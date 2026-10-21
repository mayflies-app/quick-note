import Foundation
import XCTest
@testable import QuickNote

@MainActor
final class StartupTests: XCTestCase {
    func testInvalidWorkflowDatabaseNeverLooksUpEverydayData() {
        let invalidArguments: [[String]] = [
            ["--verify-workflow"],
            ["--verify-workflow", "--database"],
            ["--verify-workflow", "--database", ""],
            ["--verify-workflow", "--database", "relative.sqlite"],
            ["--verify-workflow", "--database", "--read-back"],
            ["--verify-workflow", "--database", "/"],
            ["--verify-workflow", "--database", "/tmp/"],
            ["--verify-workflow", "--database", "/tmp/.."],
            ["--verify-workflow", "--database", "/tmp/notes\u{0}.sqlite"],
            ["--verify-workflow", "--database", "/tmp/first.sqlite", "--database", "/tmp/second.sqlite"],
            ["--verify-workflow", "--database=/tmp/notes.sqlite"]
        ]
        for arguments in invalidArguments {
            var everydayLookups = 0
            XCTAssertThrowsError(try AppDelegate.databaseURL(arguments: arguments, applicationSupportDirectory: {
                everydayLookups += 1
                return URL(fileURLWithPath: "/unreachable-user-data", isDirectory: true)
            }), "Fixture startup must stop before any NoteStore URL is returned: \(arguments)")
            XCTAssertEqual(everydayLookups, 0, "Invalid fixture startup accessed the everyday data directory")
        }
    }

    func testWorkflowUsesOnlyExplicitAbsoluteDatabaseIncludingSpaces() throws {
        let path = "/tmp/isolated fixture/notes.sqlite"
        let url = try AppDelegate.databaseURL(arguments: ["--verify-workflow", "--database", path],
            applicationSupportDirectory: { XCTFail("Fixture resolved everyday data"); throw Failure.unexpectedLookup })
        XCTAssertEqual(url.path, path)
    }

    func testOrdinaryStartupKeepsDefaultAndExplicitDatabaseBehavior() throws {
        var everydayLookups = 0
        let directory = URL(fileURLWithPath: "/ordinary-user-support", isDirectory: true)
        let fallback = try AppDelegate.databaseURL(arguments: [], applicationSupportDirectory: {
            everydayLookups += 1
            return directory
        })
        XCTAssertEqual(fallback.path, "/ordinary-user-support/QuickNote/notes.sqlite")
        XCTAssertEqual(everydayLookups, 1)
        let explicit = try AppDelegate.databaseURL(arguments: ["--database", "custom.sqlite"],
            applicationSupportDirectory: { XCTFail("Explicit normal database resolved everyday data"); throw Failure.unexpectedLookup })
        XCTAssertEqual(explicit.lastPathComponent, "custom.sqlite")
    }

    private enum Failure: Error { case unexpectedLookup }
}
