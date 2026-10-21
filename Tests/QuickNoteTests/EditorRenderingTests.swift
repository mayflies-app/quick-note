import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class EditorRenderingTests: XCTestCase {
    func testListGuttersAreCompactAndWrappedLinesHaveOneTextOrigin() throws {
        var gutters: [CGFloat] = []
        for kind in [BlockKind.bullet, .dashed, .numbered, .checklist] {
            let editor = NoteEditorViewController()
            editor.load(blocks: [NoteBlock(kind: kind, text: "需要换行的列表内容", indentLevel: 0)])
            let style = try XCTUnwrap(editor.textView.attributedString().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            gutters.append(style.headIndent)
            XCTAssertLessThanOrEqual(style.headIndent, 28, "Lists should reserve a compact marker column")
            XCTAssertEqual(style.firstLineHeadIndent, style.headIndent, "Wrapped text must align with the first line")
            XCTAssertLessThanOrEqual(style.paragraphSpacing, 4, "List items should not use the wider body paragraph gap")
        }
        XCTAssertEqual(Set(gutters).count, 1)
    }

    func testSwitchingQuoteStyleUpdatesOnlyDefaultForegroundColors() throws {
        let editor = NoteEditorViewController()
        editor.load(blocks: [NoteBlock(text: "默认颜色 自定义颜色")])
        let customRange = (editor.textView.string as NSString).range(of: "自定义颜色")
        editor.textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed, range: customRange)
        editor.apply(.quote)
        XCTAssertEqual(editor.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        XCTAssertEqual(editor.textView.attributedString().attribute(.foregroundColor, at: customRange.location, effectiveRange: nil) as? NSColor, .systemRed)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.textView.typingAttributes[.foregroundColor] as? NSColor, .secondaryLabelColor)
        editor.apply(.body)
        XCTAssertEqual(editor.textView.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(editor.textView.attributedString().attribute(.foregroundColor, at: customRange.location, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testAllTenKindsHaveExpectedNativeTypographyAndStableRoundTrip() throws {
        let expectedSizes: [BlockKind: CGFloat] = [.title: 27, .heading: 21, .subheading: 18, .body: 17, .bullet: 17, .dashed: 17, .numbered: 17, .checklist: 17, .quote: 17, .code: 15]
        for kind in BlockKind.allCases {
            let editor = NoteEditorViewController()
            let block = NoteBlock(kind: kind, text: "字形 Typography", isChecked: kind == .checklist, indentLevel: 1)
            editor.load(blocks: [block])
            let saved = try editor.snapshot()
            let restored = NoteEditorViewController()
            restored.load(blocks: saved)
            for view in [editor.textView, restored.textView] {
                let font = try XCTUnwrap(view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, expectedSizes[kind])
                XCTAssertFalse(font.fontName.lowercased().contains("times"))
                XCTAssertFalse(font.fontName.hasPrefix(".PingFangUI"))
                let latinFont = try XCTUnwrap(view.attributedString().attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(latinFont.fontDescriptor.symbolicTraits.contains(.monoSpace), kind == .code)
                let style = try XCTUnwrap(view.attributedString().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertGreaterThanOrEqual(style.lineSpacing, 0)
                XCTAssertLessThanOrEqual(style.lineSpacing, 3)
            }
            XCTAssertEqual(saved.first?.id, block.id)
            XCTAssertEqual(saved.first?.kind, kind)
            XCTAssertEqual(saved.first?.isChecked, block.isChecked)
        }
    }

    func testHeadingToQuoteOrCodeDoesNotKeepImplicitHeadingWeight() throws {
        for heading in [BlockKind.title, .heading, .subheading] {
            for destination in [BlockKind.quote, .code] {
                let editor = NoteEditorViewController()
                editor.load(blocks: [NoteBlock(kind: heading, text: "标题 code")])
                editor.apply(destination)
                let font = try XCTUnwrap(editor.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))
                XCTAssertEqual(font.pointSize, destination == .code ? 15 : 17)
                let latinFont = try XCTUnwrap(editor.textView.attributedString().attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(latinFont.fontDescriptor.symbolicTraits.contains(.monoSpace), destination == .code)
            }
        }
    }
    func testNativeMarkersShareTextGapBaselineAndNestedAlignment() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.view.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let kinds: [BlockKind] = [.bullet, .dashed, .numbered, .checklist]
        let text = "Wrapped text " + String(repeating: "continues here ", count: 12)
        editor.load(blocks: kinds.map { NoteBlock(kind: $0, text: text) } + [NoteBlock(kind: .dashed, text: "Nested", indentLevel: 1)])
        window.contentView?.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(editor.textView.layoutManager)
        let container = try XCTUnwrap(editor.textView.textContainer)
        layout.ensureLayout(for: container)
        var location = 0
        var firstTextStart: CGFloat?
        for kind in kinds {
            let geometry = try XCTUnwrap(editor.markerGeometry(at: location))
            XCTAssertEqual(geometry.textStart - geometry.frame.maxX, 6, accuracy: 0.01)
            if let firstTextStart { XCTAssertEqual(geometry.textStart, firstTextStart, accuracy: 0.01) }
            else { firstTextStart = geometry.textStart }
            let firstGlyph = layout.glyphIndexForCharacter(at: location)
            var lineRange = NSRange()
            let firstFragment = layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: &lineRange)
            let firstPosition = layout.location(forGlyphAt: firstGlyph)
            XCTAssertEqual(geometry.baseline, editor.textView.textContainerOrigin.y + firstFragment.minY + firstPosition.y, accuracy: 0.01)
            let nextFragment = layout.lineFragmentRect(forGlyphAt: NSMaxRange(lineRange), effectiveRange: nil)
            let nextPosition = layout.location(forGlyphAt: NSMaxRange(lineRange))
            XCTAssertEqual(firstFragment.minX + firstPosition.x, nextFragment.minX + nextPosition.x, accuracy: 0.01, "Wrapped lines must share the same text origin")
            if kind == .checklist { XCTAssertEqual(geometry.frame.width, 15) }
            if kind == .dashed { XCTAssertLessThanOrEqual(geometry.frame.width, 7) }
            location += text.utf16.count + 1
        }
        let nested = try XCTUnwrap(editor.markerGeometry(at: location))
        XCTAssertEqual(nested.textStart - firstTextStart!, 22, accuracy: 0.01)
    }

    func testLongNumberMarkersKeepReadableSizeAndNeverTouchText() throws {
        let editor = NoteEditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        editor.view.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        editor.load(blocks: [NoteBlock(kind: .numbered, text: "编号边界 Number")])
        window.contentView?.layoutSubtreeIfNeeded()
        for number in [1, 9, 10, 99, 1000, 999999] {
            let geometry = try XCTUnwrap(editor.markerGeometry(at: 0, number: number))
            XCTAssertEqual(geometry.textStart - geometry.frame.maxX, 6, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(geometry.frame.minX, 2)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry.font).pointSize, 9)
            if number <= 99 { XCTAssertEqual(geometry.font?.pointSize, 13) }
        }
    }

    func testMultilineQuoteRuleSpansContentInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let editor = NoteEditorViewController()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentViewController = editor
                editor.view.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
                editor.load(blocks: [NoteBlock(kind: .quote, text: String(repeating: "多行引用 Quote text ", count: 12))])
                window.contentView?.layoutSubtreeIfNeeded()
                guard let geometry = editor.markerGeometry(at: 0) else { return XCTFail("Quote needs a visible rule") }
                XCTAssertEqual(geometry.frame.width, 2)
                XCTAssertGreaterThan(geometry.frame.height, 60)
                XCTAssertEqual(geometry.textStart - geometry.frame.maxX, 10, accuracy: 0.01)
                let color = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)!
                if name == .darkAqua { XCTAssertGreaterThan(color.redComponent, 0.7) }
                else { XCTAssertLessThan(color.redComponent, 0.3) }
            }
        }
    }

    func testAlignedQuoteRuleStaysOutsideEverySoftWrappedLine() throws {
        for alignment in [NSTextAlignment.center, .right] {
            let editor = NoteEditorViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = editor
            editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            let text = "短句\u{2028}这是一段比较长的引用文字，用来检查混合长短行时竖线是否穿过正文。"
            editor.load(blocks: [NoteBlock(kind: .quote, text: text)])
            editor.setAlignment(alignment)
            window.contentView?.layoutSubtreeIfNeeded()
            let geometry = try XCTUnwrap(editor.markerGeometry(at: 0))
            let layout = try XCTUnwrap(editor.textView.layoutManager)
            let container = try XCTUnwrap(editor.textView.textContainer)
            layout.ensureLayout(for: container)
            var glyph = 0
            var minimumTextX = CGFloat.greatestFiniteMagnitude
            while glyph < layout.numberOfGlyphs {
                var range = NSRange()
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
                let position = layout.location(forGlyphAt: glyph)
                let textX = editor.textView.textContainerOrigin.x + fragment.minX + position.x
                minimumTextX = min(minimumTextX, textX)
                XCTAssertLessThanOrEqual(geometry.frame.maxX + 9.9, textX, "The rule must remain to the left of every line")
                glyph = NSMaxRange(range)
            }
            XCTAssertEqual(minimumTextX - geometry.frame.maxX, 10, accuracy: 0.01)
            let contentBounds = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), in: container)
            XCTAssertEqual(geometry.frame.height, contentBounds.height, accuracy: 0.01)
            XCTAssertEqual(try editor.snapshot().first?.text, text)
            XCTAssertEqual(editor.formatState.alignment, alignment)
        }
    }

}
