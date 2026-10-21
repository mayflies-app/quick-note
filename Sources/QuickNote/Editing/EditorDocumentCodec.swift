import AppKit
import QuickNoteCore

struct EditorParagraph {
    var range: NSRange
    var contentRange: NSRange
    var block: NoteBlock
}

struct EditorDocumentCodec {
    static let id = NSAttributedString.Key("QuickNote.blockID")
    static let kind = NSAttributedString.Key("QuickNote.blockKind")
    static let checked = NSAttributedString.Key("QuickNote.blockChecked")
    static let indent = NSAttributedString.Key("QuickNote.indentLevel")
    static let tailIndent = NSAttributedString.Key("QuickNote.tailIndent")
    static let tailID = NSAttributedString.Key("QuickNote.tailID")
    static let tailKind = NSAttributedString.Key("QuickNote.tailKind")
    static let tailChecked = NSAttributedString.Key("QuickNote.tailChecked")
    static let metadataKeys = [id, kind, checked, indent, tailID, tailKind, tailChecked, tailIndent]

    enum CodecError: LocalizedError {
        case invalidRichText(UUID)
        var errorDescription: String? { description(language: .systemDefault()) }
        func description(language: AppLanguage) -> String {
            AppLocalization.text("备忘录段落的富文本无法读取。请保留数据库并检查损坏的段落。", language: language)
        }
    }

    static func attributes(for block: NoteBlock) -> [NSAttributedString.Key: Any] {
        [id: block.id.uuidString, kind: block.kind.rawValue, checked: block.isChecked, indent: block.indentLevel]
    }

    static func metadata(from attributes: [NSAttributedString.Key: Any], fallback: NoteBlock) -> NoteBlock {
        NoteBlock(id: (attributes[id] as? String).flatMap(UUID.init(uuidString:)) ?? fallback.id,
                  kind: (attributes[kind] as? String).flatMap(BlockKind.init(rawValue:)) ?? fallback.kind,
                  isChecked: (attributes[checked] as? Bool) ?? fallback.isChecked,
                  indentLevel: min(8, max(0, (attributes[indent] as? Int) ?? fallback.indentLevel)))
    }

    static func ranges(in string: String) -> [(NSRange, NSRange)] {
        let ns = string as NSString
        var result: [(NSRange, NSRange)] = []
        var start = 0
        while start < ns.length {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if newline.location == NSNotFound {
                let range = NSRange(location: start, length: ns.length - start)
                result.append((range, range))
                start = ns.length
            } else {
                result.append((NSRange(location: start, length: newline.location - start + 1), NSRange(location: start, length: newline.location - start)))
                start = newline.location + 1
            }
        }
        if ns.length == 0 || ns.hasSuffix("\n") {
            let range = NSRange(location: ns.length, length: 0)
            result.append((range, range))
        }
        return result
    }

    static func paragraphs(in text: NSAttributedString, emptyBlock: NoteBlock) -> [EditorParagraph] {
        let string = text.string as NSString
        var used = Set<UUID>()
        return ranges(in: text.string).map { range, contentRange in
            var paragraph = paragraph(range: range, contentRange: contentRange, in: text, string: string, emptyBlock: emptyBlock)
            if !used.insert(paragraph.block.id).inserted {
                paragraph.block.id = UUID()
                paragraph.block.isChecked = false
                used.insert(paragraph.block.id)
            }
            return paragraph
        }
    }

    /// A caret on LF belongs to its preceding paragraph; immediately after LF it
    /// belongs to the next one. U+2028 is a soft line break within a single block.
    /// IDs are already unique in the normalized editor, so this path only reads
    /// the neighboring paragraph instead of scanning all preceding blocks.
    static func paragraph(at position: Int, in text: NSAttributedString, emptyBlock: NoteBlock) -> EditorParagraph {
        let string = text.string as NSString
        let location = min(max(0, position), string.length)
        var start = location
        while start > 0 && string.character(at: start - 1) != 10 { start -= 1 }
        var end = location
        while end < string.length && string.character(at: end) != 10 { end += 1 }
        let contentRange = NSRange(location: start, length: end - start)
        let range = NSRange(location: start, length: end - start + (end < string.length ? 1 : 0))
        return paragraph(range: range, contentRange: contentRange, in: text, string: string, emptyBlock: emptyBlock)
    }

    private static func paragraph(range: NSRange, contentRange: NSRange, in text: NSAttributedString, string: NSString, emptyBlock: NoteBlock) -> EditorParagraph {
        var block: NoteBlock
        if range.length > 0 {
            block = metadata(from: text.attributes(at: range.location, effectiveRange: nil), fallback: emptyBlock)
        } else if text.length > 0 {
            let attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
            let fallback = metadata(from: attributes, fallback: emptyBlock)
            block = NoteBlock(id: (attributes[tailID] as? String).flatMap(UUID.init(uuidString:)) ?? emptyBlock.id,
                              kind: (attributes[tailKind] as? String).flatMap(BlockKind.init(rawValue:)) ?? fallback.kind,
                              isChecked: (attributes[tailChecked] as? Bool) ?? false,
                              indentLevel: min(8, max(0, (attributes[tailIndent] as? Int) ?? fallback.indentLevel)))
        } else {
            block = emptyBlock
        }
        block.text = string.substring(with: contentRange)
        return EditorParagraph(range: range, contentRange: contentRange, block: block)
    }

    private struct SemanticColorRun: Codable {
        let location: Int
        let length: Int
        let role: String
    }

    /// RTF serializes dynamic system colors to their current RGB value. A standard
    /// ignorable destination retains their role without changing visible content.
    static func restoreSemanticColors(in text: NSMutableAttributedString, rtf: Data) {
        let source = String(decoding: rtf, as: UTF8.self)
        let marker = "\\quicknotecolors "
        if let start = source.range(of: marker), let end = source[start.upperBound...].firstIndex(of: "}"),
           let data = Data(base64Encoded: String(source[start.upperBound..<end])),
           let runs = try? JSONDecoder().decode([SemanticColorRun].self, from: data) {
            for run in runs where run.location >= 0 && run.length > 0 && run.location <= text.length && run.length <= text.length - run.location {
                let range = NSRange(location: run.location, length: run.length)
                if run.role == "text" || run.role == "secondary" {
                    text.addAttribute(.foregroundColor, value: run.role == "secondary" ? NSColor.secondaryLabelColor : NSColor.textColor, range: range)
                } else if run.role.hasPrefix("highlight."), let highlight = EditorHighlight(rawValue: String(run.role.dropFirst(10))) {
                    text.addAttribute(.backgroundColor, value: highlight.color, range: range)
                }
            }
        }
    }

    static func richTextData(_ rich: NSAttributedString) throws -> Data {
        var result = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        var runs: [SemanticColorRun] = []
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let role: String
            if color == NSColor.textColor { role = "text" }
            else if color == NSColor.secondaryLabelColor { role = "secondary" }
            else { return }
            runs.append(SemanticColorRun(location: range.location, length: range.length, role: role))
        }
        rich.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if let highlight = EditorHighlight.matching(value as? NSColor) {
                runs.append(SemanticColorRun(location: range.location, length: range.length, role: "highlight." + highlight.rawValue))
            }
        }
        let encoded = try JSONEncoder().encode(runs).base64EncodedString()
        let destination = Data("{\\*\\quicknotecolors \(encoded)}".utf8)
        if let end = result.lastIndex(of: 125) { result.insert(contentsOf: destination, at: end) }
        return result
    }

    static func snapshot(_ text: NSAttributedString, emptyBlock: NoteBlock) throws -> [NoteBlock] {
        try paragraphs(in: text, emptyBlock: emptyBlock).map { paragraph in
            var block = paragraph.block
            block.richText = nil
            if paragraph.contentRange.length > 0 {
                let rich = canonicalRichText(in: text, range: paragraph.contentRange)
                block.richText = try richTextData(rich)
            }
            return block
        }
    }

    static func canonicalRichText(in text: NSAttributedString, range: NSRange) -> NSAttributedString {
        let rich = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        let fullRange = NSRange(location: 0, length: rich.length)
        EditorFont.sanitize(rich, range: fullRange)
        for key in metadataKeys { rich.removeAttribute(key, range: fullRange) }
        return NSAttributedString(attributedString: rich)
    }
}
