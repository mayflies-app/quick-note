import AppKit
import QuickNoteCore

enum EditorHighlight: String, CaseIterable {
    case purple, pink, orange, mint, blue

    var color: NSColor {
        let color: NSColor
        switch self {
        case .purple: color = .systemPurple
        case .pink: color = .systemPink
        case .orange: color = .systemOrange
        case .mint: color = .systemMint
        case .blue: color = .systemBlue
        }
        // Resolve to a stable RGB color so RTF reloads and appearance changes retain it.
        return (color.usingColorSpace(.deviceRGB) ?? color).withAlphaComponent(0.24)
    }

    static func matching(_ color: NSColor?) -> EditorHighlight? {
        // Only the app's translucent palette can acquire a semantic highlight role.
        // Imported opaque colors may share RGB values and must retain their opacity.
        guard let rgb = color?.usingColorSpace(.deviceRGB), abs(rgb.alphaComponent - 0.24) <= 0.015 else { return nil }
        func distance(_ color: NSColor) -> CGFloat {
            let target = color.usingColorSpace(.deviceRGB)!
            return abs(rgb.redComponent - target.redComponent) + abs(rgb.greenComponent - target.greenComponent) + abs(rgb.blueComponent - target.blueComponent)
        }
        guard let closest = allCases.min(by: { distance($0.color) < distance($1.color) }), distance(closest.color) < 0.12 else { return nil }
        return closest
    }
}

struct EditorFormatState {
    var kind: BlockKind
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var highlight: EditorHighlight?
    var indentLevel: Int
    var alignment: NSTextAlignment
}
