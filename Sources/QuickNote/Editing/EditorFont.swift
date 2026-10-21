import AppKit

/// System UI font names beginning with a dot are private aliases. Reopening those
/// names through NSFontManager or RTF can select Times instead of the intended face.
/// Use the corresponding registered public family before conversion or persistence.
enum EditorFont {
    static func stable(_ font: NSFont, size: CGFloat? = nil, bold: Bool? = nil, italic: Bool? = nil) -> NSFont {
        let fontSize = size ?? font.pointSize
        let name = font.fontName
        let traits = font.fontDescriptor.symbolicTraits
        let isBold = bold ?? traits.contains(.bold)
        let isItalic = italic ?? traits.contains(.italic)
        let regular: NSFont
        if name.hasPrefix("."), traits.contains(.monoSpace) || name.contains("Monospaced") || name.contains("Mono") {
            let suffix = isBold ? (isItalic ? "BoldItalic" : "Bold") : (isItalic ? "Italic" : "Regular")
            return NSFont(name: "Menlo-\(suffix)", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        } else if name.hasPrefix(".") && name.contains("PingFang") {
            let region = name.contains("TC") ? "TC" : name.contains("HK") ? "HK" : "SC"
            // PingFang has no italic face; obliqueness preserves synthetic italics.
            return NSFont(name: "PingFang\(region)-\(isBold ? "Semibold" : "Regular")", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        } else if name.hasPrefix(".") {
            let suffix = isBold ? (isItalic ? "BoldItalic" : "Bold") : (isItalic ? "Italic" : "")
            return NSFont(name: suffix.isEmpty ? "HelveticaNeue" : "HelveticaNeue-\(suffix)", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        } else {
            regular = NSFont(name: name, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        }
        var result = regular
        let manager = NSFontManager.shared
        result = isBold ? manager.convert(result, toHaveTrait: .boldFontMask) : manager.convert(result, toNotHaveTrait: .boldFontMask)
        if !name.contains("PingFang") {
            result = isItalic ? manager.convert(result, toHaveTrait: .italicFontMask) : manager.convert(result, toNotHaveTrait: .italicFontMask)
        }
        return result
    }

    static func sanitize(_ text: NSMutableAttributedString, range: NSRange) {
        let copy = NSAttributedString(attributedString: text)
        copy.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            text.addAttribute(.font, value: stable(font), range: run)
            if font.fontDescriptor.symbolicTraits.contains(.italic) {
                text.addAttribute(.obliqueness, value: 0.2, range: run)
            }
        }
    }
}
