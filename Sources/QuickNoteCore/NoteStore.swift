import Foundation
import CSQLite

public enum NoteStoreError: LocalizedError {
    case sqlite(code: Int32, message: String?)
    case unsupportedSchema(Int)
    case invalidDatabase(String)

    public var errorDescription: String? { description(language: .systemDefault()) }

    public func description(language: AppLanguage) -> String {
        switch self {
        case let .sqlite(code, message): return language.format("SQLite 错误（%lld）：%@", Int64(code), message ?? language.text("Cannot open database"))
        case let .unsupportedSchema(version): return language.format("此备忘录数据库版本为 %lld，当前应用仅支持版本 2。", Int64(version))
        case let .invalidDatabase(reason):
            let detail = language.text(reason)
            return language.format("备忘录数据库无效：%@", detail)
        }
    }

}

/// The entire application owns one note. A save replaces its ordered blocks atomically.
/// Calls on a store are serialized; SQLite also coordinates independent connections.
public final class NoteStore {
    public let url: URL
    private var connection: OpaquePointer?
    private let lock = NSLock()
    private static let schemaVersion = 2
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        guard url.isFileURL else { throw NoteStoreError.invalidDatabase("A local file path is required") }
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let error = sqliteError(status)
            if let connection { sqlite3_close(connection) }
            connection = nil
            throw error
        }
        do {
            try check(sqlite3_busy_timeout(connection, 5_000))
            let version = try integerQuery("PRAGMA user_version")
            guard version == 0 || version == Self.schemaVersion else { throw NoteStoreError.unsupportedSchema(version) }
            if version == 0 {
                let tableCount = try integerQuery("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                guard tableCount == 0 else { throw NoteStoreError.invalidDatabase("An unversioned database already contains tables") }
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try verifyIntegrity()
            if version == 0 { try createSchema() }
            // Preparing these statements checks required tables and columns without repairing data.
            let notes = try prepare("SELECT id, updated_at FROM notes")
            sqlite3_finalize(notes)
            let blocks = try prepare("SELECT note_id, position, block_id, kind, text, rich_text, is_checked, indent_level FROM blocks")
            sqlite3_finalize(blocks)
        } catch {
            if let connection { sqlite3_close(connection) }
            connection = nil
            throw error
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    public func load() throws -> NoteDocument {
        lock.lock()
        defer { lock.unlock() }
        return try transaction { try readDocument() }
    }

    /// A malformed document is never replaced by an empty note.
    private func readDocument() throws -> NoteDocument {
        let note = try prepare("SELECT id, updated_at FROM notes ORDER BY id")
        defer { sqlite3_finalize(note) }
        let noteResult = sqlite3_step(note)
        if noteResult == SQLITE_DONE {
            guard try integerQuery("SELECT count(*) FROM blocks") == 0 else {
                throw NoteStoreError.invalidDatabase("Blocks exist without a parent note")
            }
            return NoteDocument()
        }
        guard noteResult == SQLITE_ROW else { throw sqliteError(noteResult) }
        guard sqlite3_column_type(note, 0) == SQLITE_INTEGER, sqlite3_column_int64(note, 0) == 1 else {
            throw NoteStoreError.invalidDatabase("Invalid note identifier")
        }
        let timeType = sqlite3_column_type(note, 1)
        let timestamp = sqlite3_column_double(note, 1)
        guard (timeType == SQLITE_FLOAT || timeType == SQLITE_INTEGER), timestamp.isFinite else {
            throw NoteStoreError.invalidDatabase("Invalid save timestamp")
        }
        guard sqlite3_step(note) == SQLITE_DONE else { throw NoteStoreError.invalidDatabase("The database contains multiple notes") }

        let columns = "note_id, position, block_id, kind, text, rich_text, is_checked, indent_level"
        let statement = try prepare("SELECT \(columns) FROM blocks ORDER BY position")
        defer { sqlite3_finalize(statement) }
        var result: [NoteBlock] = []
        var seenIDs = Set<UUID>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError(step) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) == 1,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 1) == Int64(result.count),
                  let id = UUID(uuidString: try string(statement, column: 2)),
                  seenIDs.insert(id).inserted,
                  let kind = BlockKind(rawValue: try string(statement, column: 3)),
                  sqlite3_column_type(statement, 6) == SQLITE_INTEGER else {
                throw NoteStoreError.invalidDatabase("Invalid block identifier, order, or type")
            }
            let checked = sqlite3_column_int64(statement, 6)
            guard checked == 0 || checked == 1 else { throw NoteStoreError.invalidDatabase("Invalid checklist state") }
            let indent = sqlite3_column_int64(statement, 7)
            guard sqlite3_column_type(statement, 7) == SQLITE_INTEGER, (0...8).contains(indent) else {
                throw NoteStoreError.invalidDatabase("Invalid block indentation")
            }
            let indentLevel = Int(indent)
            let richText: Data?
            switch sqlite3_column_type(statement, 5) {
            case SQLITE_NULL: richText = nil
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, 5))
                if count == 0 { richText = Data() }
                else if let bytes = sqlite3_column_blob(statement, 5) { richText = Data(bytes: bytes, count: count) }
                else { throw NoteStoreError.invalidDatabase("Invalid rich text data") }
            default: throw NoteStoreError.invalidDatabase("Rich text data is not a BLOB")
            }
            result.append(NoteBlock(id: id, kind: kind, text: try string(statement, column: 4), richText: richText, isChecked: checked == 1, indentLevel: indentLevel))
        }
        return NoteDocument(blocks: result, updatedAt: Date(timeIntervalSinceReferenceDate: timestamp))
    }

    public func save(_ document: NoteDocument) throws {
        guard document.updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw NoteStoreError.invalidDatabase("Invalid save timestamp") }
        lock.lock()
        defer { lock.unlock() }
        try transaction(immediate: true) {
            try execute("DELETE FROM blocks")
            let note = try prepare("INSERT INTO notes(id, updated_at) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at")
            defer { sqlite3_finalize(note) }
            // Persist Date's native epoch (2001-01-01 UTC), avoiding precision loss
            // from adding and subtracting the Unix epoch offset during a round trip.
            try check(sqlite3_bind_double(note, 1, document.updatedAt.timeIntervalSinceReferenceDate))
            try finish(note)
            let block = try prepare("INSERT INTO blocks(note_id, position, block_id, kind, text, rich_text, is_checked, indent_level) VALUES(1, ?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(block) }
            for (position, value) in document.blocks.enumerated() {
                try check(sqlite3_reset(block))
                try check(sqlite3_clear_bindings(block))
                try check(sqlite3_bind_int64(block, 1, Int64(position)))
                try bind(value.id.uuidString, to: block, column: 2)
                try bind(value.kind.rawValue, to: block, column: 3)
                try bind(value.text, to: block, column: 4)
                if let data = value.richText {
                    guard data.count <= Int(Int32.max) else { throw NoteStoreError.invalidDatabase("Rich text data is too large") }
                    if data.isEmpty { try check(sqlite3_bind_zeroblob(block, 5, 0)) }
                    else {
                        try data.withUnsafeBytes { bytes in
                            try check(sqlite3_bind_blob(block, 5, bytes.baseAddress, Int32(bytes.count), transient))
                        }
                    }
                } else { try check(sqlite3_bind_null(block, 5)) }
                try check(sqlite3_bind_int(block, 6, value.isChecked ? 1 : 0))
                try check(sqlite3_bind_int64(block, 7, Int64(value.indentLevel)))
                try finish(block)
            }
        }
    }

    private func createSchema() throws {
        try transaction(immediate: true) {
            try execute("""
                CREATE TABLE notes (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    updated_at REAL NOT NULL
                );
                \(Self.blocksSchema(name: "blocks"))
                PRAGMA user_version = 2;
                """)
        }
    }

    private static func blocksSchema(name: String) -> String {
        """
                CREATE TABLE \(name) (
                    note_id INTEGER NOT NULL CHECK(note_id = 1) REFERENCES notes(id) ON DELETE CASCADE,
                    position INTEGER PRIMARY KEY CHECK(position >= 0),
                    block_id TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK(kind IN ('title','heading','subheading','body','bullet','dashed','numbered','checklist','quote','code')),
                    text TEXT NOT NULL,
                    rich_text BLOB,
                    is_checked INTEGER NOT NULL CHECK(is_checked IN (0, 1)),
                    indent_level INTEGER NOT NULL DEFAULT 0 CHECK(indent_level BETWEEN 0 AND 8)
                );
        """
    }

    private func verifyIntegrity() throws {
        let integrity = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW, try string(integrity, column: 0) == "ok" else {
            throw NoteStoreError.invalidDatabase("SQLite integrity check failed")
        }
    }

    private func transaction<T>(immediate: Bool = false, _ operation: () throws -> T) throws -> T {
        try execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(result)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }

    private func integerQuery(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw sqliteError(result) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func string(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column),
              let result = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
            throw NoteStoreError.invalidDatabase("Invalid text field")
        }
        return result
    }

    private func bind(_ value: String, to statement: OpaquePointer, column: Int32) throws {
        let count = value.utf8.count
        guard count <= Int(Int32.max) else { throw NoteStoreError.invalidDatabase("Text data is too large") }
        try value.withCString { bytes in
            try check(sqlite3_bind_text(statement, column, bytes, Int32(count), transient))
        }
    }

    private func finish(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(result) }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw sqliteError(result) }
    }

    private func sqliteError(_ code: Int32) -> NoteStoreError {
        .sqlite(code: code, message: connection.map { String(cString: sqlite3_errmsg($0)) })
    }
}
