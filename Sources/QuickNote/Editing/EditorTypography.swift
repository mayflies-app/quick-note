import AppKit
import QuickNoteCore

@MainActor
enum EditorTypography {
    static func font(for kind: BlockKind) -> NSFont {
        let font: NSFont
        switch kind {
        case .title: font = NSFont.systemFont(ofSize: 27, weight: .bold)
        case .heading: font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        case .subheading: font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        case .code: font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        default: font = NSFont.systemFont(ofSize: 17)
        }
        return EditorFont.stable(font)
    }

    static func foregroundColor(for kind: BlockKind) -> NSColor {
        kind == .quote ? .secondaryLabelColor : .textColor
    }

    static func paragraphStyle(for block: NoteBlock, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.headIndent = EditorListLayout.headIndent(for: block)
        style.firstLineHeadIndent = style.headIndent
        style.lineSpacing = EditorListLayout.listKinds.contains(block.kind) ? 2 : 3
        switch block.kind {
        case .title: style.paragraphSpacing = 14
        case .heading: style.paragraphSpacing = 11
        case .subheading: style.paragraphSpacing = 9
        case .bullet, .dashed, .numbered, .checklist: style.paragraphSpacing = 3
        default: style.paragraphSpacing = 8
        }
        return style
    }
}
