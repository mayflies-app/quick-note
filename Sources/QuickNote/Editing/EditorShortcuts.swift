import AppKit
import QuickNoteCore

/// One catalog for native menus, tooltips and text-view key equivalents.
@MainActor
enum EditorShortcuts {
    enum Command: CaseIterable {
        case bold, italic, underline, strikethrough, link, formatting
        case title, heading, subheading, body, code, bullet, dashed, numbered, quote, checklist, checked
        case indent, outdent, clear

        @MainActor var title: String {
            switch self {
            case .bold: return L("粗体")
            case .italic: return L("斜体")
            case .underline: return L("下划线")
            case .strikethrough: return L("删除线")
            case .link: return L("添加链接…")
            case .formatting: return L("显示 / 隐藏格式工具")
            case .title: return L("标题")
            case .heading: return L("小标题")
            case .subheading: return L("副标题")
            case .body: return L("正文")
            case .code: return L("等宽文本")
            case .bullet: return L("项目列表")
            case .dashed: return L("虚线列表")
            case .numbered: return L("编号列表")
            case .quote: return L("引用")
            case .checklist: return L("勾选事项")
            case .checked: return L("完成 / 取消完成")
            case .indent: return L("增加缩进")
            case .outdent: return L("减少缩进")
            case .clear: return L("清除格式")
            }
        }

        var key: String {
            switch self {
            case .bold, .body: return "b"
            case .italic: return "i"
            case .underline, .checked: return "u"
            case .strikethrough: return "x"
            case .link: return "k"
            case .formatting, .title: return "t"
            case .heading: return "h"
            case .subheading: return "j"
            case .code: return "m"
            case .bullet: return "7"
            case .dashed: return "8"
            case .numbered: return "9"
            case .quote: return "'"
            case .checklist: return "l"
            case .indent: return "]"
            case .outdent: return "["
            case .clear: return "\\"
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .strikethrough, .title, .heading, .subheading, .body, .code, .bullet, .dashed, .numbered, .checklist, .checked:
                return [.command, .shift]
            case .formatting: return [.command, .option]
            default: return [.command]
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .bold, .body: return 11
            case .italic: return 34
            case .underline, .checked: return 32
            case .strikethrough: return 7
            case .link: return 40
            case .formatting, .title: return 17
            case .heading: return 4
            case .subheading: return 38
            case .code: return 46
            case .bullet: return 26
            case .dashed: return 28
            case .numbered: return 25
            case .quote: return 39
            case .checklist: return 37
            case .indent: return 30
            case .outdent: return 33
            case .clear: return 42
            }
        }

        var shortcut: String {
            (modifiers.contains(.command) ? "⌘" : "") +
            (modifiers.contains(.option) ? "⌥" : "") +
            (modifiers.contains(.shift) ? "⇧" : "") + key.uppercased()
        }

        @MainActor var tooltip: String {
            let label = title.replacingOccurrences(of: "…", with: "")
            return AppPreferences.shared.language.format("command.tooltip", label, shortcut)
        }

        @discardableResult
        @MainActor
        func perform(on editor: NoteEditorViewController) -> Bool {
            switch self {
            case .bold: editor.toggleBold()
            case .italic: editor.toggleItalic()
            case .underline: editor.toggleUnderline()
            case .strikethrough: editor.toggleStrikethrough()
            case .title: editor.apply(.title)
            case .heading: editor.apply(.heading)
            case .subheading: editor.apply(.subheading)
            case .body: editor.apply(.body)
            case .code: editor.apply(.code)
            case .bullet: editor.apply(.bullet)
            case .dashed: editor.apply(.dashed)
            case .numbered: editor.apply(.numbered)
            case .quote: editor.apply(.quote)
            case .checklist: editor.toggleChecklist()
            case .checked: editor.toggleChecked()
            case .indent: editor.indent()
            case .outdent: editor.outdent()
            case .clear: editor.clearFormatting()
            case .link, .formatting: return false // Owned by the window and native menu.
            }
            return true
        }
    }

    static func handle(_ event: NSEvent, editor: NoteEditorViewController) -> Bool {
        guard event.type == .keyDown, !editor.textView.hasMarkedText() else { return false }
        // Caps Lock and keypad origin do not change a shortcut. All actual extra modifiers do.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        let candidates = Command.allCases.filter { $0.modifiers == modifiers }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let command = candidates.first(where: { $0.key == characters }) {
            return command.perform(on: editor)
        }
        // Respect a Latin keyboard layout's logical letters (especially native Cmd-C/X/V).
        // A physical fallback handles Chinese input sources and Shift-7/8/9 producing &/*/(.
        let latinLetterOrDigit = !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value)
        }
        guard !latinLetterOrDigit else { return false }
        let nonLatin = characters.isEmpty || characters.unicodeScalars.contains { !$0.isASCII }
        guard let command = candidates.first(where: {
            $0.keyCode == event.keyCode && (nonLatin || [.bullet, .dashed, .numbered].contains($0))
        }) else { return false }
        return command.perform(on: editor)
    }
}
