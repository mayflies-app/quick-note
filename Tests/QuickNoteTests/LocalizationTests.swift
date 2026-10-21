import AppKit
import QuickNoteCore
import XCTest
@testable import QuickNote

@MainActor
final class LocalizationTests: XCTestCase {
    private func withPreferences(_ action: (AppPreferences, UserDefaults) throws -> Void) rethrows {
        let suite = "QuickNote.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(AppPreferences(defaults: defaults, preferredLanguages: ["fr", "zh-Hans", "en"]), defaults)
    }

    func testLanguageChoicePersistsImmediatelyAndInvalidValuesUseSystemDefault() {
        withPreferences { preferences, defaults in
            XCTAssertEqual(preferences.language, .simplifiedChinese)
            var changes = 0
            preferences.onChange = { changes += 1 }
            preferences.language = .english
            XCTAssertEqual(defaults.string(forKey: "language"), "en")
            XCTAssertEqual(changes, 1)
            XCTAssertEqual(AppPreferences(defaults: defaults, preferredLanguages: ["zh-Hans"]).language, .english)
            defaults.set("unknown", forKey: "language")
            XCTAssertEqual(AppPreferences(defaults: defaults, preferredLanguages: ["en", "zh-Hans"]).language, .english)
        }
    }

    func testLanguageRefreshKeepsFormatSymbolsImageOnly() {
        _ = NSApplication.shared
        let button = MinimalChrome.symbolButton("bold", label: "粗体（⌘B）", target: nil, action: NSSelectorFromString("bold:"))
        XCTAssertEqual(button.imagePosition, .imageOnly)
        let originalTitle = button.title
        AppLocalization.refresh(button, language: .english)
        print("SYMBOL EVIDENCE: initialTitle=\(originalTitle), afterTitle=\(button.title), imagePosition=\(button.imagePosition.rawValue)")
        XCTAssertEqual(button.imagePosition, .imageOnly, "Language refresh must not reveal the native Button placeholder over an icon")
        XCTAssertTrue(button.title.isEmpty)
        XCTAssertEqual(button.toolTip, "Bold (⌘B)")
        AppLocalization.refresh(button, language: .simplifiedChinese)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.toolTip, "粗体（⌘B）")
    }

    func testExistingSaveAndShortcutErrorsRenderInBothLanguages() {
        let error = NoteStoreError.unsupportedSchema(1)
        let status = NoteWindowController.SaveStatus.failed(error)
        XCTAssertTrue(status.message(language: .english).hasPrefix("Save failed: "))
        XCTAssertTrue(status.message(language: .simplifiedChinese).hasPrefix("保存失败："))
        XCTAssertTrue(status.isError)
        let shortcut = GlobalShortcutError.accessibilityRequired
        XCTAssertTrue(shortcut.description(language: .english).contains("Accessibility"))
        XCTAssertTrue(shortcut.description(language: .simplifiedChinese).contains("辅助功能"))
    }

    func testExistingNativeControlsSwitchBothWaysWithoutTranslatingEditableContent() {
        _ = NSApplication.shared
        withPreferences { preferences, _ in
            let controller = NoteWindowController()
            controller.applyPreferences(preferences)
            let editor = controller.editor.textView
            controller.editor.load(blocks: [NoteBlock(text: "标题 Quick Note 用户内容 👩🏽‍💻")])
            editor.setSelectedRange(NSRange(location: 3, length: 10))
            let before = NSAttributedString(attributedString: editor.attributedString())
            let selection = editor.selectedRange()
            controller.setSaveStatus(.failed(NoteStoreError.unsupportedSchema(1)))
            preferences.language = .english
            controller.applyPreferences(preferences)
            XCTAssertEqual(controller.window?.title, "Quick Note")
            XCTAssertTrue(controller.editor.textView === editor)
            XCTAssertTrue(editor.attributedString().isEqual(to: before))
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(controller.isSaveErrorVisible)
            let buttons = descendants(controller.formattingWindow!.contentView!).compactMap { $0 as? NSButton }
            XCTAssertTrue(buttons.contains { $0.title == "Clear Formatting" })
            XCTAssertTrue(buttons.contains { $0.toolTip == "Mint Highlight" })
            let symbols = buttons.filter { $0.image != nil && !($0 is NSPopUpButton) }
            XCTAssertEqual(symbols.count, 14)
            XCTAssertTrue(symbols.allSatisfy { $0.title.isEmpty && $0.imagePosition == .imageOnly })
            XCTAssertTrue(buttons.contains { $0.toolTip == "Bold (⌘B)" })
            preferences.language = .simplifiedChinese
            controller.applyPreferences(preferences)
            XCTAssertEqual(controller.window?.title, "随记")
            XCTAssertTrue(buttons.contains { $0.title == "清除格式" })
            XCTAssertTrue(buttons.contains { $0.toolTip == "薄荷绿高亮" })
            XCTAssertTrue(editor.attributedString().isEqual(to: before))
            XCTAssertEqual(editor.selectedRange(), selection)
            controller.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
