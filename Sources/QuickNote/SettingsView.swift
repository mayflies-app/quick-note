import AppKit
import SwiftUI
import QuickNoteCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, editing, storage
    var id: String { rawValue }
    func title(language: AppLanguage) -> String {
        if self == .editing { return language.text("settings.editing") }
        let key: String
        switch self { case .general: key = "常规"; case .appearance: key = "外观"; case .editing: key = "编辑"; case .storage: key = "本地数据" }
        return AppLocalization.text(key, language: language)
    }
    var symbol: String {
        switch self { case .general: return "gearshape"; case .appearance: return "paintpalette"; case .editing: return "textformat"; case .storage: return "internaldrive" }
    }
    func detail(language: AppLanguage) -> String {
        let key: String
        switch self {
        case .general: key = "设置界面语言、登录时启动和快捷键。"
        case .appearance: key = "设置窗口置顶和明暗外观。"
        case .editing: key = "设置拼写检查和链接识别。"
        case .storage: key = "查看自动保存方式和本地存储位置。"
        }
        return AppLocalization.text(key, language: language)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .general
    @Published private(set) var selectedShortcut: GlobalShortcut?
    @Published private(set) var problem: String?
    @Published private(set) var failedFnSelection = false
    @Published private(set) var isRecording = false
    var onRecordingChange: ((Bool) -> String?)?
    let databaseURL: URL
    var onChooseShortcut: ((GlobalShortcut) -> String?)?

    init(databaseURL: URL) { self.databaseURL = databaseURL }
    var showsFnDetails: Bool { selectedShortcut == .fnQ || failedFnSelection }

    func update(shortcut: GlobalShortcut?, problem: String?) {
        selectedShortcut = shortcut
        self.problem = problem
        failedFnSelection = problem.map {
            $0.contains("Fn Q") || $0.contains("Fn+Q") || $0.contains("辅助功能") || $0.contains("Accessibility")
        } ?? false
    }

    func recordingChanged(_ recording: Bool) {
        isRecording = recording
        if let error = onRecordingChange?(recording) { problem = error }
    }

    func chooseShortcut(_ preset: GlobalShortcut) {
        guard let onChooseShortcut else { return }
        if let error = onChooseShortcut(preset) {
            problem = error
            failedFnSelection = preset == .fnQ
        } else {
            selectedShortcut = preset
            problem = nil
            failedFnSelection = false
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var loginItems: LoginItemController
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedAction: String?

    private var palette: SettingsPalette { .init(dark: colorScheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            divider.frame(width: 1)
            VStack(spacing: 0) {
                header
                divider.frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.page {
                        case .general: generalPage
                        case .appearance: appearancePage
                        case .editing: editingPage
                        case .storage: storagePage
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                .scrollIndicators(.automatic)
            }
            .background(palette.canvas)
        }
        .frame(minWidth: 600, minHeight: 442)
        .background {
            HStack(spacing: 0) {
                palette.sidebar.frame(width: 150)
                palette.border.frame(width: 1)
                palette.canvas
            }
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .foregroundStyle(palette.text)
        .font(.system(size: 13))
        .textFieldStyle(.plain)
        .tint(palette.accent)
        .onAppear { loginItems.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItems.refresh()
        }
    }

    private var appVersion: String? {
        guard let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(palette.iconTile)
                    RoundedRectangle(cornerRadius: 11).strokeBorder(palette.iconBorder, lineWidth: 1)
                    Image(systemName: "note.text")
                        .font(.system(size: 24, weight: .medium)).foregroundStyle(palette.text)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                Text(L("随记", language: preferences.language)).font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 27)
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 9) {
                            Image(systemName: page.symbol).font(.system(size: 13)).frame(width: 17)
                            Text(page.title(language: preferences.language)).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(model.page == page ? palette.text : palette.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .background(model.page == page ? palette.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius)
                            .strokeBorder(focusedAction == "page.\(page.rawValue)" ? palette.accent : .clear, lineWidth: 1.5)
                            .allowsHitTesting(false))
                        .contentShape(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                    }
                    .buttonStyle(.plain)
                    .focused($focusedAction, equals: "page.\(page.rawValue)")
                    .accessibilityIdentifier("settings.page.\(page.rawValue)")
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }.padding(.horizontal, 10)
            Spacer(minLength: 20)
            if let version = appVersion {
                Text(preferences.language.format("版本 %@", version))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 18)
                    .accessibilityIdentifier("app.version")
            }
        }
        .frame(width: 150).frame(maxHeight: .infinity)
        .background(palette.sidebar)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page.title(language: preferences.language)).font(.system(size: 21, weight: .semibold))
                Text(model.page.detail(language: preferences.language)).font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28).padding(.vertical, 23)
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("界面语言", language: preferences.language)).font(.system(size: 13, weight: .semibold))
                Text(L("立即更新界面，保留正在书写的内容。", language: preferences.language))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                HStack(spacing: 3) {
                    languageButton(.simplifiedChinese, title: AppLanguage.simplifiedChinese.title)
                    languageButton(.english, title: AppLanguage.english.title)
                }
                .padding(3)
                .background(palette.field, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border).allowsHitTesting(false))
                .accessibilityElement(children: .contain).accessibilityLabel(L("界面语言", language: preferences.language))
                .accessibilityIdentifier("settings.language")
            }
            divider.frame(height: 1)
            loginItemSetting
            divider.frame(height: 1)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("唤出备忘录", language: preferences.language)).font(.system(size: 13, weight: .semibold))
                    Text(L("点击录入快捷键，按 Esc 取消。", language: preferences.language))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: model.selectedShortcut ?? preferences.shortcut, palette: palette,
                    language: preferences.language, onRecord: model.chooseShortcut, onRecordingChange: model.recordingChanged)
                    .frame(width: 104, height: 36)
                    .accessibilityIdentifier("settings.shortcut.recorder")
            }
            HStack(spacing: 8) {
                Button(L("恢复默认快捷键", language: preferences.language)) { model.chooseShortcut(.controlOptionN) }
                    .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "shortcut.default"))
                    .focused($focusedAction, equals: "shortcut.default")
                    .accessibilityIdentifier("settings.shortcut.default")
                Button("Fn Q") { model.chooseShortcut(.fnQ) }
                    .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "shortcut.fnQ", selected: model.selectedShortcut == .fnQ))
                    .focused($focusedAction, equals: "shortcut.fnQ")
                    .accessibilityIdentifier("settings.shortcut.fnQ")
                    .accessibilityAddTraits(model.selectedShortcut == .fnQ ? .isSelected : [])
            }.disabled(model.isRecording)
            Text(L("再次按下相同快捷键可收起窗口。", language: preferences.language))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.shortcut.error")
            }
            if model.showsFnDetails {
                divider.frame(height: 1)
                fnDetails
            }
        }
    }

    private var fnDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("使用 Fn Q", language: preferences.language)).font(.system(size: 12, weight: .semibold))
            Text(L("先在「系统设置 → 键盘 → 键盘快捷键 → 任务控制」中关闭或更改系统的快速备忘录快捷键，再允许随记使用辅助功能权限。", language: preferences.language))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("打开辅助功能设置…", language: preferences.language)) { GlobalShortcutController.openAccessibilitySettings() }
                .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "accessibility"))
                .focused($focusedAction, equals: "accessibility")
                .accessibilityIdentifier("settings.accessibility")
        }
    }

    private var editingPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                sectionLabel(L("书写", language: preferences.language))
                settingToggle(L("拼写检查", language: preferences.language), detail: L("输入时标记拼写错误。", language: preferences.language), value: $preferences.spellChecking,
                              identifier: "settings.spellChecking")
                divider.frame(height: 1)
                settingToggle(L("识别链接", language: preferences.language), detail: L("自动识别输入的网页地址。", language: preferences.language), value: $preferences.automaticLinks,
                              identifier: "settings.automaticLinks")
            }
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                sectionLabel(L("窗口", language: preferences.language))
                settingToggle(L("保持在最前", language: preferences.language), detail: L("备忘录显示在其他窗口上方。", language: preferences.language), value: $preferences.floatingWindow,
                              identifier: "settings.floatingWindow")
                divider.frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("外观", language: preferences.language)).font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 3) {
                        appearanceButton("system", title: L("跟随系统", language: preferences.language))
                        appearanceButton("light", title: L("浅色", language: preferences.language))
                        appearanceButton("dark", title: L("深色", language: preferences.language))
                    }
                    .padding(3)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border).allowsHitTesting(false))
                    .accessibilityElement(children: .contain).accessibilityLabel(L("外观", language: preferences.language))
                    .accessibilityIdentifier("settings.appearance")
                }
            }
        }
    }

    private var loginItemSetting: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingToggle(L("登录时启动", language: preferences.language), detail: L("登录后在菜单栏待命，按快捷键开始记录。", language: preferences.language),
                value: Binding(get: { loginItems.isEnabled }, set: { loginItems.setEnabled($0) }),
                identifier: "settings.launchAtLogin")
                .disabled(!loginItems.canToggle)
            if loginItems.status == .requiresApproval {
                Text(L("请在系统设置的登录项中允许随记启动。", language: preferences.language))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.launchAtLogin.status")
                Button(L("打开登录项设置", language: preferences.language)) { loginItems.openSystemSettings() }
                    .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "loginSettings"))
                    .focused($focusedAction, equals: "loginSettings")
                    .accessibilityIdentifier("settings.launchAtLogin.openSettings")
            }
            if let error = loginItems.error(language: preferences.language) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.launchAtLogin.error")
            }
        }
    }

    private func appearanceButton(_ value: String, title: String) -> some View {
        Button { preferences.appearance = value } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(SettingsButtonStyle(palette: palette,
                         focused: focusedAction == "appearance.\(value)",
                         selected: preferences.appearance == value, segmented: true))
            .focused($focusedAction, equals: "appearance.\(value)")
            .accessibilityIdentifier("settings.appearance.\(value)")
            .accessibilityAddTraits(preferences.appearance == value ? .isSelected : [])
    }

    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(L("一个备忘录，自动保存", language: preferences.language))
                Text(L("编辑后自动写入本地数据库。关闭窗口后，再次唤出即可继续书写。", language: preferences.language))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            divider.frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("存储位置", language: preferences.language)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("SQLite").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary)
                }
                Text(model.databaseURL.path)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 10)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius).strokeBorder(palette.border).allowsHitTesting(false))
                    .accessibilityIdentifier("settings.databasePath")
                Button(L("在 Finder 中显示…", language: preferences.language)) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.databaseURL])
                }
                .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "revealDatabase"))
                .focused($focusedAction, equals: "revealDatabase")
                .accessibilityIdentifier("settings.revealDatabase")
            }
            Text(L("无需账号，也不会上传内容。", language: preferences.language))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }

    private var divider: some View { Rectangle().fill(palette.border).allowsHitTesting(false) }
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
    }
    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>, identifier: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier(identifier)
        }
    }
    private func languageButton(_ language: AppLanguage, title: String) -> some View {
        Button {
            preferences.language = language
            focusedAction = "language.\(language.rawValue)"
            loginItems.refresh()
        } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == "language.\(language.rawValue)",
                         selected: preferences.language == language, segmented: true))
            .focusable()
            .focusEffectDisabled()
            .focused($focusedAction, equals: "language.\(language.rawValue)")
            .accessibilityAddTraits(preferences.language == language ? .isSelected : [])
            .accessibilityIdentifier("settings.language.\(language.rawValue)")
            .onKeyPress(.leftArrow) { preferences.language = .simplifiedChinese; focusedAction = "language.zh-Hans"; return .handled }
            .onKeyPress(.rightArrow) { preferences.language = .english; focusedAction = "language.en"; return .handled }
    }

}

private struct SettingsButtonStyle: ButtonStyle {
    let palette: SettingsPalette
    var focused = false
    var selected = false
    var segmented = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let fill = selected ? palette.segmentSelected : configuration.isPressed ? palette.pressed : hovered && enabled ? palette.hover : segmented ? Color.clear : palette.field
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 36)
            .foregroundStyle(palette.text)
            .background(fill, in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius)
                .strokeBorder(focused ? palette.accent : segmented ? .clear : palette.border, lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}
