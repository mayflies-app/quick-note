import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class WindowPlacementTests: XCTestCase {
    func testValidPositionOnNegativeCoordinateDisplayDoesNotMove() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let frame = NSRect(x: -1500, y: 120, width: 660, height: 620)
        XCTAssertEqual(WindowPlacement.frame(for: frame, visibleFrames: [primary, secondary], fallback: primary), frame)
    }

    func testDisconnectedDisplayUsesAvailableFallback() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let secondary = NSRect(x: 1440, y: -100, width: 1280, height: 780)
        let saved = NSRect(x: -1800, y: 120, width: 660, height: 620)
        let result = WindowPlacement.frame(for: saved, visibleFrames: [primary, secondary], fallback: secondary)
        XCTAssertTrue(secondary.contains(result))
        XCTAssertEqual(result.size, saved.size)
    }

    func testSmallerWorkspaceShrinksOversizedWindowAndKeepsTitlebarVisible() {
        let available = NSRect(x: -800, y: 40, width: 800, height: 560)
        let frame = NSRect(x: -900, y: -100, width: 1200, height: 900)
        let result = WindowPlacement.frame(for: frame, visibleFrames: [available])
        XCTAssertEqual(result, available)
    }

    func testPartialOverlapUsesScreenWithMostWindowArea() {
        let left = NSRect(x: -1200, y: 0, width: 1200, height: 900)
        let right = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let frame = NSRect(x: -100, y: 300, width: 660, height: 620)
        let result = WindowPlacement.frame(for: frame, visibleFrames: [left, right], fallback: left)
        XCTAssertTrue(right.contains(result))
        XCTAssertEqual(result.origin, NSPoint(x: 0, y: 280))
    }

    func testNoDisplayLeavesFrameUnchanged() {
        let frame = NSRect(x: 30, y: 40, width: 660, height: 620)
        XCTAssertEqual(WindowPlacement.frame(for: frame, visibleFrames: []), frame)
    }

    func testShowingAnOffscreenNoteRestoresItsFrameWithoutChangingTextOrSelection() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a macOS display session") }
        let controller = NoteWindowController()
        controller.editor.load(blocks: [NoteBlock(text: "保留输入与光标")])
        let selection = NSRange(location: 2, length: 3)
        controller.editor.textView.setSelectedRange(selection)
        let window = try XCTUnwrap(controller.window)
        let savedFrame = window.frame
        defer { window.setFrame(savedFrame, display: false); controller.hide() }
        window.setFrameOrigin(NSPoint(x: 100_000, y: 100_000))
        controller.show()
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }, "A detached display must not leave the note outside all current screens")
        XCTAssertEqual(controller.editor.textView.string, "保留输入与光标")
        XCTAssertEqual(controller.editor.textView.selectedRange(), selection)
    }
}
