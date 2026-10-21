import Foundation

public enum BlockKind: String, Codable, CaseIterable, Sendable {
    case title, heading, subheading, body, bullet, dashed, numbered, checklist, quote, code
}

/// One editable paragraph. Rich text contains only this paragraph, without its newline.
public struct NoteBlock: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BlockKind
    public var text: String
    public var richText: Data?
    public var isChecked: Bool
    public var indentLevel: Int

    public init(id: UUID = UUID(), kind: BlockKind = .body, text: String = "", richText: Data? = nil, isChecked: Bool = false, indentLevel: Int = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.richText = richText
        self.isChecked = isChecked
        self.indentLevel = indentLevel
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, richText, isChecked, indentLevel }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(BlockKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        richText = try values.decodeIfPresent(Data.self, forKey: .richText)
        isChecked = try values.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        indentLevel = try values.decodeIfPresent(Int.self, forKey: .indentLevel) ?? 0
    }
}

public struct NoteDocument: Equatable, Codable, Sendable {
    public var blocks: [NoteBlock]
    public var updatedAt: Date

    public init(blocks: [NoteBlock] = [NoteBlock()], updatedAt: Date = Date()) {
        self.blocks = blocks
        self.updatedAt = updatedAt
    }
}
