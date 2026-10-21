import AppKit
import QuickNoteCore

/// Reuses persisted RTF for unchanged paragraphs. Metadata stays in NoteBlock;
/// the comparison includes every attribute that actually enters its RTF.
@MainActor
final class EditorSnapshotCache {
    private struct Entry {
        let richText: NSAttributedString
        let data: Data
    }

    private var entries: [UUID: Entry] = [:]
    private let encode: (NSAttributedString) throws -> Data
    private(set) var encodingCount = 0
    var cachedParagraphCount: Int { entries.count }

    init(encode: @escaping (NSAttributedString) throws -> Data = EditorDocumentCodec.richTextData) {
        self.encode = encode
    }

    func reset() {
        entries.removeAll(keepingCapacity: false)
        encodingCount = 0
    }

    func snapshot(_ text: NSAttributedString, emptyBlock: NoteBlock) throws -> [NoteBlock] {
        var nextEntries: [UUID: Entry] = [:]
        var encoded = 0
        let result = try EditorDocumentCodec.paragraphs(in: text, emptyBlock: emptyBlock).map { paragraph in
            var block = paragraph.block
            block.richText = nil
            if paragraph.contentRange.length > 0 {
                let rich = EditorDocumentCodec.canonicalRichText(in: text, range: paragraph.contentRange)
                let entry: Entry
                if let previous = entries[block.id], previous.richText.isEqual(to: rich) {
                    entry = previous
                } else {
                    entry = Entry(richText: rich, data: try encode(rich))
                    encoded += 1
                }
                block.richText = entry.data
                nextEntries[block.id] = entry
            }
            return block
        }
        // Commit only a successful snapshot. Deleted paragraphs and stale undo
        // content are dropped so the cache cannot accumulate document history.
        entries = nextEntries
        encodingCount += encoded
        return result
    }
}
