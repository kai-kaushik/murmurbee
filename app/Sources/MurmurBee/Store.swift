import Foundation
import SQLite3

/// Local history, one row per dictation. Text only; no audio is kept.
/// Context fields are stored even though v1's model doesn't use them yet: they are training data for v2.
struct DictationRecord: Sendable {
    var createdAt = Date()
    var context = ContextSnapshot()
    var durationS = 0.0
    var chunks = 0
    var asrText = ""
    var cleanedText = ""
    var cleanupPaths = ""
    var insertMethod = ""
    var insertConfirmed = false
    var latencyTotalMs = 0.0
    var latencyAsrFinalMs = 0.0
    var latencyCleanupFinalMs = 0.0
    var cleanupOrigin = ""
    var fieldAfter: String?
    var vocab: String?
}

struct HistoryItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let date: Date
    let app: String
    let text: String
    let durationS: Double
    let latencyMs: Double
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// One recorded meeting. The audio lives in a folder of its own only until the transcript is made.
struct Meeting: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case recording, processing, ready, failed }
    let id: Int64
    var date = Date()
    var title = ""
    var durationS = 0.0
    var status = Status.recording
    /// What you typed during the call.
    var typed = ""
    var transcript = ""
    var notes = ""
    /// Why the last attempt failed.
    var problem = ""
    /// The name on your lines in the transcript; empty when nobody's voice is known (an in-person meeting).
    var you = ""
    /// Spellings given to the notes model, separated by "; ".
    var vocab = ""

    /// The notes to read and copy: the model's, then what you typed, word for word.
    var fullNotes: String {
        let lines = typed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return notes }
        let own = "## Your notes\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        return notes.isEmpty ? own : notes + "\n\n" + own
    }
}

extension Notification.Name {
    /// Posted on the main thread after a dictation is saved or history is deleted.
    static let historyChanged = Notification.Name("MurmurBeeHistoryChanged")
}

actor Store {
    /// ~/Library/Application Support/MurmurBee. Data from the app's earlier name ("LocalFlow") is moved here once.
    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MurmurBee")
        let old = support.appendingPathComponent("LocalFlow")
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        return dir
    }()
    private var db: OpaquePointer?

    /// `path` is for tests; the app uses Application Support/MurmurBee/history.sqlite.
    init(path: String? = nil) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = path ?? Self.directory.appendingPathComponent("history.sqlite").path
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS dictations (
              id INTEGER PRIMARY KEY, created_at TEXT, app_bundle TEXT, app_name TEXT, app_type TEXT,
              window_title TEXT, before_cursor TEXT, selected_text TEXT, duration_s REAL, chunks INTEGER,
              asr_text TEXT, cleaned_text TEXT, cleanup_paths TEXT, asr_origin TEXT, cleanup_origin TEXT,
              insert_method TEXT, insert_confirmed INTEGER, latency_total_ms REAL, latency_asr_final_ms REAL,
              latency_cleanup_final_ms REAL, edited_text TEXT);
            """, nil, nil, nil)
        // Columns added after v0.1; ALTER fails harmlessly when they already exist.
        for col in ["field_after TEXT", "field_later TEXT", "vocab TEXT", "cleanup_origin_v TEXT",
                    "source TEXT", "import_id TEXT", "url TEXT"] {
            sqlite3_exec(db, "ALTER TABLE dictations ADD COLUMN \(col)", nil, nil, nil)
        }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS meetings (
              id INTEGER PRIMARY KEY, created_at TEXT, title TEXT, duration_s REAL, status TEXT, typed TEXT,
              transcript TEXT, notes TEXT, problem TEXT, you TEXT, vocab TEXT);
            """, nil, nil, nil)
        // Imported rows (e.g. from Wispr Flow) carry their original id, so importing twice adds nothing.
        sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS dictations_import_id ON dictations(import_id)", nil, nil, nil)
    }

    @discardableResult
    func save(_ r: DictationRecord) -> Int64 {
        let sql = """
            INSERT INTO dictations (created_at, app_bundle, app_name, app_type, window_title, before_cursor,
              selected_text, duration_s, chunks, asr_text, cleaned_text, cleanup_paths, asr_origin, cleanup_origin,
              insert_method, insert_confirmed, latency_total_ms, latency_asr_final_ms, latency_cleanup_final_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let texts = [ISO8601DateFormatter().string(from: r.createdAt), r.context.bundleId, r.context.appName,
                     r.context.appType, r.context.windowTitle, r.context.beforeCursor, r.context.selectedText]
        for (i, t) in texts.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), t, -1, transient) }
        sqlite3_bind_double(stmt, 8, r.durationS)
        sqlite3_bind_int(stmt, 9, Int32(r.chunks))
        for (i, t) in [r.asrText, r.cleanedText, r.cleanupPaths, Transcriber.origin, r.cleanupOrigin, r.insertMethod]
            .enumerated() { sqlite3_bind_text(stmt, Int32(10 + i), t, -1, transient) }
        sqlite3_bind_int(stmt, 16, r.insertConfirmed ? 1 : 0)
        sqlite3_bind_double(stmt, 17, r.latencyTotalMs)
        sqlite3_bind_double(stmt, 18, r.latencyAsrFinalMs)
        sqlite3_bind_double(stmt, 19, r.latencyCleanupFinalMs)
        sqlite3_step(stmt)
        let id = sqlite3_last_insert_rowid(db)
        setText(id, "field_after", r.fieldAfter)
        setText(id, "vocab", r.vocab)
        return id
    }

    /// Newest first; `search` matches the pasted text, the edit or the app name.
    func history(search: String = "", limit: Int = 500) -> [HistoryItem] {
        var sql = """
            SELECT id, created_at, app_name, COALESCE(NULLIF(cleaned_text, ''), asr_text), duration_s, latency_total_ms
            FROM dictations WHERE COALESCE(NULLIF(cleaned_text, ''), asr_text) <> ''
            """
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { sql += " AND (cleaned_text LIKE ?1 OR asr_text LIKE ?1 OR app_name LIKE ?1)" }
        sql += " ORDER BY id DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if !q.isEmpty { sqlite3_bind_text(stmt, 1, "%\(q)%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        let iso = ISO8601DateFormatter()
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var out: [HistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryItem(id: sqlite3_column_int64(stmt, 0), date: iso.date(from: text(1)) ?? .distantPast,
                                   app: text(2), text: text(3), durationS: sqlite3_column_double(stmt, 4),
                                   latencyMs: sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    struct TrainingRow: Sendable {
        let date: Date, source: String, bundle: String, app: String, appType: String, url: String
        let before: String, selected: String, asr: String, pasted: String, edited: String?
    }

    /// Every dictation that can teach the personal model something (raw transcript and a final text).
    func trainingRows() -> [TrainingRow] {
        let sql = """
            SELECT created_at, COALESCE(source, ''), COALESCE(app_bundle, ''), COALESCE(app_name, ''),
                   COALESCE(app_type, ''), COALESCE(url, ''), COALESCE(before_cursor, ''), COALESCE(selected_text, ''),
                   asr_text, COALESCE(cleaned_text, ''), NULLIF(edited_text, '')
            FROM dictations WHERE COALESCE(asr_text, '') <> '' AND COALESCE(cleaned_text, '') <> '' ORDER BY created_at
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var out: [TrainingRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TrainingRow(date: iso.date(from: text(0)) ?? .distantPast, source: text(1), bundle: text(2),
                                   app: text(3), appType: text(4), url: text(5), before: text(6), selected: text(7),
                                   asr: text(8), pasted: text(9),
                                   edited: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : text(10)))
        }
        return out
    }

    struct Usage: Sendable {
        var dictations = 0, words = 0, edited = 0, days = 0
        var first: Date?
    }

    /// Counts for the weekly totals, from dictations made in MurmurBee since `since` (imported ones are skipped).
    /// `first` is the date of the first MurmurBee dictation ever.
    func usage(since: Date) -> Usage {
        let iso = ISO8601DateFormatter()
        var u = Usage()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT MIN(created_at) FROM dictations WHERE source IS NULL", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
            u.first = iso.date(from: String(cString: t))
        }
        sqlite3_finalize(stmt)
        stmt = nil
        let sql = """
            SELECT created_at, COALESCE(NULLIF(cleaned_text, ''), asr_text), edited_text IS NOT NULL
            FROM dictations WHERE source IS NULL AND created_at >= ? AND COALESCE(NULLIF(cleaned_text, ''), asr_text) <> ''
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return u }
        sqlite3_bind_text(stmt, 1, iso.string(from: since), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var days = Set<DateComponents>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = sqlite3_column_text(stmt, 0).flatMap { iso.date(from: String(cString: $0)) } ?? since
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            u.dictations += 1
            u.words += text.split(whereSeparator: \.isWhitespace).count
            if sqlite3_column_int(stmt, 2) != 0 { u.edited += 1 }
            days.insert(Calendar.current.dateComponents([.year, .month, .day], from: date))
        }
        u.days = days.count
        return u
    }

    /// Adds dictations imported from Wispr Flow (one transaction per batch); returns how many were new.
    func importDictations(_ rows: [WisprImport.Row], appName: @Sendable (String) -> String) -> Int {
        let sql = """
            INSERT OR IGNORE INTO dictations (created_at, app_bundle, app_name, app_type, window_title, before_cursor,
              selected_text, duration_s, chunks, asr_text, cleaned_text, cleanup_paths, asr_origin, cleanup_origin,
              insert_method, insert_confirmed, latency_total_ms, edited_text, source, import_id, url)
            VALUES (?,?,?,'','',?,?,?,0,?,?,'','wispr-flow','wispr-flow','',1,0,?,'wispr',?,?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let iso = ISO8601DateFormatter()
        let before = sqlite3_total_changes(db)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for r in rows {
            sqlite3_reset(stmt)
            let texts: [(Int32, String?)] = [(1, iso.string(from: r.date)), (2, r.bundle), (3, appName(r.bundle)),
                                             (4, r.before), (5, r.selected), (7, r.asr), (8, r.pasted),
                                             (9, r.edited), (10, "wispr:\(r.id)"), (11, r.url)]
            for (i, t) in texts {
                if let t { sqlite3_bind_text(stmt, i, t, -1, transient) } else { sqlite3_bind_null(stmt, i) }
            }
            sqlite3_bind_double(stmt, 6, r.durationS)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return Int(sqlite3_total_changes(db) - before)
    }

    // Deletes overwrite the freed pages (secure_delete) and flush the write-ahead log, so deleted text doesn't
    // linger in the database files.
    func delete(_ id: Int64) {
        sqlite3_exec(db, "DELETE FROM dictations WHERE id = \(id); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }

    func deleteAll() {
        sqlite3_exec(db, "DELETE FROM dictations; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }

    // MARK: Meetings

    func addMeeting(title: String, date: Date) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meetings (created_at, title, status) VALUES (?, ?, 'recording')", -1,
                                 &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, ISO8601DateFormatter().string(from: date), -1, transient)
        sqlite3_bind_text(stmt, 2, title, -1, transient)
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func saveMeeting(_ m: Meeting) {
        let sql = """
            UPDATE meetings SET title = ?, duration_s = ?, status = ?, typed = ?, transcript = ?, notes = ?, problem = ?,
              you = ?, vocab = ? WHERE id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, m.title, -1, transient)
        sqlite3_bind_double(stmt, 2, m.durationS)
        for (i, t) in [m.status.rawValue, m.typed, m.transcript, m.notes, m.problem, m.you, m.vocab].enumerated() {
            sqlite3_bind_text(stmt, Int32(3 + i), t, -1, transient)
        }
        sqlite3_bind_int64(stmt, 10, m.id)
        sqlite3_step(stmt)
    }

    /// Newest first.
    func meetings() -> [Meeting] {
        let sql = """
            SELECT id, created_at, title, duration_s, status, typed, transcript, notes, problem, you, vocab
            FROM meetings ORDER BY id DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var out: [Meeting] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Meeting(id: sqlite3_column_int64(stmt, 0), date: iso.date(from: text(1)) ?? .distantPast, title: text(2),
                               durationS: sqlite3_column_double(stmt, 3), status: Meeting.Status(rawValue: text(4)) ?? .failed,
                               typed: text(5), transcript: text(6), notes: text(7), problem: text(8), you: text(9),
                               vocab: text(10)))
        }
        return out
    }

    func deleteMeeting(_ id: Int64) {
        sqlite3_exec(db, "DELETE FROM meetings WHERE id = \(id); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    }

    /// Edit capture: the field's contents some time after the paste (diffed offline by scripts/learn.py).
    func setText(_ id: Int64, _ column: String, _ value: String?) {
        guard let value, id > 0 else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE dictations SET \(column) = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }
}
