import AppKit
import QuickNoteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var noteWindow: NoteWindowController?
    private(set) var store: NoteStore?
    private(set) var document = NoteDocument()
    private(set) var workflowShortcutTriggerCount = 0
    let loginItems = CommandLine.arguments.contains("--verify-workflow")
        ? LoginItemService.disabledMockController() : LoginItemService.controller()
    private let shortcut: GlobalShortcutController
    private let appPreferences: AppPreferences

    init(preferences: AppPreferences? = nil, shortcutController: GlobalShortcutController? = nil) {
        appPreferences = preferences ?? .shared
        shortcut = shortcutController ?? GlobalShortcutController()
        super.init()
    }
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var saveTimer: Timer?
    private var isDirty = false
    private var shortcutProblem: Error?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let databaseURL = try Self.databaseURL()
            store = try NoteStore(url: databaseURL)
            document = try store!.load()
            let controller = NoteWindowController()
            noteWindow = controller
            controller.applyPreferences(appPreferences)
            appPreferences.onChange = { [weak self] in
                guard let self else { return }
                self.noteWindow?.applyPreferences(self.appPreferences)
                self.settings?.window?.appearance = self.appPreferences.nativeAppearance
                if let menu = NSApp.mainMenu { AppLocalization.refresh(menu, language: self.appPreferences.language) }
                self.rebuildStatusMenu()
                self.settings?.update(shortcut: self.shortcut.activeShortcut,
                    problem: self.shortcutProblem.map { localizedError($0, language: self.appPreferences.language) })
                self.statusItem?.button?.toolTip = self.appPreferences.language.appName
                self.statusItem?.button?.setAccessibilityLabel(self.appPreferences.language.appName)
            }
            var loadError: Error?
            controller.editor.onError = { loadError = $0 }
            controller.editor.load(blocks: document.blocks)
            if let loadError { throw loadError }
            controller.updateDocumentInfo(document)
            controller.editor.onEdit = { [weak self] in self?.didEdit() }
            controller.editor.onError = { [weak self] error in
                self?.isDirty = true
                self?.noteWindow?.setSaveStatus(.unsaved(error))
            }
            controller.onHide = { [weak self] in _ = self?.flushSave() }
            controller.onRetrySave = { [weak self] in _ = self?.flushSave() }
            shortcut.onTrigger = { [weak self] in
                guard let self else { return }
                let isVerification = CommandLine.arguments.contains("--verify-workflow")
                if isVerification {
                    self.workflowShortcutTriggerCount += 1
                    self.diagnoseWorkflowShortcut("before-toggle")
                }
                self.noteWindow?.toggle()
                if isVerification { self.diagnoseWorkflowShortcut("after-toggle") }
            }
            setupMainMenu()
            setupStatusItem()
            let isVerification = CommandLine.arguments.contains("--verify-workflow")
            let savedPreset = appPreferences.shortcut
            do {
                try shortcut.register(savedPreset)
            } catch {
                shortcutProblem = error
                if savedPreset != .controlOptionN { try? shortcut.register(.controlOptionN) }
            }
            controller.setShortcut(shortcut.activeShortcut)
            rebuildStatusMenu()
            if !(isVerification && CommandLine.arguments.contains("--menu-shortcuts-only")),
               LoginLaunch.shouldShowWindow(for: NSAppleEventManager.shared().currentAppleEvent, isVerification: isVerification) {
                controller.show()
            }
            if isVerification {
                Task { await WorkflowVerifier.run(delegate: self) }
            }
        } catch {
            if CommandLine.arguments.contains("--verify-workflow") {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("无法打开本地备忘录")
            alert.informativeText = localizedError(error, language: appPreferences.language) + "\n\n" + L("原有数据未被覆盖。请检查数据库文件及目录权限后重新启动。")
            alert.alertStyle = .critical
            alert.addButton(withTitle: L("退出"))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    var activeShortcut: GlobalShortcut? { shortcut.activeShortcut }

    private func diagnoseWorkflowShortcut(_ stage: String) {
        let window = noteWindow?.window
        let responder = window?.firstResponder
        let responderType = responder.map { String(reflecting: type(of: $0)) } ?? "none"
        let editorOwnsFirstResponder = noteWindow.map { responder === $0.editor.textView } ?? false
        print("DIAGNOSTIC: workflow-shortcut observer=onTrigger stage=\(stage) " +
              "sequence=\(workflowShortcutTriggerCount) uptime=\(ProcessInfo.processInfo.systemUptime) " +
              "activeShortcut=\(activeShortcut?.title ?? "none") " +
              "visible=\(window?.isVisible == true) key=\(window?.isKeyWindow == true) " +
              "appActive=\(NSApp.isActive) firstResponderType=\(responderType) " +
              "editorOwnsFirstResponder=\(editorOwnsFirstResponder) " +
              "formattingVisible=\(noteWindow?.isFormattingVisible == true) " +
              "formattingKey=\(noteWindow?.formattingWindow?.isKeyWindow == true)")
    }

    func registerShortcut(_ preset: GlobalShortcut, requestPermission: Bool = false, persist: Bool = true) throws {
        try shortcut.register(preset, requestPermission: requestPermission)
        if persist { appPreferences.saveShortcut(preset) }
        shortcutProblem = nil
        noteWindow?.setShortcut(preset)
        rebuildStatusMenu()
    }

    var isShortcutRecording: Bool { shortcut.isPaused }
    var shortcutError: String? { shortcutProblem.map { localizedError($0, language: appPreferences.language) } }

    /// A recorder temporarily releases the physical hot key. Cancellation restores it;
    /// a failed restore is visible and never reported as an active registration.
    func setShortcutRecording(_ recording: Bool) -> String? {
        if recording { shortcut.pause(); return nil }
        do {
            try shortcut.resume()
            shortcutProblem = nil
            noteWindow?.setShortcut(shortcut.activeShortcut)
            rebuildStatusMenu()
            return nil
        } catch {
            shortcutProblem = error
            noteWindow?.setShortcut(shortcut.activeShortcut)
            rebuildStatusMenu()
            settings?.update(shortcut: shortcut.activeShortcut,
                             problem: localizedError(error, language: appPreferences.language))
            return localizedError(error, language: self.appPreferences.language)
        }
    }

    static func databaseURL(arguments: [String] = CommandLine.arguments,
                            applicationSupportDirectory: () throws -> URL = {
                                try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                            }) throws -> URL {
        if arguments.contains("--verify-workflow") {
            // Reject fixture invocations before NoteStore can create or load a database.
            // The everyday Application Support directory must never be a fixture fallback.
            let options = arguments.indices.filter {
                arguments[$0] == "--database" || arguments[$0].hasPrefix("--database=")
            }
            guard options.count == 1, let index = options.first,
                  arguments[index] == "--database", arguments.indices.contains(index + 1) else {
                throw NSError(domain: "QuickNote.Verification", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Verification requires exactly one explicit absolute --database file path"])
            }
            let path = arguments[index + 1]
            let leaf = (path as NSString).lastPathComponent
            guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0),
                  !leaf.isEmpty, leaf != ".", leaf != ".." else {
                throw NSError(domain: "QuickNote.Verification", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Verification requires an absolute --database file path"])
            }
            return URL(fileURLWithPath: path)
        }
        if let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        let support = try applicationSupportDirectory()
        return support.appendingPathComponent("QuickNote", isDirectory: true).appendingPathComponent("notes.sqlite")
    }

    private func didEdit() {
        document.updatedAt = Date()
        isDirty = true
        noteWindow?.didEdit(at: document.updatedAt)
        noteWindow?.setSaveStatus(.saving)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A timer from the preceding committed edit can fire during IME composition.
                // Keep the draft in the input client until the user confirms or cancels it.
                if self.noteWindow?.editor.textView.hasMarkedText() == true {
                    self.scheduleSave()
                } else {
                    _ = self.flushSave(commitPendingInput: false)
                }
            }
        }
    }

    @discardableResult
    func flushSave(commitPendingInput: Bool = true) -> Bool {
        if commitPendingInput { noteWindow?.editor.commitPendingInput() }
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty else { return true }
        do {
            if let editor = noteWindow?.editor { document.blocks = try editor.snapshot() }
            try store?.save(document)
            isDirty = false
            noteWindow?.updateDocumentInfo(document)
            noteWindow?.setSaveStatus(.saved)
            return true
        } catch {
            noteWindow?.setSaveStatus(.failed(error))
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !flushSave() else { shortcut.unregister(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("当前更改尚未保存")
        alert.informativeText = L("请返回备忘录检查保存错误并重试，或放弃本次未保存的更改。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("返回备忘录"))
        alert.addButton(withTitle: L("放弃更改并退出"))
        if alert.runModal() == .alertSecondButtonReturn { shortcut.unregister(); return .terminateNow }
        noteWindow?.show()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { AppPreferences.cleanUpVerificationPreferences() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        noteWindow?.dismissFormatting()
        WindowPlacement.keepVisible(noteWindow?.window)
        WindowPlacement.keepVisible(settings?.window)
    }
    func applicationDidBecomeActive(_ notification: Notification) { loginItems.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        noteWindow?.show()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: L("随记"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = AppPreferences.shared.language.appName
        statusItem = item
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: L("打开随记"), action: #selector(openNote), keyEquivalent: "")
        open.target = self
        if let preset = shortcut.activeShortcut {
            let info = menu.addItem(withTitle: appPreferences.language.format("全局快捷键：%@", preset.title), action: nil, keyEquivalent: "")
            info.isEnabled = false
        }
        if shortcutProblem != nil {
            let info = menu.addItem(withTitle: L("快捷键未就绪，请在设置中检查"), action: #selector(openSettings), keyEquivalent: "")
            info.target = self
        }
        menu.addItem(.separator())
        let preferences = menu.addItem(withTitle: L("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L("退出随记"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem?.menu = menu
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: appPreferences.language.appName)
        let appItem = NSMenuItem(title: appPreferences.language.appName, action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)
        add(appMenu, L("设置…"), #selector(openSettings), ",", target: self)
        appMenu.addItem(.separator())
        add(appMenu, L("退出随记"), #selector(quit), "q", target: self)

        let file = NSMenu(title: L("文件"))
        let fileItem = NSMenuItem(title: L("文件"), action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)
        add(file, L("关闭窗口"), #selector(NSWindow.performClose(_:)), "w")

        let edit = NSMenu(title: L("编辑"))
        let editItem = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        add(edit, L("撤销"), Selector(("undo:")), "z")
        add(edit, L("重做"), Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, L("剪切"), #selector(NSText.cut(_:)), "x")
        add(edit, L("复制"), #selector(NSText.copy(_:)), "c")
        add(edit, L("粘贴"), #selector(NSText.paste(_:)), "v")
        add(edit, L("粘贴并匹配样式"), #selector(NSTextView.pasteAsPlainText(_:)), "v", modifiers: [.command, .option, .shift])
        add(edit, L("全选"), #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = add(edit, L("查找…"), #selector(NSTextView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let format = NSMenu(title: L("格式"))
        let formatItem = NSMenuItem(title: L("格式"), action: nil, keyEquivalent: "")
        formatItem.submenu = format
        main.addItem(formatItem)
        let groups: [[EditorShortcuts.Command]] = [
            [.bold, .italic, .underline, .strikethrough, .link, .formatting],
            [.title, .heading, .subheading, .body, .code, .bullet, .dashed, .numbered, .quote, .checklist, .checked],
            [.indent, .outdent, .clear]
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { format.addItem(.separator()) }
            for command in group {
                let item = add(format, command.title, #selector(editorCommand(_:)), command.key,
                               modifiers: command.modifiers, target: self)
                item.representedObject = command
            }
        }
        format.addItem(.separator())
        let fontItem = NSMenuItem(title: L("字体"), action: nil, keyEquivalent: "")
        let nativeFontMenu = NSFontManager.shared.fontMenu(true)
        // The editor owns these commands, including their selection and IME safeguards.
        // Avoid a second native item handling the same key after our item is disabled.
        for item in nativeFontMenu?.items ?? [] where ["b", "i", "u"].contains(item.keyEquivalent)
            && item.keyEquivalentModifierMask == .command {
            nativeFontMenu?.removeItem(item)
        }
        fontItem.submenu = nativeFontMenu
        format.addItem(fontItem)
        add(format, L("文字颜色…"), #selector(NSApplication.orderFrontColorPanel(_:)), "", target: NSApp)
        NSApp.mainMenu = main
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    @objc private func openNote() { noteWindow?.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editorCommand(_:)) {
            return noteWindow?.acceptsEditorCommands == true
        }
        return true
    }

    @objc private func editorCommand(_ sender: NSMenuItem) {
        guard let controller = noteWindow, controller.acceptsEditorCommands,
              let command = sender.representedObject as? EditorShortcuts.Command else { return }
        switch command {
        case .link: controller.editLink()
        case .formatting: controller.toggleFormatting(nil)
        default:
            _ = command.perform(on: controller.editor)
            if controller.isFormattingVisible { controller.dismissFormatting(); controller.show() }
        }
    }

    @objc private func openSettings() {
        noteWindow?.dismissFormatting()
        if settings == nil {
            settings = SettingsWindowController(databaseURL: store!.url, preferences: appPreferences, loginItems: loginItems)
            settings?.onRecordingChange = { [weak self] recording in self?.setShortcutRecording(recording) }
            settings?.onChooseShortcut = { [weak self] preset in
                guard let self else { return L("应用已退出") }
                do {
                    try self.registerShortcut(preset, requestPermission: true)
                    return nil
                } catch {
                    self.shortcutProblem = error
                    self.rebuildStatusMenu()
                    return localizedError(error, language: self.appPreferences.language)
                }
            }
        }
        settings?.update(shortcut: shortcut.activeShortcut, problem: shortcutProblem.map { localizedError($0, language: appPreferences.language) })
        settings?.show()
    }
}
