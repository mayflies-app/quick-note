import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class EditorInteractionTests: XCTestCase {
    func testBackspaceExitsEmptyListOrReducesItsIndentation() throws {
        for kind in [BlockKind.bullet, .dashed, .numbered, .checklist] {
            for indent in [0, 2] {
                let editor = NoteEditorViewController()
                let block = NoteBlock(kind: kind, indentLevel: indent)
                editor.load(blocks: [block])
                editor.textView.deleteBackward(nil)
                let result = try XCTUnwrap(editor.snapshot().first)
                XCTAssertEqual(result.id, block.id)
                XCTAssertEqual(result.kind, indent == 0 ? .body : kind)
                XCTAssertEqual(result.indentLevel, max(0, indent - 1))
            }
        }
    }

    func testBackspaceOnEmptyNestedTaskKeepsPriorParagraphAndSupportsUndo() throws {
        let editor = NoteEditorViewController()
        let original = [NoteBlock(text: "保留前段"), NoteBlock(kind: .checklist, indentLevel: 1)]
        editor.load(blocks: original)
        editor.textView.deleteBackward(nil)
        var result = try editor.snapshot()
        XCTAssertEqual(result.map(\.id), original.map(\.id))
        XCTAssertEqual(result.map(\.text), ["保留前段", ""])
        XCTAssertEqual(result.last?.kind, .checklist)
        XCTAssertEqual(result.last?.indentLevel, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.textView.deleteBackward(nil)
        result = try editor.snapshot()
        XCTAssertEqual(result.map(\.id), original.map(\.id))
        XCTAssertEqual(result.last?.kind, .body)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().last?.kind, .checklist)
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 0)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 1)
    }

    func testBackspaceWithTextOrSelectionUsesNativeDeletion() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .bullet, text: "abc", indentLevel: 2)])
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(try editor.snapshot().first?.text, "bc")
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 2)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 1))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(try editor.snapshot().first?.text, "c")
        XCTAssertEqual(try editor.snapshot().first?.kind, .bullet)
    }

    func testClearingPartialSelectionPreservesUnselectedTextAndParagraphSemantics() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .checklist, text: "ABCD", isChecked: true, indentLevel: 2)])
        let text = editor.textView
        text.setSelectedRange(NSRange(location: 0, length: 4))
        editor.toggleBold()
        editor.setLink(URL(string: "https://example.com")!)
        editor.setHighlight(.mint)
        editor.setAlignment(.right)
        text.setSelectedRange(NSRange(location: 1, length: 2))
        editor.clearFormatting()
        let rich = text.attributedString()
        for index in [0, 3] {
            let font = try XCTUnwrap(rich.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertNotNil(rich.attribute(.link, at: index, effectiveRange: nil))
            XCTAssertNotNil(rich.attribute(.backgroundColor, at: index, effectiveRange: nil))
        }
        for index in [1, 2] {
            XCTAssertNil(rich.attribute(.link, at: index, effectiveRange: nil))
            XCTAssertNil(rich.attribute(.backgroundColor, at: index, effectiveRange: nil))
        }
        let block = try XCTUnwrap(editor.snapshot().first)
        XCTAssertEqual(block.kind, .checklist)
        XCTAssertEqual(block.indentLevel, 2)
        XCTAssertTrue(block.isChecked)
        XCTAssertEqual((rich.attribute(.paragraphStyle, at: 1, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 1, length: 2))
    }

    func testClearingMultiParagraphSelectionOnlyResetsFullySelectedParagraphs() throws {
        let editor = NoteEditorViewController()
        let source = [NoteBlock(kind: .heading, text: "ABCD"), NoteBlock(kind: .subheading, text: "EF", indentLevel: 1), NoteBlock(kind: .checklist, text: "GHIJ", isChecked: true, indentLevel: 2), NoteBlock()]
        editor.load(blocks: source)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 9))
        editor.clearFormatting()
        let result = try editor.snapshot()
        XCTAssertEqual(result.map(\.kind), [.heading, .body, .checklist, .body])
        XCTAssertEqual(result.map(\.indentLevel), [0, 0, 2, 0])
        XCTAssertEqual(result.map(\.id), source.map(\.id))
        XCTAssertTrue(result[2].isChecked)
    }

    func testClearingAtCaretResetsCurrentParagraphAndTypingAttributesOnly() throws {
        let editor = NoteEditorViewController()
        let source = [NoteBlock(kind: .title, text: "标题"), NoteBlock(kind: .checklist, indentLevel: 2)]
        editor.load(blocks: source)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.clearFormatting()
        let result = try editor.snapshot()
        XCTAssertEqual(result.map(\.kind), [.body, .checklist])
        XCTAssertEqual(result.map(\.id), source.map(\.id))
        XCTAssertEqual(result.last?.indentLevel, 2)
        XCTAssertFalse(editor.formatState.bold)
        XCTAssertEqual((editor.textView.typingAttributes[.font] as? NSFont)?.pointSize, 17)
    }
    func testPendingIMEInputCommitsOnceWithoutPublishingPreedit() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "正文")])
        var edits = 0
        var published: [[String]] = []
        editor.onEdit = { edits += 1 }
        editor.onChange = { published.append($0.map(\.text)) }
        editor.textView.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertEqual(edits, 0)
        XCTAssertTrue(published.isEmpty)
        editor.commitPendingInput()
        XCTAssertFalse(editor.textView.hasMarkedText())
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(published, [["正文你好"]])
        editor.commitPendingInput()
        XCTAssertEqual(edits, 1)
    }

    func testEditNotificationWorksWithoutSnapshotSubscriber() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "记录")])
        var edits = 0
        editor.onEdit = { edits += 1 }
        editor.textView.insertText("一笔", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(try editor.snapshot().first?.text, "记录一笔")
    }

    func testBackspaceDuringMarkedInputKeepsListIndentation() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .checklist, indentLevel: 2)])
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 2)
        XCTAssertEqual(try editor.snapshot().first?.kind, .checklist)
    }

    func testEditingAndSplittingMiddleParagraphPreservesOtherBlockIDsAndRichText() throws {
        let editor = NoteEditorViewController()
        let source = (0..<1000).map { NoteBlock(kind: $0 == 700 ? .checklist : .body, text: "段落\($0)", isChecked: $0 == 700, indentLevel: $0 == 700 ? 2 : 0) }
        editor.load(blocks: source)
        var range = (editor.textView.string as NSString).range(of: "段落500")
        editor.textView.setSelectedRange(range)
        editor.toggleBold()
        let before = try editor.snapshot()
        editor.textView.setSelectedRange(NSRange(location: range.location + 2, length: 0))
        editor.textView.insertText("新增", replacementRange: editor.textView.selectedRange())
        let edited = try editor.snapshot()
        XCTAssertEqual(edited.map(\.id), before.map(\.id))
        XCTAssertEqual(edited[499], before[499])
        XCTAssertEqual(edited[700], before[700])
        range = (editor.textView.string as NSString).range(of: "段落新增500")
        editor.textView.setSelectedRange(NSRange(location: range.location + 4, length: 0))
        editor.textView.insertNewline(nil)
        let split = try editor.snapshot()
        XCTAssertEqual(split.count, 1001)
        XCTAssertEqual(split[500].id, before[500].id)
        XCTAssertEqual(split[501].text, "500")
        XCTAssertEqual(Set(split.map(\.id)).count, 1001)
        XCTAssertEqual(split[701], before[700])
        let rich = try XCTUnwrap(split[501].richText)
        let restored = try NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue((restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testPartialClearFormattingCanBeUndoneWithoutChangingEmptyTail() throws {
        let editor = NoteEditorViewController()
        let source = [NoteBlock(kind: .checklist, text: "ABCD", isChecked: true, indentLevel: 1), NoteBlock(kind: .bullet, indentLevel: 2)]
        editor.load(blocks: source)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        editor.toggleBold()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        editor.clearFormatting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertTrue(editor.formatState.bold)
        let result = try editor.snapshot()
        XCTAssertEqual(result.map(\.id), source.map(\.id))
        XCTAssertEqual(result.map(\.kind), source.map(\.kind))
        XCTAssertEqual(result.map(\.indentLevel), source.map(\.indentLevel))
        XCTAssertTrue(result[0].isChecked)
    }

    func testReplacingFirstParagraphWithRichPasteKeepsDistantCompletedTaskIdentity() throws {
        let editor = NoteEditorViewController()
        let source = [NoteBlock(text: "第一段"), NoteBlock(text: "中间段"), NoteBlock(kind: .checklist, text: "完成项", isChecked: true)]
        editor.load(blocks: source)
        editor.textView.insertText(NSAttributedString(string: "粘贴", attributes: [.font: NSFont.systemFont(ofSize: 19)]), replacementRange: NSRange(location: 0, length: 3))
        for _ in 0..<2 {
            let result = try editor.snapshot()
            XCTAssertEqual(result.map(\.id), source.map(\.id))
            XCTAssertEqual(result.map(\.kind), source.map(\.kind))
            XCTAssertTrue(result[2].isChecked)
            XCTAssertEqual(result[0].text, "粘贴")
        }
    }

    func testNativeWindowEmptyListBackspaceHasItsOwnUndoEvent() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.load(blocks: [NoteBlock(text: "先前文字")])
        window.makeFirstResponder(editor.textView)
        editor.textView.insertNewline(nil)
        editor.apply(.checklist)
        editor.indent()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.textView.undoManager?.undo()
        let result = try editor.snapshot()
        XCTAssertEqual(result.last?.kind, .checklist)
        XCTAssertEqual(result.last?.indentLevel, 1)
        XCTAssertEqual(result.map(\.text), ["先前文字", ""])
    }

    func testReplacingRenderedQuoteWithMarkedTextKeepsRenderingValid() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.load(blocks: [NoteBlock(kind: .quote, text: String(repeating: "多行引用。", count: 80))])
        window.makeFirstResponder(editor.textView)
        window.contentView?.layoutSubtreeIfNeeded()
        let view = editor.textView
        let rect = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let length = view.string.utf16.count
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: length))
        view.cacheDisplay(in: rect, to: bitmap)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, "ni")
        XCTAssertEqual(editor.formatState.kind, .quote)
        editor.commitPendingInput()
        XCTAssertEqual(try editor.snapshot().first?.kind, .quote)
    }

    func testRTFImportKeepsFirstParagraphAndDistantCompletedTaskIdentity() throws {
        let editor = NoteEditorViewController()
        let source = [NoteBlock(text: "第一段"), NoteBlock(text: "中间段"), NoteBlock(kind: .checklist, text: "完成项", isChecked: true)]
        editor.load(blocks: source)
        let rich = NSAttributedString(string: "RTF内容", attributes: [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor.systemBlue])
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let imported = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.textView.insertText(imported, replacementRange: editor.textView.selectedRange())
        for _ in 0..<2 {
            let result = try editor.snapshot()
            XCTAssertEqual(result.map(\.id), source.map(\.id))
            XCTAssertEqual(result.map(\.kind), source.map(\.kind))
            XCTAssertTrue(result[2].isChecked)
            XCTAssertEqual(result[0].text, "RTF内容")
        }
    }

}
