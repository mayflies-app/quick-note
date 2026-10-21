import AppKit
import XCTest
@testable import QuickNote
import QuickNoteCore

@MainActor
final class EditorSnapshotCacheTests: XCTestCase {
    private func assertEquivalent(_ actual: [NoteBlock], _ expected: [NoteBlock], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualBlock, expectedBlock) in zip(actual, expected) {
            var actualMetadata = actualBlock
            var expectedMetadata = expectedBlock
            actualMetadata.richText = nil
            expectedMetadata.richText = nil
            XCTAssertEqual(actualMetadata, expectedMetadata, file: file, line: line)
            if let actualData = actualBlock.richText, let expectedData = expectedBlock.richText {
                let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
                let actualRich = try NSMutableAttributedString(data: actualData, options: options, documentAttributes: nil)
                let expectedRich = try NSMutableAttributedString(data: expectedData, options: options, documentAttributes: nil)
                EditorDocumentCodec.restoreSemanticColors(in: actualRich, rtf: actualData)
                EditorDocumentCodec.restoreSemanticColors(in: expectedRich, rtf: expectedData)
                XCTAssertTrue(actualRich.isEqual(to: expectedRich), file: file, line: line)
            } else {
                XCTAssertEqual(actualBlock.richText, expectedBlock.richText, file: file, line: line)
            }
        }
    }

    private func document(_ blocks: [NoteBlock]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in blocks.enumerated() {
            var attributes = EditorDocumentCodec.attributes(for: block)
            attributes[.font] = NSFont.systemFont(ofSize: 17)
            attributes[.foregroundColor] = NSColor.textColor
            result.append(NSAttributedString(string: block.text + (index + 1 < blocks.count ? "\n" : ""), attributes: attributes))
        }
        if let last = blocks.last, last.text.isEmpty, result.length > 0 {
            result.addAttributes([
                EditorDocumentCodec.tailID: last.id.uuidString,
                EditorDocumentCodec.tailKind: last.kind.rawValue,
                EditorDocumentCodec.tailChecked: last.isChecked,
                EditorDocumentCodec.tailIndent: last.indentLevel
            ], range: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    func testUnchangedParagraphsReuseRTFAndOnlyChangedParagraphEncodes() throws {
        let blocks = [NoteBlock(text: "first"), NoteBlock(text: "second"), NoteBlock(text: "")]
        let text = document(blocks)
        let cache = EditorSnapshotCache()
        let initial = try cache.snapshot(text, emptyBlock: blocks.last!)
        XCTAssertEqual(cache.encodingCount, 2)
        XCTAssertEqual(try cache.snapshot(text, emptyBlock: blocks.last!), initial)
        XCTAssertEqual(cache.encodingCount, 2)
        text.replaceCharacters(in: NSRange(location: 7, length: 1), with: "X")
        let changed = try cache.snapshot(text, emptyBlock: blocks.last!)
        XCTAssertEqual(cache.encodingCount, 3)
        XCTAssertEqual(changed.first?.richText, initial.first?.richText)
        XCTAssertEqual(changed.last?.id, blocks.last?.id)
        XCTAssertNil(changed.last?.richText)
        try assertEquivalent(changed, EditorDocumentCodec.snapshot(text, emptyBlock: blocks.last!))
    }

    func testMetadataChangesDoNotReencodeButAllInlineAttributesDo() throws {
        let block = NoteBlock(text: "中文 ABC")
        let text = document([block])
        let cache = EditorSnapshotCache()
        let first = try cache.snapshot(text, emptyBlock: block)
        let full = NSRange(location: 0, length: text.length)
        text.addAttributes([EditorDocumentCodec.kind: BlockKind.checklist.rawValue,
                            EditorDocumentCodec.checked: true, EditorDocumentCodec.indent: 2], range: full)
        let metadata = try cache.snapshot(text, emptyBlock: block)
        XCTAssertEqual(cache.encodingCount, 1)
        XCTAssertEqual(metadata.first?.richText, first.first?.richText)
        XCTAssertEqual(metadata.first?.kind, .checklist)
        XCTAssertEqual(metadata.first?.isChecked, true)
        XCTAssertEqual(metadata.first?.indentLevel, 2)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let changes: [(NSAttributedString.Key, Any)] = [
            (.font, NSFont.boldSystemFont(ofSize: 19)),
            (.foregroundColor, NSColor.systemRed),
            (.backgroundColor, EditorHighlight.purple.color),
            (.link, URL(string: "https://example.com")!),
            (.underlineStyle, NSUnderlineStyle.single.rawValue),
            (.strikethroughStyle, NSUnderlineStyle.single.rawValue),
            (.paragraphStyle, paragraphStyle)
        ]
        for (index, change) in changes.enumerated() {
            text.addAttribute(change.0, value: change.1, range: NSRange(location: 0, length: 1))
            let snapshot = try cache.snapshot(text, emptyBlock: block)
            XCTAssertEqual(cache.encodingCount, index + 2)
            try assertEquivalent(snapshot, EditorDocumentCodec.snapshot(text, emptyBlock: block))
        }
    }

    func testDeletedAndReinsertedIDDoesNotReuseStaleContentAndResetDropsCache() throws {
        let first = NoteBlock(text: "first")
        let second = NoteBlock(text: "second")
        let cache = EditorSnapshotCache()
        _ = try cache.snapshot(document([first, second]), emptyBlock: second)
        XCTAssertEqual(cache.encodingCount, 2)
        _ = try cache.snapshot(document([first]), emptyBlock: first)
        XCTAssertEqual(cache.cachedParagraphCount, 1)
        var replacement = second
        replacement.text = "replacement"
        let replaced = try cache.snapshot(document([first, replacement]), emptyBlock: replacement)
        XCTAssertEqual(cache.encodingCount, 3)
        try assertEquivalent(replaced, EditorDocumentCodec.snapshot(document([first, replacement]), emptyBlock: replacement))
        let undone = try cache.snapshot(document([first, second]), emptyBlock: second)
        XCTAssertEqual(cache.encodingCount, 4)
        XCTAssertEqual(undone.map(\.text), ["first", "second"])
        cache.reset()
        XCTAssertEqual(cache.cachedParagraphCount, 0)
        _ = try cache.snapshot(document([first, second]), emptyBlock: second)
        XCTAssertEqual(cache.encodingCount, 2)
    }

    func testLocalParagraphMatchesFullParserAtEveryUTF16Boundary() throws {
        for content in ["", "a", "a\n", "\n\n", "中文 👩🏽‍💻\nsoft\u{2028}line\n尾段", "a\r\nb\n"] {
            let blocks = content.components(separatedBy: "\n").enumerated().map { index, text in
                NoteBlock(kind: index % 2 == 0 ? .body : .checklist, text: text, isChecked: index % 2 == 1, indentLevel: index % 3)
            }
            let text = document(blocks)
            let all = EditorDocumentCodec.paragraphs(in: text, emptyBlock: blocks.last!)
            for position in 0...text.length {
                let expected = all.last { $0.range.location <= position }!
                let actual = EditorDocumentCodec.paragraph(at: position, in: text, emptyBlock: blocks.last!)
                XCTAssertEqual(actual.range, expected.range, "\(content.debugDescription) at \(position)")
                XCTAssertEqual(actual.contentRange, expected.contentRange)
                XCTAssertEqual(actual.block, expected.block)
            }
        }
    }

    func testEmptyDocumentDoesNotKeepFallbackRichText() throws {
        var fallback = NoteBlock(text: "old text")
        fallback.richText = try EditorDocumentCodec.snapshot(document([fallback]), emptyBlock: fallback).first?.richText
        let empty = NSAttributedString(string: "")
        let cache = EditorSnapshotCache()
        let cached = try cache.snapshot(empty, emptyBlock: fallback)
        XCTAssertEqual(cached.first?.text, "")
        XCTAssertNil(cached.first?.richText)
        try assertEquivalent(cached, EditorDocumentCodec.snapshot(empty, emptyBlock: fallback))
    }

    func testMutableParagraphStyleDoesNotMutateCachedFingerprint() throws {
        let block = NoteBlock(text: "aligned")
        let text = document([block])
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let cache = EditorSnapshotCache()
        _ = try cache.snapshot(text, emptyBlock: block)
        style.alignment = .right
        let changed = try cache.snapshot(text, emptyBlock: block)
        XCTAssertEqual(cache.encodingCount, 2)
        try assertEquivalent(changed, EditorDocumentCodec.snapshot(text, emptyBlock: block))
    }

    func testFailedEncodingDoesNotCommitPartialSnapshot() throws {
        let cache = EditorSnapshotCache { rich in
            if rich.string == "fail" { throw CocoaError(.fileWriteUnknown) }
            return try EditorDocumentCodec.richTextData(rich)
        }
        let first = NoteBlock(text: "first")
        let second = NoteBlock(text: "second")
        let initial = try cache.snapshot(document([first, second]), emptyBlock: second)
        var changedFirst = first
        changedFirst.text = "changed"
        var changedSecond = second
        changedSecond.text = "fail"
        XCTAssertThrowsError(try cache.snapshot(document([changedFirst, changedSecond]), emptyBlock: changedSecond))
        XCTAssertEqual(cache.encodingCount, 2)
        XCTAssertEqual(cache.cachedParagraphCount, 2)
        XCTAssertEqual(try cache.snapshot(document([first, second]), emptyBlock: second), initial)
        XCTAssertEqual(cache.encodingCount, 2)
        let recovered = try cache.snapshot(document([changedFirst, second]), emptyBlock: second)
        XCTAssertEqual(cache.encodingCount, 3)
        try assertEquivalent(recovered, EditorDocumentCodec.snapshot(document([changedFirst, second]), emptyBlock: second))
    }
}
