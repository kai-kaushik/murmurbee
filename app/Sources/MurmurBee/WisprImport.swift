import AppKit
import Foundation
import SQLite3

/// One-click import of Wispr Flow's local history and dictionary, so MurmurBee knows your words from day one.
/// Wispr keeps everything in ~/Library/Application Support/Wispr Flow/flow.sqlite; it is opened read-only and never
/// changed. Audio is not imported. Each dictation keeps Wispr's raw transcript and your edits: that pairing is what a
/// personal model trains on later.
enum WisprImport {
    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
    }
    static var isAvailable: Bool { FileManager.default.isReadableFile(atPath: database.path) }
    static var imported: Bool {
        get { UserDefaults.standard.bool(forKey: "wisprImported") }
        set { UserDefaults.standard.set(newValue, forKey: "wisprImported") }
    }

    struct Found: Sendable { let dictations: Int; let words: Int }
    struct Result: Sendable { let dictations: Int; let words: Int }

    struct Row: Sendable {
        let id: String
        let date: Date
        let bundle: String
        let url: String
        let durationS: Double
        let asr: String
        let pasted: String
        let edited: String?
        let before: String
        let selected: String
    }

    /// What there is to import (fast counts).
    static func scan() -> Found? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        return Found(dictations: count(db, "SELECT count(*) FROM History WHERE \(hasText)"),
                     words: count(db, "SELECT count(*) FROM Dictionary WHERE \(isWord)"))
    }

    /// Imports dictations into history and words into the dictionary. Safe to run again: nothing is added twice.
    static func run(into store: Store, writeDictionary: Bool = true,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Result {
        guard let db = open() else { throw CocoaError(.fileReadNoPermission) }
        defer { sqlite3_close(db) }
        let total = count(db, "SELECT count(*) FROM History WHERE \(hasText)")

        // Dictionary words (not snippets, not deleted). Words Wispr picked up from your edits are marked auto-learned.
        var words: [(String, Bool)] = []
        query(db, "SELECT phrase, COALESCE(source, '') FROM Dictionary WHERE \(isWord)") { s in
            let phrase = text(s, 0).trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { words.append((phrase, text(s, 1) != "manual")) }
        }
        let addedWords = writeDictionary ? addToDictionary(words) : words.count

        // Dictations, oldest first, in batches so progress can move.
        let sql = """
            SELECT transcriptEntityId, timestamp, COALESCE(app, ''), COALESCE(url, ''), COALESCE(duration, 0),
                   COALESCE(asrText, ''), COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), asrText, ''),
                   NULLIF(editedText, ''),
                   COALESCE(json_extract(additionalContext, '$.textbox_contents.beforeText'), ''),
                   COALESCE(json_extract(additionalContext, '$.textbox_contents.selectedText'), '')
            FROM History WHERE \(hasText) ORDER BY timestamp
            """
        var batch: [Row] = [], done = 0, added = 0
        query(db, sql) { s in
            batch.append(Row(id: text(s, 0), date: parseDate(text(s, 1)), bundle: text(s, 2), url: text(s, 3),
                             durationS: sqlite3_column_double(s, 4), asr: text(s, 5), pasted: text(s, 6),
                             edited: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : text(s, 7),
                             before: text(s, 8), selected: text(s, 9)))
        }
        let names = AppNames()
        for chunk in stride(from: 0, to: batch.count, by: 500).map({ Array(batch[$0..<min($0 + 500, batch.count)]) }) {
            added += await store.importDictations(chunk, appName: { names.name(for: $0) })
            done += chunk.count
            progress(done, total)
        }
        if writeDictionary { imported = true }
        NotificationCenter.default.post(name: .historyChanged, object: nil)
        return Result(dictations: added, words: addedWords)
    }

    // MARK: - SQLite helpers

    private static let hasText = "COALESCE(asrText, '') <> ''"
    private static let isWord = "COALESCE(isDeleted, 0) = 0 AND COALESCE(isSnippet, 0) = 0 AND COALESCE(replacement, '') = ''"

    private static func open() -> OpaquePointer? {
        guard isAvailable else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)  // Wispr may be writing
        return db
    }

    private static func count(_ db: OpaquePointer, _ sql: String) -> Int {
        var n = 0
        query(db, sql) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    /// Wispr timestamps look like "2026-10-10 12:46:01.420 +00:00".
    private static func parseDate(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSS ZZZZZ", "yyyy-MM-dd HH:mm:ss ZZZZZ", "yyyy-MM-dd HH:mm:ss.SSS"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s) ?? .distantPast
    }

    /// Appends new words to dictionary.txt (auto-learned ones tagged "# auto"); returns how many were new.
    private static func addToDictionary(_ words: [(String, Bool)]) -> Int {
        _ = Vocabulary.dictionary()  // make sure the file exists
        let existing = (try? String(contentsOf: Vocabulary.file, encoding: .utf8)) ?? ""
        var have = Set(existing.split(separator: "\n").map {
            $0.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces).lowercased()
        })
        var lines: [String] = []
        for (w, auto) in words where !have.contains(w.lowercased()) {
            have.insert(w.lowercased())
            lines.append(auto ? "\(w)  # auto" : w)
        }
        guard !lines.isEmpty else { return 0 }
        let out = (existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n") + lines.joined(separator: "\n") + "\n"
        try? out.write(to: Vocabulary.file, atomically: true, encoding: .utf8)
        return lines.count
    }
}

/// Bundle ID → app name ("com.tinyspeck.slackmacgap" → "Slack"), cached.
private final class AppNames: @unchecked Sendable {
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    func name(for bundle: String) -> String {
        guard !bundle.isEmpty else { return "" }
        lock.lock(); defer { lock.unlock() }
        if let n = cache[bundle] { return n }
        var n = bundle.split(separator: ".").last.map(String.init)?.capitalized ?? bundle
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        cache[bundle] = n
        return n
    }
}

/// Drives the import from the UI (Home card and Settings → Privacy) and reports progress.
@MainActor
@Observable
final class WisprImporter {
    static let shared = WisprImporter()
    var store: Store?
    private(set) var found: WisprImport.Found?
    private(set) var progress: (done: Int, total: Int)?
    private(set) var result: WisprImport.Result?
    var dismissed: Bool {
        didSet { UserDefaults.standard.set(dismissed, forKey: "wisprCardDismissed") }
    }
    var running: Bool { progress != nil && result == nil }

    private init() {
        dismissed = UserDefaults.standard.bool(forKey: "wisprCardDismissed")
        refresh()
    }

    /// Re-count what Wispr Flow has (cheap; run off the main thread).
    func refresh() {
        guard WisprImport.isAvailable else { found = nil; return }
        Task.detached { [weak self] in
            let f = WisprImport.scan()
            await MainActor.run { self?.found = f }
        }
    }

    /// Show the Home card only when there's something to import and it hasn't been done or dismissed.
    var offerOnHome: Bool { (found?.dictations ?? 0) > 0 && !WisprImport.imported && !dismissed || running }

    func start(onDone: @escaping @MainActor (WisprImport.Result) -> Void = { _ in }) {
        guard let store, !running else { return }
        result = nil
        progress = (0, found?.dictations ?? 0)
        Task.detached { [weak self] in
            let r = try? await WisprImport.run(into: store) { d, t in
                Task { @MainActor in self?.progress = (d, t) }
            }
            await MainActor.run {
                guard let self else { return }
                let res = r ?? WisprImport.Result(dictations: 0, words: 0)
                self.result = res
                self.progress = nil
                onDone(res)
            }
        }
    }
}
