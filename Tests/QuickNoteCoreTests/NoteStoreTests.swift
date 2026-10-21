import XCTest
import Foundation
import CSQLite
@testable import QuickNoteCore

final class NoteStoreTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("note.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNewDatabaseLoadsOneEmptyBodyBlock() throws {
        let document = try NoteStore(url: databaseURL).load()
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks.first?.kind, .body)
        XCTAssertEqual(document.blocks.first?.text, "")
        XCTAssertEqual(try scalar("PRAGMA user_version"), 2)
    }

    func testOldSchemaIsRejectedWithoutChangingItsBytesOrCreatingWAL() throws {
        try execute("CREATE TABLE precious(value TEXT); INSERT INTO precious VALUES('keep me'); PRAGMA user_version = 1")
        let before = try Data(contentsOf: databaseURL)
        XCTAssertThrowsError(try NoteStore(url: databaseURL)) { error in
            guard case NoteStoreError.unsupportedSchema(1) = error else {
                return XCTFail("Expected unsupported schema, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertEqual(try scalar("PRAGMA user_version"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM precious WHERE value = 'keep me'"), 1)
    }

    func testNestedFormatsRoundTripAndInvalidIndentRollsBackSave() throws {
        let store = try NoteStore(url: databaseURL)
        let document = NoteDocument(blocks: [
            NoteBlock(kind: .subheading, text: "小标题", indentLevel: 1),
            NoteBlock(kind: .dashed, text: "— 项目", richText: Data([1, 2, 3]), indentLevel: 8),
            NoteBlock(kind: .numbered, text: "下一项", indentLevel: 3)
        ], updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000001))
        try store.save(document)
        XCTAssertEqual(try NoteStore(url: databaseURL).load(), document)
        for invalidLevel in [-1, 9, Int.max] {
            var invalid = document
            invalid.updatedAt = Date()
            invalid.blocks[0].indentLevel = invalidLevel
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(try store.load(), document)
        }
    }

    func testRoundTripPreservesUnicodeRichTextOrderAndTimestamp() throws {
        let document = NoteDocument(blocks: [
            NoteBlock(kind: .title, text: "记录 📝\u{0000}末尾", richText: Data("{\\rtf1\\ansi Bold}".utf8)),
            NoteBlock(kind: .checklist, text: "已完成 café", richText: Data(), isChecked: true),
            NoteBlock(kind: .quote, text: "第二行\n引用")
        ], updatedAt: Date(timeIntervalSince1970: 1234567890.125))
        let store = try NoteStore(url: databaseURL)
        try store.save(document)
        XCTAssertEqual(try store.load(), document)
    }

    func testEditsDeleteRemovedBlocksAndKeepASingleNote() throws {
        let store = try NoteStore(url: databaseURL)
        var document = NoteDocument(blocks: [NoteBlock(text: "first"), NoteBlock(text: "delete")])
        try store.save(document)
        document.blocks.removeLast()
        document.blocks[0].text = "edited"
        try store.save(document)
        XCTAssertEqual(try store.load(), document)
        XCTAssertEqual(try scalar("SELECT count(*) FROM notes"), 1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM blocks"), 1)
        XCTAssertThrowsError(try execute("INSERT INTO notes(id, updated_at) VALUES(2, 0)"))
    }

    func testDuplicateBlockIDRollsBackEntireSave() throws {
        let store = try NoteStore(url: databaseURL)
        let original = NoteDocument(blocks: [NoteBlock(text: "recover me")], updatedAt: Date(timeIntervalSince1970: 100))
        try store.save(original)
        let duplicate = UUID()
        let invalid = NoteDocument(blocks: [NoteBlock(id: duplicate, text: "a"), NoteBlock(id: duplicate, text: "b")], updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(try NoteStore(url: databaseURL).load(), original)
    }

    func testReopeningRestoresTheSameDocument() throws {
        let document = NoteDocument(blocks: [NoteBlock(kind: .heading, text: "Persistent")])
        do {
            let store = try NoteStore(url: databaseURL)
            try store.save(document)
        }
        XCTAssertEqual(try NoteStore(url: databaseURL).load(), document)
    }

    func testTimestampRetainsNativeDatePrecision() throws {
        let document = NoteDocument(updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000001))
        let store = try NoteStore(url: databaseURL)
        try store.save(document)
        XCTAssertEqual(try store.load().updatedAt, document.updatedAt)
    }

    func testFutureSchemaVersionIsRejectedWithoutClearingData() throws {
        let document = NoteDocument(blocks: [NoteBlock(text: "future data")])
        try NoteStore(url: databaseURL).save(document)
        try execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try NoteStore(url: databaseURL))
        XCTAssertEqual(try scalar("SELECT count(*) FROM blocks"), 1)
        XCTAssertEqual(try scalar("PRAGMA user_version"), 99)
    }

    func testMalformedSchemaAndMalformedFileAreRejected() throws {
        try execute("CREATE TABLE unexpected(value TEXT)")
        XCTAssertThrowsError(try NoteStore(url: databaseURL))
        try FileManager.default.removeItem(at: databaseURL)
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        XCTAssertThrowsError(try NoteStore(url: databaseURL))
    }

    func testInvalidPersistedBlockDoesNotSilentlyProduceAnEmptyNote() throws {
        try NoteStore(url: databaseURL).save(NoteDocument(blocks: [NoteBlock(text: "valuable")]))
        try execute("UPDATE blocks SET block_id = 'invalid-uuid'")
        XCTAssertThrowsError(try NoteStore(url: databaseURL).load())
        XCTAssertEqual(try scalar("SELECT count(*) FROM blocks"), 1)
    }

    private func withDatabase<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &connection)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw TestDatabaseError.failed
        }
        defer { sqlite3_close(connection) }
        return try action(connection)
    }

    private func execute(_ sql: String) throws {
        try withDatabase { connection in
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw TestDatabaseError.failed }
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        try withDatabase { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw TestDatabaseError.failed }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw TestDatabaseError.failed }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private enum TestDatabaseError: Error { case failed }
}
