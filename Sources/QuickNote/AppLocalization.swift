import AppKit
import QuickNoteCore

/// App-owned copy only. Note content and editable fields never pass through this catalog.
enum AppLocalization {
    static func text(_ key: String, language: AppLanguage) -> String {
        language.text(key)
    }

    private static let english = AppLanguage.english.catalog
    private static let chinese = AppLanguage.simplifiedChinese.catalog

    private static func sourceKey(for value: String) -> String {
        if english[value] != nil { return value }
        return english.first(where: { $0.value == value })?.key
            ?? chinese.first(where: { $0.value == value })?.key ?? value
    }

    @MainActor static func refresh(_ menu: NSMenu, language: AppLanguage) {
        func translate(_ value: String) -> String {
            let key = sourceKey(for: value)
            return text(key, language: language)
        }
        menu.title = translate(menu.title)
        for item in menu.items {
            item.title = translate(item.title)
            if let submenu = item.submenu { refresh(submenu, language: language) }
        }
    }

    /// Refresh existing native controls instead of replacing the editor or its input client.
    @MainActor static func refresh(_ view: NSView, language: AppLanguage, excluding editor: NSView? = nil) {
        guard view !== editor else { return }
        func translated(_ value: String) -> String {
            let key = sourceKey(for: value)
            if english[key] != nil { return text(key, language: language) }
            // Command tooltips retain the keyboard equivalent while changing their title.
            for (key, englishTitle) in english {
                let zh = (chinese[key] ?? key).replacingOccurrences(of: "…", with: "")
                let en = englishTitle.replacingOccurrences(of: "…", with: "")
                let prefixes = [zh + "（", en + "（", en + " ("]
                if let prefix = prefixes.first(where: { value.hasPrefix($0) }), value.hasSuffix("）") || value.hasSuffix(")") {
                    let shortcut = value.dropFirst(prefix.count).dropLast()
                    return language.format("command.tooltip", language.text(key).replacingOccurrences(of: "…", with: ""), String(shortcut))
                }
            }
            return value
        }
        if let tooltip = view.toolTip { view.toolTip = translated(tooltip) }
        if let label = view.accessibilityLabel() { view.setAccessibilityLabel(translated(label)) }
        // NSButton.title also changes imagePosition. Its hidden default "Button" title
        // must never be reassigned on symbol controls, or AppKit draws it over the icon.
        if let button = view as? NSButton, button.imagePosition != .imageOnly {
            button.title = translated(button.title)
        }
        if let popup = view as? NSPopUpButton {
            for item in popup.itemArray { item.title = translated(item.title) }
        }
        if let field = view as? NSTextField, !field.isEditable { field.stringValue = translated(field.stringValue) }
        for child in view.subviews { refresh(child, language: language, excluding: editor) }
    }
}

@MainActor func L(_ key: String, language: AppLanguage? = nil) -> String {
    AppLocalization.text(key, language: language ?? AppPreferences.shared.language)
}

func localizedError(_ error: Error, language: AppLanguage) -> String {
    if let error = error as? NoteStoreError { return error.description(language: language) }
    if let error = error as? GlobalShortcutError { return error.description(language: language) }
    if let error = error as? EditorDocumentCodec.CodecError { return error.description(language: language) }
    return error.localizedDescription
}
