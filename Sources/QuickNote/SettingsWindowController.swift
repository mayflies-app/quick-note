import AppKit
import Combine
import SwiftUI
import QuickNoteCore

/// Let text input and the shortcut recorder consume Escape before the window closes.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    var onChooseShortcut: ((GlobalShortcut) -> String?)?
    var onRecordingChange: ((Bool) -> String?)?
    private let model: SettingsModel
    private let preferences: AppPreferences
    private var languageSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?

    init(databaseURL: URL, preferences: AppPreferences? = nil, loginItems: LoginItemController? = nil) {
        let preferences = preferences ?? .shared
        self.preferences = preferences
        model = SettingsModel(databaseURL: databaseURL)
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("随记设置")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = NSColor(name: nil) { appearance in
            SettingsPalette(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).nativeCanvas
        }
        window.minSize = NSSize(width: 600, height: 470)
        super.init(window: window)
        let loginItems = loginItems ?? (CommandLine.arguments.contains("--verify-workflow")
            ? LoginItemService.disabledMockController() : LoginItemService.controller())
        let hosting = NSHostingView(rootView: SettingsView(model: model, preferences: preferences, loginItems: loginItems))
        window.contentView = hosting
        model.onChooseShortcut = { [weak self] preset in
            guard let callback = self?.onChooseShortcut else { return L("快捷键尚未注册，请稍后重试。") }
            return callback(preset)
        }
        model.onRecordingChange = { [weak self] recording in self?.onRecordingChange?(recording) }
        appearanceSubscription = preferences.$appearance.sink { [weak window] value in
            switch value {
            case "light": window?.appearance = NSAppearance(named: .aqua)
            case "dark": window?.appearance = NSAppearance(named: .darkAqua)
            default: window?.appearance = nil
            }
        }
        languageSubscription = preferences.$language.sink { [weak window] language in
            window?.title = AppLocalization.text("随记设置", language: language)
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(shortcut: GlobalShortcut?, problem: String?) { model.update(shortcut: shortcut, problem: problem) }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.appearance = preferences.nativeAppearance
        WindowPlacement.keepVisible(window)
        window?.makeKeyAndOrderFront(nil)
    }
    func selectPage(_ page: SettingsPage) { model.page = page }
    func chooseShortcut(_ preset: GlobalShortcut) { model.chooseShortcut(preset) }
    var selectedShortcut: GlobalShortcut? { model.selectedShortcut }
    var shortcutProblem: String? { model.problem }

}
