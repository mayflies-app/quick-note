import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class EditorTests: XCTestCase {
    func testUnicodeAndTrailingEmptyParagraphRoundTrip() throws {
        let editor = NoteEditorViewController()
        let blocks = [NoteBlock(kind: .title, text: "日记 👩🏽‍💻"), NoteBlock(kind: .body, text: "第二段 café"), NoteBlock(kind: .body, text: "")]
        editor.load(blocks: blocks)
        let restored = try editor.snapshot()
        XCTAssertEqual(restored.map(\.text), blocks.map(\.text))
        XCTAssertEqual(restored.map(\.id), blocks.map(\.id))
        XCTAssertEqual(restored.map(\.kind), blocks.map(\.kind))
    }

    func testChecklistAndInlineFormattingRoundTrip() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .checklist, text: "Buy milk", isChecked: true)])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.toggleBold()
        let block = try XCTUnwrap(editor.snapshot().first)
        XCTAssertTrue(block.isChecked)
        XCTAssertEqual(block.kind, .checklist)
        let rich = try XCTUnwrap(block.richText)
        let attributed = try NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let second = NoteEditorViewController()
        second.load(blocks: [block])
        XCTAssertEqual(try second.snapshot().first?.isChecked, true)
    }

    func testSplittingParagraphCreatesUniqueIDAndKeepsOriginal() throws {
        let editor = NoteEditorViewController()
        let block = NoteBlock(kind: .bullet, text: "abcd")
        editor.load(blocks: [block])
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textView.insertNewline(nil)
        let blocks = try editor.snapshot()
        XCTAssertEqual(blocks.map(\.text), ["ab", "cd"])
        XCTAssertEqual(blocks.map(\.kind), [.bullet, .bullet])
        XCTAssertEqual(blocks.first?.id, block.id)
        XCTAssertEqual(Set(blocks.map(\.id)).count, 2)
    }

    func testNewChecklistItemIsUncheckedAndEmptyReturnExitsList() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .checklist, text: "Done", isChecked: true)])
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.insertNewline(nil)
        var blocks = try editor.snapshot()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last?.kind, .checklist)
        XCTAssertEqual(blocks.last?.isChecked, false)
        editor.textView.insertNewline(nil)
        blocks = try editor.snapshot()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last?.kind, .body)
        XCTAssertEqual(blocks.last?.text, "")
    }


    func testReturnAfterTitleAndHeadingStartsBody() throws {
        for kind in [BlockKind.title, .heading, .subheading] {
            let editor = NoteEditorViewController()
            editor.load(blocks: [NoteBlock(kind: kind, text: "标题")])
            editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
            editor.textView.insertNewline(nil)
            editor.textView.insertText("正文", replacementRange: editor.textView.selectedRange())
            let blocks = try editor.snapshot()
            XCTAssertEqual(blocks.map(\.kind), [kind, .body])
            XCTAssertEqual(blocks.map(\.text), ["标题", "正文"])
            let font = editor.textView.attributedString().attribute(.font, at: 3, effectiveRange: nil) as? NSFont
            XCTAssertEqual(font?.pointSize, 17)
            XCTAssertFalse(NSFontManager.shared.traits(of: font!).contains(.boldFontMask))
        }
    }


    func testMergingParagraphsKeepsFirstIDAndOtherIDsStable() throws {
        let editor = NoteEditorViewController()
        let blocks = [NoteBlock(text: "first"), NoteBlock(kind: .bullet, text: "second"), NoteBlock(text: "third")]
        editor.load(blocks: blocks)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 1))
        editor.textView.insertText("", replacementRange: editor.textView.selectedRange())
        let restored = try editor.snapshot()
        XCTAssertEqual(restored.map(\.text), ["firstsecond", "third"])
        XCTAssertEqual(restored.map(\.id), [blocks[0].id, blocks[2].id])
    }

    func testFormattingAndCheckingAtDocumentEnd() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "abc")])
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.apply(.title)
        XCTAssertEqual(try editor.snapshot().first?.kind, .title)
        editor.toggleChecklist()
        XCTAssertEqual(try editor.snapshot().first?.kind, .checklist)
        editor.toggleChecked()
        XCTAssertEqual(try editor.snapshot().first?.isChecked, true)
    }

    func testMixedSemanticsAndEmptyTrailingParagraphRoundTrip() throws {
        for kind in [BlockKind.title, .checklist] {
            let editor = NoteEditorViewController()
            let blocks = [NoteBlock(kind: kind, text: "前段", isChecked: kind == .checklist), NoteBlock(kind: .body, text: "")]
            editor.load(blocks: blocks)
            let restored = try editor.snapshot()
            XCTAssertEqual(restored.map(\.kind), [kind, .body])
            XCTAssertEqual(restored.map(\.id), blocks.map(\.id))
            XCTAssertEqual(restored.last?.isChecked, false)
        }
    }

    func testFormattingEmptyTrailingParagraphAndUndo() throws {
        let editor = NoteEditorViewController()
        let blocks = [NoteBlock(text: "first"), NoteBlock(text: "")]
        editor.load(blocks: blocks)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        editor.apply(.checklist)
        XCTAssertEqual(try editor.snapshot().last?.kind, .checklist)
        editor.toggleChecked()
        XCTAssertEqual(try editor.snapshot().last?.isChecked, true)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().last?.isChecked, false)
    }

    func testLinksAndItalicSurviveStructuredRoundTrip() throws {
        let rich = NSMutableAttributedString(string: "苹果文档")
        rich.addAttributes([.link: URL(string: "https://developer.apple.com")!, .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 17), toHaveTrait: .italicFontMask)], range: NSRange(location: 0, length: rich.length))
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .quote, text: rich.string, richText: data)])
        let block = try XCTUnwrap(editor.snapshot().first)
        let serialized = try NSAttributedString(data: XCTUnwrap(block.richText), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertNotNil(serialized.attribute(.link, at: 0, effectiveRange: nil))
        let font = try XCTUnwrap(serialized.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask) || ((serialized.attribute(.obliqueness, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0) > 0, "Italic appearance must survive native CJK font fallback")
        XCTAssertEqual(block.kind, .quote)
    }

    func testChineseSystemTypographySurvivesRTFRoundTrip() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "快捷备忘录")])
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.apply(.title)
        editor.textView.insertNewline(nil)
        editor.textView.insertText("今天的记录", replacementRange: editor.textView.selectedRange())
        editor.textView.insertNewline(nil)
        editor.toggleChecklist()
        editor.textView.insertText("完成工作", replacementRange: editor.textView.selectedRange())
        let saved = try editor.snapshot()
        XCTAssertEqual(saved.map(\.kind), [.title, .body, .checklist])
        let restored = NoteEditorViewController()
        restored.load(blocks: saved)
        for view in [editor.textView, restored.textView] {
            view.attributedString().enumerateAttribute(.font, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                let font = value as! NSFont
                XCTAssertFalse(font.fontName.lowercased().contains("times"), "Unexpected serif fallback: \(font.fontName)")
                XCTAssertFalse(font.fontName.hasPrefix(".PingFangUI"), "Private font aliases can render as Times when converted: \(font.fontName)")
                if range.location >= 6 {
                    XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Body and task text must stay regular: \(font.fontName)")
                    XCTAssertEqual(font.pointSize, 17)
                }
            }
        }
        for block in saved {
            let rich = try XCTUnwrap(block.richText)
            let rtf = String(decoding: rich, as: UTF8.self)
            XCTAssertFalse(rtf.contains(".PingFangUI"), "Internal UI font names must not enter persistent RTF")
        }
    }

    func testCodeRemainsMonospacedAfterRTFRoundTrip() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "let value = 42")])
        editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
        editor.apply(.code)
        let saved = try editor.snapshot()
        let restored = NoteEditorViewController()
        restored.load(blocks: saved)
        for view in [editor.textView, restored.textView] {
            let font = try XCTUnwrap(view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace), "Code must remain monospaced: \(font.fontName)")
            XCTAssertEqual(font.pointSize, 15)
        }
    }

    func testOrdinaryBodyReturnPreservesInlineBold() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "abcXYZ")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
        editor.toggleBold()
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.textView.insertNewline(nil)
        let blocks = try editor.snapshot()
        XCTAssertEqual(blocks.map(\.text), ["abc", "XYZ"])
        let font = try XCTUnwrap(editor.textView.attributedString().attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Splitting regular body must retain inline formatting")
    }

    func testNativeUndoRestoresTypedText() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "hello")])
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.textView.insertText(" world", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(try editor.snapshot().first?.text, "hello world")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().first?.text, "hello")
    }
    func testMixedSelectionBecomesUniformlyBoldThenClears() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "one two")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.toggleBold()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        editor.toggleBold()
        XCTAssertTrue(editor.formatState.bold)
        editor.textView.attributedString().enumerateAttribute(.font, in: NSRange(location: 0, length: 7)) { font, _, _ in
            XCTAssertTrue((font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
        editor.toggleBold()
        XCTAssertFalse(editor.formatState.bold)
    }

    func testHighlightStrikeLinkColorAndAlignmentSurviveTypingAndReload() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "记录 café")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        editor.toggleStrikethrough()
        editor.setHighlight(.mint)
        editor.setLink(URL(string: "https://developer.apple.com"))
        editor.setAlignment(.center)
        editor.textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 7))
        editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        let restored = NoteEditorViewController()
        restored.load(blocks: try editor.snapshot())
        restored.textView.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertTrue(restored.formatState.strikethrough)
        XCTAssertEqual(restored.formatState.highlight, .mint)
        XCTAssertEqual((restored.textView.attributedString().attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0, 0.24, accuracy: 0.01)
        XCTAssertEqual(restored.formatState.alignment, .center)
        XCTAssertNotNil(restored.textView.attributedString().attribute(.link, at: 0, effectiveRange: nil))
        let color = try XCTUnwrap(restored.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertGreaterThan(try XCTUnwrap(color.usingColorSpace(.deviceRGB)).redComponent, 0.7)
    }

    func testNestedListSoftReturnAndEmptyReturnRetainStructure() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .dashed, text: "第一项", indentLevel: 1)])
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.textView.insertLineBreak(nil)
        editor.textView.insertText("续行", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(try editor.snapshot().map(\.text), ["第一项\u{2028}续行"])
        editor.textView.insertNewline(nil)
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 1)
        editor.textView.insertNewline(nil)
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 0)
        XCTAssertEqual(try editor.snapshot().last?.kind, .dashed)
        editor.textView.insertNewline(nil)
        XCTAssertEqual(try editor.snapshot().last?.kind, .body)
        let saved = try editor.snapshot()
        let restored = NoteEditorViewController()
        restored.load(blocks: saved)
        XCTAssertEqual(try restored.snapshot().map(\.indentLevel), saved.map(\.indentLevel))
        XCTAssertEqual(try restored.snapshot().map(\.text), saved.map(\.text))
    }

    func testTabIndentsListAndBacktabOutdentsWithoutTextMutation() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .numbered, text: "Task")])
        editor.textView.insertTab(nil)
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 1)
        XCTAssertEqual(try editor.snapshot().first?.text, "Task")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.textView.insertBacktab(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 0)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 1)
    }

    func testListPrefixesConvertWithoutPersistingMarkerCharacters() throws {
        for (prefix, kind) in [("*", BlockKind.bullet), ("-", .dashed), ("1.", .numbered)] {
            let editor = NoteEditorViewController()
            editor.load(blocks: [NoteBlock()])
            editor.textView.insertText(prefix, replacementRange: editor.textView.selectedRange())
            editor.textView.insertText(" ", replacementRange: editor.textView.selectedRange())
            editor.textView.insertText("事项", replacementRange: editor.textView.selectedRange())
            XCTAssertEqual(try editor.snapshot().first?.kind, kind)
            XCTAssertEqual(try editor.snapshot().first?.text, "事项")
        }
    }

    func testSubheadingAndEmptyIndentPersistAndClearFormatUndo() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(kind: .subheading, text: "小标题"), NoteBlock(kind: .checklist, indentLevel: 2)])
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 2)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        editor.toggleUnderline()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.clearFormatting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(try editor.snapshot().first?.kind, .body)
        XCTAssertEqual(try editor.snapshot().last?.indentLevel, 2, "Clearing another paragraph must leave the empty trailing task unchanged")
        XCTAssertFalse(editor.formatState.underline)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(try editor.snapshot().first?.kind, .subheading)
        XCTAssertTrue(editor.formatState.underline)
    }

    func testImportedExplicitForegroundColorsRemainUnchangedWithoutAppMetadata() throws {
        let original = NSMutableAttributedString(string: "ABC", attributes: [
            .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black
        ])
        original.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0.008, green: 0.008, blue: 0.008, alpha: 1),
                              range: NSRange(location: 1, length: 1))
        original.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0.78, green: 0.18, blue: 0.24, alpha: 1),
                              range: NSRange(location: 2, length: 1))
        // Standard imported RTF has explicit colors and no application-specific role metadata.
        let rtf = try original.data(from: NSRange(location: 0, length: original.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let imported = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var blocks = [NoteBlock(text: "ABC", richText: rtf)]
        for _ in 0..<2 {
            let editor = NoteEditorViewController()
            editor.load(blocks: blocks)
            let actualText = editor.textView.attributedString()
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for position in 0..<3 {
                    let actualColor = try XCTUnwrap(actualText.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor)
                    let expectedColor = try XCTUnwrap(imported.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor)
                    var actual: NSColor?
                    var expected: NSColor?
                    appearance.performAsCurrentDrawingAppearance {
                        actual = actualColor.usingColorSpace(.deviceRGB)
                        expected = expectedColor.usingColorSpace(.deviceRGB)
                    }
                    let a = try XCTUnwrap(actual)
                    let e = try XCTUnwrap(expected)
                    XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 0.01, "Explicit imported colors must not adapt to appearance")
                    XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 0.01)
                    XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 0.01)
                    XCTAssertEqual(a.alphaComponent, e.alphaComponent, accuracy: 0.01)
                }
            }
            blocks = try editor.snapshot()
        }
    }

    func testDefaultTextColorRemainsDynamicWhileExplicitBlackRemainsExplicit() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "Default explicit")])
        editor.textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 8, length: 8))
        let saved = try editor.snapshot()
        let restored = NoteEditorViewController()
        restored.load(blocks: saved)
        let text = restored.textView.attributedString()
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertNotEqual(text.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor, .textColor)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var darkDefault: CGFloat = 0
        var darkExplicit: CGFloat = 1
        dark.performAsCurrentDrawingAppearance {
            darkDefault = (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).usingColorSpace(.deviceRGB)!.redComponent
            darkExplicit = (text.attribute(.foregroundColor, at: 8, effectiveRange: nil) as! NSColor).usingColorSpace(.deviceRGB)!.redComponent
        }
        XCTAssertGreaterThan(darkDefault, 0.7)
        XCTAssertLessThan(darkExplicit, 0.1)
        let second = NoteEditorViewController()
        second.load(blocks: try restored.snapshot())
        XCTAssertEqual(second.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
    }

    func testFontAndColorPanelActionsPublishAndPreserveAcrossReload() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "Font color")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        var changes = 0
        editor.onChange = { _ in changes += 1 }
        let manager = NSFontManager.shared
        let originalTarget = manager.target
        let originalAction = manager.action
        defer { manager.target = originalTarget; manager.action = originalAction }
        manager.target = editor.textView
        manager.action = #selector(NSTextView.changeFont(_:))
        let larger = NSMenuItem(title: "Bigger", action: nil, keyEquivalent: "")
        larger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        manager.modifyFont(larger)
        XCTAssertGreaterThan(changes, 0, "Native font-panel changes must enter autosave")
        let size = try XCTUnwrap(editor.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        XCTAssertGreaterThan(size, 17)
        editor.indent()
        XCTAssertEqual((editor.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, size, "Changing indentation must preserve custom font size")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let panel = NSColorPanel.shared
        panel.color = .systemRed
        let before = changes
        editor.textView.changeColor(panel)
        XCTAssertGreaterThan(changes, before, "Native color-panel changes must enter autosave")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let restored = NoteEditorViewController()
        restored.load(blocks: try editor.snapshot())
        XCTAssertEqual((restored.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, size)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
    }

    func testParagraphBoundarySelectionDoesNotFormatNextParagraph() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "one"), NoteBlock(text: "two")])
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        editor.apply(.subheading)
        editor.indent()
        editor.setAlignment(.right)
        let blocks = try editor.snapshot()
        XCTAssertEqual(blocks.map(\.kind), [.subheading, .body])
        XCTAssertEqual(blocks.map(\.indentLevel), [1, 0])
        let secondStyle = editor.textView.attributedString().attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(secondStyle?.alignment, .natural)
    }

    func testChangingSemanticStyleBackToBodyRestoresBodyTypography() throws {
        for kind in [BlockKind.title, .heading, .subheading, .code] {
            let editor = NoteEditorViewController()
            editor.load(blocks: [NoteBlock(kind: kind, text: "正文")])
            editor.apply(.body)
            let font = try XCTUnwrap(editor.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 17)
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    func testNativeWindowContinuesSubheadingIntoNestedDashedList() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.load(blocks: [NoteBlock(kind: .title, text: "标题"), NoteBlock(text: "正文"), NoteBlock(kind: .checklist, text: "任务"), NoteBlock(text: "重点想法")])
        window.makeFirstResponder(editor.textView)
        let text = editor.textView
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertNewline(nil)
        text.insertText("下一段", replacementRange: text.selectedRange())
        editor.apply(.subheading)
        text.insertNewline(nil)
        text.insertText("- ", replacementRange: text.selectedRange())
        text.insertText("拆解事项", replacementRange: text.selectedRange())
        text.insertTab(nil)
        text.insertLineBreak(nil)
        text.insertText("延续同一项", replacementRange: text.selectedRange())
        let last = try XCTUnwrap(editor.snapshot().last)
        XCTAssertEqual(last.kind, .dashed)
        XCTAssertEqual(last.indentLevel, 1)
        XCTAssertEqual(last.text, "拆解事项\u{2028}延续同一项")
    }

    func testNativeOptionTabInsertsLiteralTabAndPlainTabIndents() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.load(blocks: [NoteBlock(kind: .bullet, text: "事项")])
        window.makeFirstResponder(editor.textView)
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        }
        editor.textView.keyDown(with: try event(.option))
        XCTAssertEqual(try editor.snapshot().first?.text, "事项\t")
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 0)
        editor.textView.keyDown(with: try event([]))
        XCTAssertEqual(try editor.snapshot().first?.text, "事项\t")
        XCTAssertEqual(try editor.snapshot().first?.indentLevel, 1)
    }

    func testImportedOpaqueBackgroundColorsSurviveStructuredRoundTrip() throws {
        let blue = try XCTUnwrap(NSColor.systemBlue.usingColorSpace(.deviceRGB)).withAlphaComponent(1)
        let yellow = NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.21, alpha: 1)
        let imported = NSMutableAttributedString(string: "蓝色 黄色", attributes: [.font: NSFont.systemFont(ofSize: 17)])
        imported.addAttribute(.backgroundColor, value: blue, range: NSRange(location: 0, length: 2))
        imported.addAttribute(.backgroundColor, value: yellow, range: NSRange(location: 3, length: 2))
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock()])
        editor.textView.insertText(imported, replacementRange: editor.textView.selectedRange())
        var saved = try editor.snapshot()
        for _ in 0..<2 {
            let restored = NoteEditorViewController()
            restored.load(blocks: saved)
            for (position, original) in [(0, blue), (3, yellow)] {
                let color = try XCTUnwrap(restored.textView.attributedString().attribute(.backgroundColor, at: position, effectiveRange: nil) as? NSColor)
                let actual = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                let expected = try XCTUnwrap(original.usingColorSpace(.deviceRGB))
                XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01, "Imported opaque colors must not become native translucent highlights")
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.015)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.015)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.015)
            }
            restored.textView.setSelectedRange(NSRange(location: 0, length: 2))
            XCTAssertNil(restored.formatState.highlight, "An imported opaque blue background is not the native blue highlight")
            saved = try restored.snapshot()
        }
    }

    func testFiveNativeHighlightsPreserveTheirTranslucencyOnReload() throws {
        for highlight in EditorHighlight.allCases {
            let editor = NoteEditorViewController()
            editor.load(blocks: [NoteBlock(text: "高亮")])
            editor.textView.setSelectedRange(NSRange(location: 0, length: 2))
            editor.setHighlight(highlight)
            let restored = NoteEditorViewController()
            restored.load(blocks: try editor.snapshot())
            restored.textView.setSelectedRange(NSRange(location: 0, length: 2))
            XCTAssertEqual(restored.formatState.highlight, highlight)
            let color = try XCTUnwrap(restored.textView.attributedString().attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(color.alphaComponent, 0.24, accuracy: 0.01)
        }
    }

}
