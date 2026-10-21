import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class EditorShortcutTests: XCTestCase {
    private func event(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
    }

    private func makeEditor() -> NoteEditorViewController {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "ABCD")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        return editor
    }

    func testShiftedNumberKeysAndChineseInputSourceApplyListStyles() throws {
        for (keyCode, shifted, kind) in [(UInt16(26), "&", BlockKind.bullet), (28, "*", .dashed), (25, "(", .numbered)] {
            for characters in [shifted, "中"] {
                let editor = makeEditor()
                XCTAssertTrue(EditorShortcuts.handle(event(characters, keyCode: keyCode, modifiers: [.command, .shift]), editor: editor))
                XCTAssertEqual(try editor.snapshot().first?.kind, kind)
            }
        }
    }

    func testRequiredParagraphCommandsThroughKeyboard() throws {
        let cases: [(UInt16, String, NSEvent.ModifierFlags, BlockKind)] = [
            (17, "T", [.command, .shift], .title), (4, "H", [.command, .shift], .heading),
            (38, "J", [.command, .shift], .subheading), (46, "M", [.command, .shift], .code),
            (39, "'", [.command], .quote), (37, "L", [.command, .shift], .checklist)
        ]
        for (keyCode, text, flags, kind) in cases {
            let editor = makeEditor()
            XCTAssertTrue(EditorShortcuts.handle(event(text, keyCode: keyCode, modifiers: flags), editor: editor))
            XCTAssertEqual(try editor.snapshot().first?.kind, kind)
            XCTAssertTrue(EditorShortcuts.handle(event("B", keyCode: 11, modifiers: [.command, .shift]), editor: editor))
            XCTAssertEqual(try editor.snapshot().first?.kind, .body)
        }
    }

    func testInlineCommandsClearOnlySelectionAndUndoRestoresIt() async throws {
        let editor = makeEditor()
        XCTAssertTrue(EditorShortcuts.handle(event("b", keyCode: 11, modifiers: .command), editor: editor))
        XCTAssertTrue(EditorShortcuts.handle(event("X", keyCode: 7, modifiers: [.command, .shift]), editor: editor))
        editor.setLink(URL(string: "https://example.com")!)
        editor.setHighlight(.blue)
        try await Task.sleep(for: .milliseconds(40))
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertTrue(EditorShortcuts.handle(event("\\", keyCode: 42, modifiers: .command), editor: editor))
        for index in [0, 3] {
            let attributes = editor.textView.attributedString().attributes(at: index, effectiveRange: nil)
            XCTAssertNotNil(attributes[.link])
            XCTAssertNotNil(attributes[.backgroundColor])
            XCTAssertEqual(attributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        }
        for index in [1, 2] {
            let attributes = editor.textView.attributedString().attributes(at: index, effectiveRange: nil)
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.backgroundColor])
            XCTAssertNil(attributes[.strikethroughStyle])
        }
        editor.textView.undoManager?.undo()
        XCTAssertNotNil(editor.textView.attributedString().attribute(.link, at: 1, effectiveRange: nil))
        XCTAssertNotNil(editor.textView.attributedString().attribute(.backgroundColor, at: 1, effectiveRange: nil))
    }

    func testIndentAndChecklistCompletionCommands() throws {
        let editor = makeEditor()
        XCTAssertTrue(EditorShortcuts.handle(event("]", keyCode: 30, modifiers: .command), editor: editor))
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 1)
        XCTAssertTrue(EditorShortcuts.handle(event("[", keyCode: 33, modifiers: .command), editor: editor))
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 0)
        _ = EditorShortcuts.handle(event("L", keyCode: 37, modifiers: [.command, .shift]), editor: editor)
        XCTAssertTrue(EditorShortcuts.handle(event("U", keyCode: 32, modifiers: [.command, .shift]), editor: editor))
        XCTAssertEqual(try editor.snapshot().first?.isChecked, true)
    }

    func testExtraModifiersAndNativeNavigationAreNotConsumed() throws {
        let editor = makeEditor()
        for flags: NSEvent.ModifierFlags in [[.command, .control], [.command, .option], [.command, .function], [.command, .help], []] {
            XCTAssertFalse(EditorShortcuts.handle(event("b", keyCode: 11, modifiers: flags), editor: editor))
        }
        XCTAssertFalse(EditorShortcuts.handle(event("7", keyCode: 26, modifiers: []), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("\u{7f}", keyCode: 51, modifiers: .command), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("k", keyCode: 40, modifiers: .command), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("t", keyCode: 17, modifiers: [.command, .option]), editor: editor))
        XCTAssertEqual(try editor.snapshot().first?.kind, .body)
    }

    func testLogicalCopyKeyOnAnotherLayoutDoesNotBecomeBold() throws {
        let editor = makeEditor()
        XCTAssertFalse(EditorShortcuts.handle(event("c", keyCode: 11, modifiers: .command), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("v", keyCode: 34, modifiers: .command), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("x", keyCode: 32, modifiers: .command), editor: editor))
        XCTAssertFalse(editor.formatState.bold)
        XCTAssertFalse(editor.formatState.italic)
        XCTAssertFalse(editor.formatState.underline)
        XCTAssertEqual(editor.textView.string, "ABCD")
        XCTAssertTrue(EditorShortcuts.handle(event("b", keyCode: 8, modifiers: .command), editor: editor))
        XCTAssertTrue(editor.formatState.bold)
    }

    func testNativeTextViewKeyEquivalentHandlesInlineCommandsAndCapsLock() throws {
        let editor = makeEditor()
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: event("B", keyCode: 11, modifiers: [.command, .capsLock])))
        XCTAssertTrue(editor.formatState.bold)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: event("i", keyCode: 34, modifiers: .command)))
        XCTAssertTrue(editor.formatState.italic)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: event("u", keyCode: 32, modifiers: .command)))
        XCTAssertTrue(editor.formatState.underline)
    }

    func testMarkedTextIsNotInterruptedByFormattingShortcut() throws {
        let editor = makeEditor()
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertFalse(EditorShortcuts.handle(event("T", keyCode: 17, modifiers: [.command, .shift]), editor: editor))
        XCTAssertFalse(EditorShortcuts.handle(event("\\", keyCode: 42, modifiers: .command), editor: editor))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertEqual(editor.textView.string, "ABCDni")
        editor.textView.insertText("你", replacementRange: editor.textView.markedRange())
        XCTAssertEqual(try editor.snapshot().first?.kind, .body)
    }
}
