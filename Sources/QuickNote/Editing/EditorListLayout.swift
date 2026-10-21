import AppKit
import QuickNoteCore

struct EditorMarkerGeometry {
    var frame: NSRect
    var textStart: CGFloat
    var baseline: CGFloat
    var font: NSFont?
}

@MainActor
enum EditorListLayout {
    static let levelIndent: CGFloat = 22
    static let markerColumn: CGFloat = 22
    static let markerGap: CGFloat = 6
    static let checkboxSize: CGFloat = 15
    static let quoteIndent: CGFloat = 18
    static let listKinds: Set<BlockKind> = [.bullet, .dashed, .numbered, .checklist]
    static let markedKinds = listKinds.union([.quote])

    static func headIndent(for block: NoteBlock) -> CGFloat {
        CGFloat(block.indentLevel) * levelIndent + (listKinds.contains(block.kind) ? markerColumn + markerGap : block.kind == .quote ? quoteIndent : 0)
    }

    static func geometry(kind: BlockKind, number: Int, textStart: CGFloat, baseline: CGFloat, textFont: NSFont) -> EditorMarkerGeometry? {
        let right = textStart - markerGap
        let centerY = baseline - textFont.capHeight / 2
        let rect: NSRect
        var markerFont: NSFont?
        switch kind {
        case .checklist:
            rect = NSRect(x: right - checkboxSize, y: centerY - checkboxSize / 2, width: checkboxSize, height: checkboxSize)
        case .bullet:
            rect = NSRect(x: right - 4.5, y: centerY - 2.25, width: 4.5, height: 4.5)
        case .dashed:
            rect = NSRect(x: right - 7, y: centerY - 0.75, width: 7, height: 1.5)
        case .numbered:
            let label = "\(number)." as NSString
            var font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            var size = label.size(withAttributes: [.font: font])
            // Keep the common trailing edge and use the writing margin for long
            // labels before reducing their size. Even six-digit lists stay visible.
            let available = max(markerColumn, right - 3)
            if size.width > available {
                font = NSFont.monospacedDigitSystemFont(ofSize: max(9, 13 * available / size.width), weight: .regular)
                size = label.size(withAttributes: [.font: font])
            }
            markerFont = font
            rect = NSRect(x: right - size.width, y: baseline - font.ascender, width: size.width, height: size.height)
        case .quote:
            rect = NSRect(x: textStart - 12, y: centerY - 8, width: 2, height: 16)
        default: return nil
        }
        return EditorMarkerGeometry(frame: rect, textStart: textStart, baseline: baseline, font: markerFont)
    }
}
