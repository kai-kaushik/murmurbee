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
