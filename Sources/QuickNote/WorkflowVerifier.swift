import AppKit
import ApplicationServices
import Carbon
import QuickNoteCore

@MainActor
private final class WorkflowLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var registrationStatus: LoginItemStatus = .requiresApproval
    var failRegistration = false
    var registered = 0
    var unregistered = 0
    var settingsOpened = 0
    func register() throws {
        registered += 1
        if failRegistration { throw NSError(domain: "QuickNote.Workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟系统拒绝注册登录项"]) }
        status = registrationStatus
    }
    func unregister() throws { unregistered += 1; status = .disabled }
    func openSystemSettings() { settingsOpened += 1 }
}

@MainActor
private final class WorkflowMenuShortcutProbe: NSObject {
    var invocations = 0
    @objc func invoke(_ sender: Any?) { invocations += 1 }
}

/// Runs the production window, editor, save callbacks and SQLite store with an isolated database.
@MainActor
enum WorkflowVerifier {
    struct VerificationFailure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationFailure(message) }
        print("PASS: \(message)")
    }

    static func run(delegate: AppDelegate) async {
        setbuf(stdout, nil)
        do {
            guard let controller = delegate.noteWindow, let store = delegate.store,
                  let index = CommandLine.arguments.firstIndex(of: "--database"),
                  CommandLine.arguments.indices.contains(index + 1) else {
                throw VerificationFailure("Verification requires an explicit isolated --database path")
            }
            let folder = store.url.deletingLastPathComponent()
            let expectedURL = folder.appendingPathComponent("expected.json")
            if CommandLine.arguments.contains("--window-shortcuts-only") {
                defer { AppPreferences.cleanUpVerificationPreferences() }
                if CommandLine.arguments.contains("--menu-shortcuts-only") {
                    try verifyShiftedMenuShortcuts(controller, folder: folder)
                } else if CommandLine.arguments.contains("--undo-redo-only") {
                    try await verifyUndoRedoShortcuts(controller)
                    try JSONEncoder().encode(["status": "passed", "coverage": "Native Command Z undo followed by Command Shift Z redo with a real editor mutation"]).write(to: folder.appendingPathComponent("undo-redo-shortcuts.json"), options: .atomic)
                } else {
                    try await verifyWindowShortcuts(delegate, controller: controller, store: store, folder: folder)
                }
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--settings-only") {
                let shortcutURL = folder.appendingPathComponent("expected-shortcut.json")
                if CommandLine.arguments.contains("--read-back") {
                    let expected = try JSONDecoder().decode(GlobalShortcut.self, from: Data(contentsOf: shortcutURL))
                    try require(delegate.activeShortcut == expected && AppPreferences.shared.shortcut == expected,
                                "Relaunch restores the custom shortcut recorded through the actual Settings window")
                    // Relaunch persistence is independent of the shared desktop's focus.
                } else {
                    controller.editor.textView.insertText("隔离设置录入验证 👩🏽‍💻", replacementRange: controller.editor.textView.selectedRange())
                    controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
                    _ = EditorShortcuts.Command.bold.perform(on: controller.editor)
                    let settings = SettingsWindowController(databaseURL: store.url, loginItems: LoginItemService.disabledMockController())
                    settings.update(shortcut: delegate.activeShortcut, problem: nil)
                    settings.show()
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if CommandLine.arguments.contains("--shortcut-only") {
                        AppPreferences.shared.language = .english
                        settings.selectPage(.editing)
                        try await Task.sleep(nanoseconds: 100_000_000)
                        try captureWindow(settings.window, folder: folder, suffix: "settings-editing-en-final")
                    } else { try await verifySettingsSections(settings, folder: folder) }
                    try await verifyCustomShortcut(delegate, controller: controller, settings: settings, folder: folder,
                                                   permitDesktopInterference: true)
                    try JSONEncoder().encode(AppPreferences.shared.shortcut).write(to: shortcutURL, options: .atomic)
                    settings.close()
                }
                print("PASS: Independent native settings checks; desktop focus coverage is reported separately")
                NSApp.terminate(nil)
                return
            }
            let expectedShortcutURL = folder.appendingPathComponent("expected-shortcut.json")
            if CommandLine.arguments.contains("--read-back") {
                let expectedShortcut = try JSONDecoder().decode(GlobalShortcut.self, from: Data(contentsOf: expectedShortcutURL))
                try require(delegate.activeShortcut == expectedShortcut && AppPreferences.shared.shortcut == expectedShortcut,
                            "Relaunch restores the user-recorded Carbon shortcut from isolated preferences")
                if CGPreflightPostEventAccess() { try await verifyShortcut(delegate, controller: controller, shortcut: expectedShortcut) }
            } else { try require(delegate.activeShortcut == .controlOptionN, "Carbon global shortcut registered") }
            if CommandLine.arguments.contains("--read-back") {
                let expected = try JSONDecoder().decode(NoteDocument.self, from: Data(contentsOf: expectedURL))
                let restored = try controller.editor.snapshot()
                try require(restored.map(\.text) == expected.blocks.map(\.text), "Relaunch restored all Unicode paragraphs")
                try require(restored.map(\.id) == expected.blocks.map(\.id), "Relaunch preserved block identities")
                try require(restored.map(\.kind) == expected.blocks.map(\.kind), "Relaunch restored paragraph styles")
                try require(restored.map(\.isChecked) == expected.blocks.map(\.isChecked), "Relaunch restored checklist state")
                try require(restored.map(\.indentLevel) == expected.blocks.map(\.indentLevel), "Relaunch restored list indentation")
                try require(restored[0].richText != nil, "Relaunch retained rich text")
                let font = controller.editor.textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                try require(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                            "Relaunch displayed the title font")
                try verifyInlineFormats(controller)
                try capture(controller, folder: folder, suffix: "restored")
            } else {
                try require(delegate.document.blocks.allSatisfy { $0.text.isEmpty }, "Fresh database contains no sample data")
                let textView = controller.editor.textView
                textView.insertText("今天的随记", replacementRange: textView.selectedRange())
                controller.editor.apply(.title)
                textView.insertNewline(nil)
                controller.editor.apply(.body)
                textView.insertText("把想法记在这一页 👩🏽‍💻", replacementRange: textView.selectedRange())
                textView.insertNewline(nil)
                controller.editor.apply(.checklist)
                textView.insertText("准备下一步", replacementRange: textView.selectedRange())
                controller.editor.toggleChecked()
                textView.insertNewline(nil)
                textView.insertText("保持专注", replacementRange: textView.selectedRange())
                textView.insertNewline(nil)
                textView.insertNewline(nil)
                // Native undo groups close between input events; model that boundary
                // before testing a separate click rather than grouping setup into it.
                try await Task.sleep(nanoseconds: 50_000_000)
                try verifyChecklistClick(controller)
                let beforeHide = try controller.editor.snapshot()
                try require(beforeHide.map(\.text) == ["今天的随记", "把想法记在这一页 👩🏽‍💻", "准备下一步", "保持专注", ""],
                            "Native editing created the expected paragraphs")
                try require(beforeHide.map(\.kind) == [.title, .body, .checklist, .checklist, .body],
                            "Lists continue and an empty Return exits to body")
                try require(beforeHide[2].isChecked && !beforeHide[3].isChecked, "Only the completed checklist item is checked")
                try await Task.sleep(nanoseconds: 600_000_000)
                try require(try store.load().blocks.map(\.text) == beforeHide.map(\.text), "Debounced autosave commits without closing the window")
                textView.breakUndoCoalescing()
                textView.insertText("收起前输入", replacementRange: textView.selectedRange())
                let pending = try controller.editor.snapshot()
                let selection = textView.selectedRange()
                controller.hide()
                try require(controller.window?.isVisible == false, "Hide closes the panel without ending the application")
                let persisted = try store.load()
                try require(persisted.blocks.map(\.text) == pending.map(\.text), "Hide immediately flushes pending autosave")
                controller.show()
                try require(textView.selectedRange() == selection, "Show resumes the same caret position")
                textView.breakUndoCoalescing()
                textView.undoManager?.undo()
                try require(try controller.editor.snapshot().map(\.text) == beforeHide.map(\.text), "Native Undo restores the last edit")
                try require(delegate.flushSave(), "Undo is saved by the production save coordinator")
                try JSONEncoder().encode(store.load()).write(to: expectedURL, options: .atomic)
                (controller.window as? NotePanel)?.cancelOperation(nil)
                try require(controller.window?.isVisible == false, "Escape hides the panel")
                controller.show()
                if CGPreflightPostEventAccess() {
                    try await verifyShortcut(delegate, controller: controller)
                    try await verifyFnShortcut(delegate, controller: controller)
                } else {
                    print("SKIP: Synthetic physical shortcut requires existing event posting permission; registration is verified")
                }
                try capture(controller, folder: folder, suffix: "edited")
                try verifyWindowRecovery(delegate, controller: controller)
                try await verifyMinimalPresentation(delegate, controller: controller, folder: folder)
                try await verifyEditorShortcuts(controller)
                try await verifyFocusedEditing(delegate, controller: controller)
                try await verifyEnhancedEditing(delegate, controller: controller, folder: folder)
                try JSONEncoder().encode(store.load()).write(to: expectedURL, options: .atomic)
                let settingsSelection = textView.selectedRange()
                textView.setSelectedRange((textView.string as NSString).range(of: "把想法"))
                let beforeSettings = NSAttributedString(attributedString: textView.attributedString())
                controller.toggleFormatting(nil)
                let appMenu = NSApp.mainMenu!.items[0].submenu!
                appMenu.performActionForItem(at: 0)
                try await Task.sleep(nanoseconds: 80_000_000)
                try require(!controller.isFormattingVisible && controller.window?.isVisible == true,
                            "Opening Settings from the native menu dismisses the palette without hiding the note")
                if let settingsWindow = NSApp.windows.first(where: { $0.title == "随记设置" }) {
                    try sendKey(to: settingsWindow, characters: "b", code: 11, modifiers: .command)
                    try sendKey(to: settingsWindow, characters: "+", code: 24, modifiers: [.command, .shift])
                    try require(textView.attributedString().isEqual(to: beforeSettings),
                                "Font-size shortcuts in Settings do not change the background note")
                    try sendKey(to: settingsWindow, characters: "-", code: 27, modifiers: .command)
                    try require(textView.attributedString().isEqual(to: beforeSettings),
                                "Formatting shortcuts in Settings do not change the background note")
                }
                controller.toggle()
                try require(controller.window?.isVisible == true && controller.window?.isKeyWindow == true,
                            "Shortcut toggle from Settings brings the note forward")
                textView.setSelectedRange(settingsSelection)
                NSApp.windows.first(where: { $0.title == "随记设置" })?.close()
                let loginManager = WorkflowLoginItemManager()
                let loginItems = LoginItemController(manager: loginManager)
                let settings = SettingsWindowController(databaseURL: store.url, loginItems: loginItems)
                settings.update(shortcut: delegate.activeShortcut, problem: nil)
                settings.show()
                try captureWindow(settings.window, folder: folder, suffix: "settings")
                settings.update(shortcut: .controlOptionN, problem: "Fn Q 需要辅助功能权限。当前仍使用 ⌃⌥N。")
                try captureWindow(settings.window, folder: folder, suffix: "settings-permission")
                settings.selectPage(.general)
                try await verifyLoginItems(settings, loginItems: loginItems, manager: loginManager, folder: folder)
                settings.selectPage(.storage)
                try await Task.sleep(nanoseconds: 80_000_000)
                try captureWindow(settings.window, folder: folder, suffix: "settings-storage")
                settings.onChooseShortcut = { _ in "验证中的注册失败" }
                settings.chooseShortcut(.fnQ)
                try require(settings.selectedShortcut == .controlOptionN && settings.shortcutProblem != nil,
                            "Settings keep the active shortcut after registration fails")
                try verifyPreferences(controller, folder: folder)
                try await verifyLanguageSwitch(controller, settings: settings, folder: folder)
                try await verifySettingsSections(settings, folder: folder)
                try await verifyCustomShortcut(delegate, controller: controller, settings: settings, folder: folder)
                try JSONEncoder().encode(AppPreferences.shared.shortcut).write(to: expectedShortcutURL, options: .atomic)
                settings.close()
            }
            print("PASS: Single-note native application workflow")
            NSApp.terminate(nil)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyMinimalPresentation(_ delegate: AppDelegate, controller: NoteWindowController, folder: URL) async throws {
        try require(!controller.isFormattingVisible && !controller.isSaveErrorVisible, "Writing surface hides tools and routine save status")
        try require(controller.window?.isOpaque == false && controller.editor.textView.drawsBackground == false,
                    "Editor and native frame expose the shared glass surface")
        try require(controller.editor.textView.textContainerInset == NSSize(width: 20, height: 14),
                    "Editor uses compact writing margins")
        try require(controller.window?.contentView?.superview?.layer?.masksToBounds == true,
                    "Main window clips the native frame to its rounded corners")
        try require(controller.window?.contentView?.superview?.layer?.cornerRadius == 16,
                    "Main window shares the sibling apps' 16-point corner radius")
        let textView = controller.editor.textView
        let originalCaret = textView.selectedRange()
        let selection = (textView.string as NSString).range(of: "把想法")
        let originalFont = textView.attributedString().attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont
        let originalTraits = originalFont.map { NSFontManager.shared.traits(of: $0) }
        textView.setSelectedRange(selection)
        controller.toggleFormatting(nil)
        try await Task.sleep(nanoseconds: 120_000_000)
        try require(controller.isFormattingVisible && textView.selectedRange() == selection, "Format popover preserves the editor selection")
        try require(controller.formattingWindow?.isOpaque == false && controller.formattingWindow?.styleMask.contains(.titled) == false,
                    "Formatting palette uses a transparent borderless native window")
        try require(controller.formattingWindow?.contentView?.superview?.layer?.cornerRadius == 16,
                    "Formatting palette removes rectangular frame corners")
        try captureWindow(controller.formattingWindow, folder: folder, suffix: "format") { appearance in
            try verifyToolbarSymbolLayout(controller, context: "zh-Hans/default/\(appearance)")
        }
        guard let formatRoot = controller.formattingWindow?.contentView,
              let bold = findButton(in: formatRoot, toolTip: "粗体（⌘B）") else {
            throw VerificationFailure("Format popover must expose the bold control")
        }
        guard let style = findStylePopup(in: formatRoot) else {
            throw VerificationFailure("Format popover must expose paragraph styles")
        }
        try require(style.window?.makeFirstResponder(style) == true && style.window?.firstResponder === style,
                    "Paragraph styles accept keyboard focus without losing the editor selection")
        try require(textView.selectedRange() == selection, "Keyboard focus in formatting tools preserves the text selection")
        bold.performClick(nil)
        try require(!controller.isFormattingVisible, "Choosing a format dismisses the tools")
        try require(controller.window?.firstResponder === textView, "A format action returns focus to the editor")
        let font = textView.attributedString().attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont
        try require(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Popover bold action formats the selected text")
        // The user's Undo is a separate input event after the popover action.
        try await Task.sleep(nanoseconds: 50_000_000)
        textView.undoManager?.undo()
        let restoredFont = textView.attributedString().attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont
        try require(restoredFont.map { NSFontManager.shared.traits(of: $0) } == originalTraits,
                    "Undo restores the formatting applied through the popover")
        textView.setSelectedRange(originalCaret)
        textView.setSelectedRange(selection)
        controller.toggleFormatting(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        // Exercise AppKit's real menu tracking rather than only assigning popup focus.
        for (characters, code) in [("\u{f701}", UInt16(125)), ("\r", UInt16(36))] {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.formattingWindow!.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        style.performClick(nil)
        try require(!controller.isFormattingVisible && controller.editor.formatState.kind != .body,
                    "Native paragraph popup opens and accepts a keyboard selection")
        try await Task.sleep(nanoseconds: 50_000_000)
        textView.undoManager?.undo()
        try require(controller.editor.formatState.kind == .body, "Undo restores the style chosen from the native popup")
        controller.toggleFormatting(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        guard let more = findMorePopup(in: formatRoot) else { throw VerificationFailure("Font and color controls must be accessible from the palette") }
        more.selectItem(at: 1)
        more.sendAction(more.action, to: more.target)
        try require(NSFontManager.shared.fontPanel(false)?.isVisible == true && NSFontManager.shared.target === textView,
                    "Palette More opens the native font panel connected to the editor")
        NSFontManager.shared.fontPanel(false)?.orderOut(nil)
        controller.show()
        controller.toggleFormatting(nil)
        more.selectItem(at: 2)
        more.sendAction(more.action, to: more.target)
        try require(NSColorPanel.shared.isVisible, "Palette More opens the native text color panel")
        NSColorPanel.shared.orderOut(nil)
        controller.show()
        textView.setSelectedRange(originalCaret)
        controller.toggleFormatting(nil)
        controller.formattingWindow?.cancelOperation(nil)
        try require(!controller.isFormattingVisible && controller.window?.isVisible == true,
                    "Escape dismisses formatting tools and keeps the note open")
        controller.toggleFormatting(nil)
        if let window = controller.window, let outside = NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 160, y: window.contentLayoutRect.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1) {
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: outside.locationInWindow,
                modifierFlags: [], timestamp: outside.timestamp + 0.01, windowNumber: window.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 0) {
                NSApp.postEvent(up, atStart: false)
            }
            NSApp.sendEvent(outside)
            try require(!controller.isFormattingVisible, "Clicking the editor dismisses the formatting palette")
        }
        textView.setSelectedRange(originalCaret)
        guard let store = delegate.store, let root = controller.window?.contentView else {
            throw VerificationFailure("Save-error presentation requires the isolated store and note surface")
        }
        try require(delegate.flushSave(), "Save-error presentation starts with a committed document")
        let savedBeforeError = try store.load().blocks
        let caretBeforeError = textView.selectedRange()
        let pendingOffset = (textView.string as NSString).length
        let pendingText = " 待重试内容"
        textView.breakUndoCoalescing()
        textView.insertText(pendingText, replacementRange: NSRange(location: pendingOffset, length: 0))
        let pendingDocument = try controller.editor.snapshot()
        let pendingCaret = textView.selectedRange()
        let errorMessage = "保存失败：暂时无法写入本地数据库，请重试。"
        controller.setSaveState(errorMessage, isError: true)
        try require(controller.isSaveErrorVisible, "Save errors remain visible while the tools are hidden")
        guard let inline = findAccessible("quick-note-save-error", in: root) as? NSView,
              let retry = findTitledButton(in: inline, title: "重试") else {
            throw VerificationFailure("Save error must expose an inline container and its retry button")
        }
        try require(!inline.isHiddenOrHasHiddenAncestor && retry.isEnabled && !retry.isHiddenOrHasHiddenAncestor,
                    "Inline save error and retry control remain visible and enabled")
        try require(descendantViews(in: inline).contains { ($0 as? NSTextField)?.stringValue == errorMessage },
                    "Inline save error exposes the complete failure label")
        let rootMaterials = materialViews(in: root)
        let inlineMaterials = materialViews(in: inline)
        if CommandLine.arguments.contains("--standard-appearance") {
            try require(root is NSVisualEffectView, "Forced standard verification uses the native fallback material")
        }
        print("DIAGNOSTIC: save-error root=\(String(reflecting: type(of: root))) " +
              "inline=\(String(reflecting: type(of: inline))) " +
              "rootMaterialCount=\(rootMaterials.count) inlineMaterialCount=\(inlineMaterials.count)")
        let materialTree = descendantViews(in: root).map { view in
            ["class": String(reflecting: type(of: view)),
             "parentClass": view.superview.map { String(reflecting: type(of: $0)) } ?? "",
             "isMaterial": isMaterialView(view), "isInline": view === inline] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: materialTree, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("save-error-material-tree.json"), options: .atomic)
        try require(isMaterialView(root) && inlineMaterials.isEmpty && rootMaterials.count == 1,
                    "Save error adds no nested material to the single note glass surface")
        try require(try controller.editor.snapshot() == pendingDocument && textView.selectedRange() == pendingCaret,
                    "Showing a save error preserves pending text, rich text, identities and selection")
        try require(try store.load().blocks == savedBeforeError && pendingDocument.map(\.text) != savedBeforeError.map(\.text),
                    "Showing a save error leaves pending edits unsaved")
        try capture(controller, folder: folder, suffix: "save-error") { appearance in
            try require(isMaterialView(root) && materialViews(in: inline).isEmpty && materialViews(in: root).count == 1,
                        "Save error keeps one root material and no inline material in \(appearance) appearance")
        }
        retry.performClick(nil)
        try require(try store.load().blocks.map(\.text) == pendingDocument.map(\.text)
                    && store.load().blocks.map(\.id) == pendingDocument.map(\.id),
                    "Native retry saves the pending document through the production save coordinator")
        try require(!controller.isSaveErrorVisible, "Successful saving returns to the quiet writing surface")
        textView.breakUndoCoalescing()
        textView.insertText("", replacementRange: NSRange(location: pendingOffset, length: (pendingText as NSString).length))
        textView.setSelectedRange(caretBeforeError)
        try require(delegate.flushSave() && controller.editor.snapshot().map(\.text) == savedBeforeError.map(\.text),
                    "Save-error presentation restores the original fixture content")
        let originalFrame = controller.window!.frame
        controller.window?.setContentSize(NSSize(width: 420, height: 360))
        try capture(controller, folder: folder, suffix: "compact")
        controller.window?.setFrame(originalFrame, display: true)
    }

    private static func descendantViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendantViews(in: $0) }
    }

    private static func isMaterialView(_ view: NSView) -> Bool {
        if #available(macOS 26.0, *), view is NSGlassEffectView { return true }
        return view is NSVisualEffectView
    }

    private static func materialViews(in view: NSView) -> [NSView] {
        descendantViews(in: view).filter { isMaterialView($0) }
    }

    private static func verifyWindowRecovery(_ delegate: AppDelegate, controller: NoteWindowController) throws {
        guard let window = controller.window else { throw VerificationFailure("Missing note window") }
        let frame = window.frame
        let text = NSAttributedString(attributedString: controller.editor.textView.attributedString())
        let selection = controller.editor.textView.selectedRange()
        defer { window.setFrame(frame, display: true) }
        window.setFrameOrigin(NSPoint(x: 100_000, y: 100_000))
        controller.toggleFormatting(nil)
        delegate.applicationDidChangeScreenParameters(Notification(name: NSApplication.didChangeScreenParametersNotification))
        try require(!controller.isFormattingVisible, "Screen changes dismiss formatting tools with stale anchors")
        try require(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) },
                    "Screen changes keep the note inside the current visible workspace")
        controller.show()
        try require(controller.editor.textView.attributedString().isEqual(to: text) && controller.editor.textView.selectedRange() == selection,
                    "Window recovery preserves rich text and the selected range")
    }

    private static func verifyLoginItems(_ settings: SettingsWindowController, loginItems: LoginItemController,
                                         manager: WorkflowLoginItemManager, folder: URL) async throws {
        guard let window = settings.window else { throw VerificationFailure("Missing Settings window") }
        let originalSize = window.frame.size
        // Expand the fixture to capture the complete editing page, including approval/error feedback.
        window.setContentSize(NSSize(width: 640, height: 680))
        defer { window.setFrame(NSRect(origin: window.frame.origin, size: originalSize), display: true) }
        try await Task.sleep(nanoseconds: 80_000_000)
        try pressAccessible("settings.launchAtLogin", in: window)
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(manager.registered == 1 && loginItems.status == .requiresApproval,
                    "The native login switch reads the pending approval state without assuming enabled")
        try pressAccessible("settings.launchAtLogin.openSettings", in: window)
        try require(manager.settingsOpened == 1, "Login approval opens System Settings through the injected service")
        try captureWindow(window, folder: folder, suffix: "settings-login-approval")
        try pressAccessible("settings.launchAtLogin", in: window)
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(manager.unregistered == 1 && !loginItems.isEnabled, "The native login switch can cancel pending approval")
        manager.failRegistration = true
        try pressAccessible("settings.launchAtLogin", in: window)
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(!loginItems.isEnabled && loginItems.error != nil &&
                    findAccessible("settings.launchAtLogin.error", in: window) != nil,
                    "A login registration failure keeps the switch off and displays the actual error")
        try captureWindow(window, folder: folder, suffix: "settings-login-failure")
        manager.failRegistration = false
        manager.registrationStatus = .enabled
        try pressAccessible("settings.launchAtLogin", in: window)
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(loginItems.status == .enabled && loginItems.error == nil,
                    "Retrying the native login switch refreshes system state and clears the error")
        try pressAccessible("settings.launchAtLogin", in: window)
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    private static func pressAccessible(_ identifier: String, in root: Any) throws {
        guard let object = findAccessible(identifier, in: root) else { throw VerificationFailure("Missing native control: \(identifier)") }
        if let control = object as? NSControl { control.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { throw VerificationFailure("Native control cannot be pressed: \(identifier)") }
        typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
        let action = unsafeBitCast(object.method(for: selector), to: Action.self)
        try require(action(object, selector).boolValue, "Native control responds: \(identifier)")
    }

    // SwiftUI virtual accessibility nodes expose selectors without declaring the AppKit protocol.
    private static func findAccessible(_ identifier: String, in root: Any, depth: Int = 0) -> NSObject? {
        guard depth < 30, let object = root as? NSObject else { return nil }
        let id = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        for child in values {
            if let result = findAccessible(identifier, in: child, depth: depth + 1) { return result }
        }
        return nil
    }

    private static func sendKey(to window: NSWindow, characters: String, code: UInt16,
                                modifiers: NSEvent.ModifierFlags) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { throw VerificationFailure("Unable to construct native key event") }
        NSApp.sendEvent(event)
    }

    /// Native menu matching needs the layout metadata retained by a CGEvent backing.
    /// Plain keyEvent(characters:) can report the same text while matching Shift differently.
    private static func menuKeyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        guard let physical = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
            throw VerificationFailure("Unable to construct physical menu key event")
        }
        physical.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        guard let event = NSEvent(cgEvent: physical) else { throw VerificationFailure("Unable to construct native menu key event") }
        return event
    }

    private static func verifyWindowShortcuts(_ delegate: AppDelegate, controller: NoteWindowController,
                                               store: NoteStore, folder: URL) async throws {
        guard let note = controller.window else { throw VerificationFailure("Missing note window") }
        let text = controller.editor.textView
        text.insertText("Isolated window shortcut note 你好", replacementRange: text.selectedRange())
        text.setSelectedRange(NSRange(location: 0, length: 8))
        let before = NSAttributedString(attributedString: text.attributedString())
        let selection = text.selectedRange()
        let shortcut = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_5),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘5"))
        try delegate.registerShortcut(shortcut, persist: false)
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppPreferences.shared.language = language
            controller.show()
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(note.isKeyWindow && NSApp.isActive, "Window shortcut verification owns desktop focus")
            try sendKey(to: note, characters: ",", code: 43, modifiers: .command)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let settings = NSApp.windows.first(where: { $0.title == language.text("随记设置") }) else {
                throw VerificationFailure("Command comma did not create Settings")
            }
            try require(settings.isKeyWindow && settings.isVisible && note.isVisible,
                        "Command comma opens Settings and preserves the note (\(language.rawValue))")
            try sendKey(to: settings, characters: "W", code: 13, modifiers: [.command, .shift])
            try require(settings.isVisible, "Command Shift W does not close Settings")
            try sendKey(to: settings, characters: "w", code: 13, modifiers: .command)
            try require(!settings.isVisible && note.isVisible,
                        "Command W closes only the key Settings window (\(language.rawValue))")
            controller.show()
            try sendKey(to: note, characters: ",", code: 43, modifiers: .command)
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(settings.isVisible && settings.isKeyWindow, "Command comma reopens the same Settings window")
            guard let recorder = recorder(in: settings.contentView!) else {
                throw VerificationFailure("Missing native shortcut recorder")
            }
            recorder.performClick(nil)
            try require(recorder.isRecording && delegate.isShortcutRecording, "Recorder owns shortcut input")
            try sendKey(to: settings, characters: "\u{1b}", code: 53, modifiers: [])
            try require(!recorder.isRecording && !delegate.isShortcutRecording && settings.isVisible &&
                        delegate.activeShortcut == shortcut,
                        "First Escape cancels recording and restores the global shortcut without closing Settings")
            try sendKey(to: settings, characters: "\u{1b}", code: 53, modifiers: [])
            try require(!settings.isVisible && note.isVisible, "Escape closes Settings after recording is cancelled")
            try require(text.attributedString().isEqual(to: before) && text.selectedRange() == selection,
                        "Settings shortcuts preserve note rich text and selection")
            controller.show()
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
            text.insertText(" pending", replacementRange: text.selectedRange())
            let pending = try controller.editor.snapshot()
            try sendKey(to: note, characters: "w", code: 13, modifiers: .command)
            try require(!note.isVisible, "Command W hides the note through its save coordinator")
            try require(try store.load().blocks.map(\.text) == pending.map(\.text),
                        "Command W flushes pending note edits to the isolated database")
            controller.show()
            text.setSelectedRange(NSRange(location: before.length, length: text.string.utf16.count - before.length))
            text.insertText("", replacementRange: text.selectedRange())
            text.setSelectedRange(selection)
        }
        try await verifyUndoRedoShortcuts(controller)
        try await verifyEditorShortcuts(controller)
        controller.dismissFormatting()
        if CGPreflightPostEventAccess() {
            try await verifyShortcut(delegate, controller: controller, shortcut: shortcut)
        } else {
            print("SKIP: Physical custom shortcut injection requires existing event posting permission; Carbon registration is verified")
        }
        try captureWindow(note, folder: folder, suffix: "window-shortcuts")
        try JSONEncoder().encode(["status": "passed", "coverage": "Native NSApplication.sendEvent routing for bilingual Settings Command comma, Command W, Escape, recorder cancellation and note close persistence"]).write(to: folder.appendingPathComponent("window-shortcuts.json"), options: .atomic)
        print("PASS: Native window shortcut checks with isolated data and preferences")
    }

    private static func verifyShiftedMenuShortcuts(_ controller: NoteWindowController, folder: URL) throws {
        print("DIAGNOSTIC: menu probe key=\(NSApp.keyWindow?.title ?? "none") noteVisible=\(controller.window?.isVisible == true) formattingVisible=\(controller.formattingWindow?.isVisible == true) active=\(NSApp.isActive)")
        try require(NSApp.keyWindow == nil && controller.window?.isVisible == false &&
                    controller.formattingWindow?.isVisible == false,
                    "Menu matching probe keeps note and formatting windows hidden without a key window")
        var roots: [NSMenu] = NSApp.mainMenu.map { [$0] } ?? []
        func collectPopupMenus(_ view: NSView) {
            if let popup = view as? NSPopUpButton, let menu = popup.menu { roots.append(menu) }
            view.subviews.forEach(collectPopupMenus)
        }
        if let view = controller.window?.contentView { collectPopupMenus(view) }
        if let view = controller.formattingWindow?.contentView { collectPopupMenus(view) }
        let probe = WorkflowMenuShortcutProbe()
        var rows: [[String: String]] = []
        var failures: [String] = []
        func verify(_ menu: NSMenu) throws {
            for item in menu.items {
                if let submenu = item.submenu { try verify(submenu) }
                let key = item.keyEquivalent
                guard item.keyEquivalentModifierMask.contains(.shift), key.count == 1,
                      key.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) else { continue }
                let action = item.action, target = item.target, enabled = item.isEnabled
                let automaticallyEnabled = menu.autoenablesItems
                defer {
                    item.action = action; item.target = target; item.isEnabled = enabled
                    menu.autoenablesItems = automaticallyEnabled
                }
                menu.autoenablesItems = false
                item.action = #selector(WorkflowMenuShortcutProbe.invoke(_:))
                item.target = probe
                item.isEnabled = true
                let before = probe.invocations
                let character = key.uppercased()
                let codes: [String: UInt16] = ["z": 6, "v": 9, "x": 7, "t": 17, "h": 4, "j": 38,
                    "b": 11, "m": 46, "l": 37, "u": 32, "c": 8, "s": 1, "p": 35]
                guard let code = codes[key.lowercased()] else { throw VerificationFailure("Menu probe needs a physical key code for \(key)") }
                let event = try menuKeyEvent(code: code, modifiers: item.keyEquivalentModifierMask)
                let handled = menu.performKeyEquivalent(with: event)
                let passed = handled && probe.invocations == before + 1
                rows.append(["title": item.title, "keyEquivalent": key, "event": character,
                             "result": passed ? "passed" : "failed"])
                print("\(passed ? "PASS" : "FAIL"): Shifted menu key \(item.title) key=\(key) event=\(character)")
                if !passed { failures.append(item.title) }
            }
        }
        for root in roots { try verify(root) }
        try JSONEncoder().encode(rows).write(to: folder.appendingPathComponent("menu-shortcuts.json"), options: .atomic)
        try require(!rows.isEmpty && failures.isEmpty,
                    "All \(rows.count) shifted-letter main and popup menu items match uppercase native events")
    }

    private static func verifyUndoRedoShortcuts(_ controller: NoteWindowController) async throws {
        guard let window = controller.window else { throw VerificationFailure("Missing note window") }
        controller.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(window.isKeyWindow && NSApp.isActive, "Undo and redo checks own the native editor focus")
        let text = controller.editor.textView
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.breakUndoCoalescing()
        text.undoManager?.removeAllActions()
        let before = text.string
        text.insertText(" undo-redo probe", replacementRange: text.selectedRange())
        let edited = text.string
        try require(edited != before, "Undo and redo checks begin with an actual editor mutation")
        try await Task.sleep(nanoseconds: 50_000_000)
        NSApp.sendEvent(try menuKeyEvent(code: 6, modifiers: .command))
        try require(text.string == before, "Native Command Z undoes the editor mutation")
        NSApp.sendEvent(try menuKeyEvent(code: 6, modifiers: [.command, .shift]))
        try require(text.string == edited, "Native Command Shift Z redoes the mutation after Undo")
    }

    private static func verifyEditorShortcuts(_ controller: NoteWindowController) async throws {
        controller.show()
        guard let window = controller.window else { throw VerificationFailure("Missing note window") }
        let editor = controller.editor
        let text = editor.textView
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let start = text.selectedRange().location
        text.insertText("键盘格式", replacementRange: text.selectedRange())
        let selection = NSRange(location: start, length: 4)
        text.setSelectedRange(selection)
        try sendKey(to: window, characters: "T", code: 17, modifiers: [.command, .shift])
        try require(editor.formatState.kind == .title, "Native Command Shift T applies the title style")
        for (characters, code, kind) in [("&", UInt16(26), BlockKind.bullet), ("*", 28, .dashed), ("(", 25, .numbered)] {
            try sendKey(to: window, characters: characters, code: code, modifiers: [.command, .shift])
            try require(editor.formatState.kind == kind, "Shifted numeric key applies \(kind.rawValue) through native event routing")
        }
        try sendKey(to: window, characters: "L", code: 37, modifiers: [.command, .shift])
        try sendKey(to: window, characters: "U", code: 32, modifiers: [.command, .shift])
        try require(try editor.snapshot().last?.isChecked == true, "Native checklist completion shortcut toggles the selected item once")
        try sendKey(to: window, characters: "B", code: 11, modifiers: [.command, .shift])
        try sendKey(to: window, characters: "b", code: 11, modifiers: .command)
        try sendKey(to: window, characters: "X", code: 7, modifiers: [.command, .shift])
        try require(editor.formatState.bold && editor.formatState.strikethrough,
                    "Native bold and strikethrough shortcuts format the selected text")
        try sendKey(to: window, characters: "\\", code: 42, modifiers: .command)
        try require(!editor.formatState.bold && !editor.formatState.strikethrough && editor.formatState.kind == .body && text.selectedRange() == selection,
                    "Command backslash clears formatting and preserves the selected text")
        let beforeSize = (text.attributedString().attribute(.font, at: start, effectiveRange: nil) as! NSFont).pointSize
        try sendKey(to: window, characters: "+", code: 24, modifiers: [.command, .shift])
        let larger = (text.attributedString().attribute(.font, at: start, effectiveRange: nil) as! NSFont).pointSize
        try require(larger > beforeSize, "Command plus increases font size through the native font menu")
        try sendKey(to: window, characters: "-", code: 27, modifiers: .command)
        try require((text.attributedString().attribute(.font, at: start, effectiveRange: nil) as! NSFont).pointSize == beforeSize,
                    "Command minus restores the previous font size")
        try sendKey(to: window, characters: "t", code: 17, modifiers: [.command, .option])
        try require(controller.isFormattingVisible, "Command Option T opens the formatting palette through the native menu")
        if let palette = controller.formattingWindow {
            try sendKey(to: palette, characters: "\u{1b}", code: 53, modifiers: [])
        }
        try require(!controller.isFormattingVisible && window.isVisible,
                    "A native Escape key dismisses the palette and keeps the note open")
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertNewline(nil)
        editor.clearFormatting()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private static func verifyFocusedEditing(_ delegate: AppDelegate, controller: NoteWindowController) async throws {
        guard let store = delegate.store else { throw VerificationFailure("Missing workflow store") }
        let editor = controller.editor
        let text = editor.textView
        controller.show()
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        try require(delegate.flushSave(), "Pending presentation edits are saved before input testing")
        let committed = try store.load()
        text.insertText("即时记录", replacementRange: text.selectedRange())
        try await Task.sleep(nanoseconds: 50_000_000)
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(text.hasMarkedText() && text.string.hasSuffix("即时记录ni"),
                    "Idle autosave leaves marked input and its caret intact")
        try require(try store.load().blocks.map(\.text) == committed.blocks.map(\.text),
                    "An older autosave timer never stores unconfirmed input")
        text.insertText("你好", replacementRange: text.markedRange())
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(!text.hasMarkedText() && store.load().blocks.last?.text == "即时记录你好",
                    "Confirmed Unicode input is saved after the typing pause")

        text.insertText("。", replacementRange: text.selectedRange())
        text.setMarkedText("qu", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 450_000_000)
        text.insertText("", replacementRange: text.markedRange())
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(!text.hasMarkedText() && store.load().blocks.last?.text == "即时记录你好。",
                    "Cancelling marked input saves only the committed text")

        text.setMarkedText("完成", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.hide()
        try require(!text.hasMarkedText() && store.load().blocks.last?.text == "即时记录你好。完成",
                    "Hiding explicitly commits the current input before saving")
        controller.show()
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertText(" ABCD", replacementRange: text.selectedRange())
        let whole = (text.string as NSString).range(of: "ABCD")
        text.setSelectedRange(whole)
        editor.toggleBold()
        editor.setHighlight(.orange)
        editor.setLink(URL(string: "https://example.com/selection")!)
        try await Task.sleep(nanoseconds: 50_000_000)
        text.setSelectedRange(NSRange(location: whole.location + 1, length: 2))
        controller.toggleFormatting(nil)
        guard let root = controller.formattingWindow?.contentView,
              let clear = findTitledButton(in: root, title: "清除格式") else {
            throw VerificationFailure("Missing clear-formatting control")
        }
        clear.performClick(nil)
        let attributed = text.attributedString()
        for offset in [0, 3] {
            let attributes = attributed.attributes(at: whole.location + offset, effectiveRange: nil)
            try require(attributes[.link] != nil && attributes[.backgroundColor] != nil &&
                        (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                        "Clearing a selection preserves formatting outside it (\(offset))")
        }
        let cleared = attributed.attributes(at: whole.location + 1, effectiveRange: nil)
        try require(cleared[.link] == nil && cleared[.backgroundColor] == nil &&
                    (cleared[.font] as? NSFont).map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
                    "The palette clears only the selected inline formatting")
        try await Task.sleep(nanoseconds: 50_000_000)
        text.undoManager?.undo()
        try require(text.attributedString().attribute(.link, at: whole.location + 1, effectiveRange: nil) != nil,
                    "Undo restores formatting cleared from a partial selection")
        text.setSelectedRange(whole)
        editor.clearFormatting()

        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertNewline(nil)
        editor.apply(.checklist)
        editor.indent()
        let before = try editor.snapshot()
        try await Task.sleep(nanoseconds: 50_000_000)
        text.deleteBackward(nil)
        let outdented = try editor.snapshot()
        try require(outdented.map(\.id) == before.map(\.id) && outdented.last?.kind == .checklist && outdented.last?.indentLevel == 0,
                    "Backspace on an empty nested item outdents without merging paragraphs")
        text.deleteBackward(nil)
        let exited = try editor.snapshot()
        try require(exited.map(\.id) == before.map(\.id) && exited.last?.kind == .body &&
                    exited.dropLast().map(\.text) == before.dropLast().map(\.text),
                    "Backspace exits an empty outer list and preserves the preceding note")
        try require(delegate.flushSave(), "Focused editing changes are saved by the production coordinator")
    }

    private static func verifyEnhancedEditing(_ delegate: AppDelegate, controller: NoteWindowController, folder: URL) async throws {
        controller.show()
        let text = controller.editor.textView
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertText("重点想法", replacementRange: text.selectedRange())
        let range = (text.string as NSString).range(of: "重点")
        text.setSelectedRange(range)
        controller.toggleFormatting(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        guard let root = controller.formattingWindow?.contentView,
              let strike = findButton(in: root, toolTip: EditorShortcuts.Command.strikethrough.tooltip) else { throw VerificationFailure("Missing strike control") }
        strike.performClick(nil)
        controller.toggleFormatting(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        guard let mint = findButton(in: root, toolTip: "薄荷绿高亮") else { throw VerificationFailure("Missing highlight control") }
        mint.performClick(nil)
        controller.editor.setLink(URL(string: "https://example.com/idea")!)
        try await verifyLinkInput(controller)
        try verifyInlineFormats(controller)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertNewline(nil)
        text.insertText("下一段", replacementRange: text.selectedRange())
        guard let format = NSApp.mainMenu?.items.first(where: { $0.title == "格式" })?.submenu,
              let subtitle = format.items.firstIndex(where: { $0.title == "副标题" }) else {
            throw VerificationFailure("Missing native paragraph style menu")
        }
        format.performActionForItem(at: subtitle)
        try require(controller.editor.formatState.kind == .subheading, "Native format menu applies the Notes subheading style")
        text.insertNewline(nil)
        text.insertText("- ", replacementRange: text.selectedRange())
        text.insertText("拆解事项", replacementRange: text.selectedRange())
        text.insertTab(nil)
        text.insertLineBreak(nil)
        text.insertText("延续同一项", replacementRange: text.selectedRange())
        let list = try controller.editor.snapshot().last!
        print("INFO: Native list state = \(list.kind.rawValue), indent \(list.indentLevel), text \(String(reflecting: list.text))")
        try require(list.kind == .dashed && list.indentLevel == 1 && list.text == "拆解事项\u{2028}延续同一项",
                    "Typing a list prefix, Tab and Shift Return produces one indented list block")
        text.insertNewline(nil)
        text.insertText("下一步", replacementRange: text.selectedRange())
        text.insertNewline(nil)
        text.insertNewline(nil)
        try require(controller.editor.formatState.kind == .dashed && controller.editor.formatState.indentLevel == 0,
                    "Return on an empty nested item reduces indentation")
        text.insertNewline(nil)
        try require(controller.editor.formatState.kind == .body, "Return on an empty outer item exits the list")
        controller.editor.apply(.quote)
        text.insertText("把注意力留给文字。引用的竖线会随段落换行延伸，所有文本样式都保存在这一页。", replacementRange: text.selectedRange())
        text.insertNewline(nil)
        controller.editor.apply(.code)
        text.insertText("let idea = \"keep writing\"", replacementRange: text.selectedRange())
        try require(delegate.flushSave(), "Enhanced text formats commit through the production save coordinator")
        try capture(controller, folder: folder, suffix: "text-formats")
    }

    private static func verifyInlineFormats(_ controller: NoteWindowController) throws {
        let range = (controller.editor.textView.string as NSString).range(of: "重点")
        guard range.location != NSNotFound else { throw VerificationFailure("Missing enhanced format text") }
        let attributes = controller.editor.textView.attributedString().attributes(at: range.location, effectiveRange: nil)
        try require((attributes[.strikethroughStyle] as? Int ?? 0) != 0 && attributes[.backgroundColor] != nil && attributes[.link] != nil,
                    "Strikethrough, highlight and link render on the selected Unicode text")
    }

    private static func verifyLinkInput(_ controller: NoteWindowController) async throws {
        let selection = controller.editor.textView.selectedRange()
        let before = controller.editor.textView.attributedString().attribute(.link, at: selection.location, effectiveRange: nil) as? URL
        guard let window = controller.window else { throw VerificationFailure("Missing link owner window") }
        try sendKey(to: window, characters: "k", code: 40, modifiers: .command)
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView,
              let field = findLinkField(in: content), let done = findTitledButton(in: content, title: "完成"),
              let cancel = findTitledButton(in: content, title: "取消") else { throw VerificationFailure("Link editor sheet must expose its controls") }
        field.stringValue = "https://["
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try require(!done.isEnabled, "Invalid link input disables completion instead of deleting the existing link")
        cancel.performClick(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = controller.editor.textView.attributedString().attribute(.link, at: selection.location, effectiveRange: nil) as? URL
        try require(after == before && controller.editor.textView.selectedRange() == selection, "Cancelling link editing preserves the link and selection")
    }

    private static func findLinkField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "https://example.com" { return field }
        for child in view.subviews { if let field = findLinkField(in: child) { return field } }
        return nil
    }

    private static func findTitledButton(in view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let button = findTitledButton(in: child, title: title) { return button } }
        return nil
    }

    private static func verifyLanguageSwitch(_ controller: NoteWindowController, settings: SettingsWindowController, folder: URL) async throws {
        let preferences = AppPreferences.shared
        let originalLanguage = preferences.language
        defer { preferences.language = originalLanguage }
        let text = controller.editor.textView
        let before = NSAttributedString(attributedString: text.attributedString())
        let selection = text.selectedRange()
        let originalEditor = text
        preferences.language = .english
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(controller.window?.title == "Quick Note" && settings.window?.title == "Quick Note Settings",
                    "Existing note and Settings windows switch to English without restarting")
        try require(controller.editor.textView === originalEditor && text.attributedString().isEqual(to: before)
                    && text.selectedRange() == selection, "Language switching preserves the editor, rich text and selection")
        try require(NSApp.mainMenu?.items.contains(where: { $0.title == "Format" }) == true,
                    "Native menus immediately follow the selected app language")
        guard let formatRoot = controller.formattingWindow?.contentView,
              findButton(in: formatRoot, toolTip: "Bold (⌘B)") != nil,
              findTitledButton(in: formatRoot, title: "Clear Formatting") != nil else {
            throw VerificationFailure("Existing format controls must switch to English")
        }
        settings.selectPage(.general)
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(findAccessible("settings.language", in: settings.window!) != nil,
                    "Settings expose the language choice with a stable accessibility identifier")
        try captureWindow(settings.window, folder: folder, suffix: "settings-english")
        try captureToolbarWidths(controller, folder: folder, language: "en")
        // Change the language while the existing input client has an uncommitted IME draft.
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        let marked = text.markedRange()
        let draft = NSAttributedString(attributedString: text.attributedString())
        preferences.language = .simplifiedChinese
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(text.hasMarkedText() && text.markedRange() == marked && text.attributedString().isEqual(to: draft),
                    "Language switching preserves an active IME composition without committing it")
        text.insertText("", replacementRange: marked)
        text.setSelectedRange(selection)
        try require(controller.window?.title == "随记" && settings.window?.title == "随记设置"
                    && findButton(in: formatRoot, toolTip: "粗体（⌘B）") != nil,
                    "Existing windows and formatting tooltips switch back to Simplified Chinese")
        try captureToolbarWidths(controller, folder: folder, language: "zh-Hans")
    }


    private static func verifySettingsSections(_ settings: SettingsWindowController, folder: URL) async throws {
        guard let window = settings.window else { throw VerificationFailure("Missing Settings window") }
        let preferences = AppPreferences.shared
        let originalAppearance = preferences.appearance
        defer { preferences.appearance = originalAppearance; preferences.language = .simplifiedChinese }
        settings.selectPage(.general)
        settings.update(shortcut: .controlOptionN, problem: nil)
        settings.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        try pressAccessible("settings.language.zh-Hans", in: window)
        try sendKey(to: window, characters: "\u{f703}", code: 124, modifiers: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(preferences.language == .english && findAccessible("settings.language.en", in: window) != nil,
                    "Right Arrow selects English through the focused native language segment")
        if CommandLine.arguments.contains("--settings-only"), !CommandLine.arguments.contains("--read-back") {
            try require(window.title == "Quick Note Settings", "English settings title updates before failure injection")
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let languageGroup = findAccessible("settings.language", in: window)
            try require(languageGroup?.responds(to: labelSelector) == true
                        && languageGroup?.perform(labelSelector)?.takeUnretainedValue() as? String == "Interface Language",
                        "Visible language row exposes its English accessibility label before failure injection")
            let mode = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_MODE"] ?? "normal"
            guard ["normal", "fail", "hold"].contains(mode) else { throw VerificationFailure("Unknown localization failure mode") }
            try captureWindow(window, folder: folder, suffix: "localization-english-checkpoint")
            let progress: [String: Any] = ["stage": "english-visible", "language": "en", "pid": Int(getpid()), "mode": mode]
            let progressPath = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_PROGRESS"]
            if let progressPath {
                guard let directory = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_DIRECTORY"],
                      directory.hasSuffix("/fixture-data"),
                      progressPath == String(directory.dropLast("/fixture-data".count)) + "/localization-progress.json" else {
                    throw VerificationFailure("Localization progress must remain in the native output directory")
                }
            }
            let progressURL = progressPath.map { URL(fileURLWithPath: $0) }
                ?? folder.appendingPathComponent("localization-progress.json")
            try JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys]).write(to: progressURL, options: .atomic)
            if mode == "fail" { throw VerificationFailure("Injected failure after the native English language switch") }
            if mode == "hold" {
                while true { try await Task.sleep(nanoseconds: 300_000_000_000) }
            }
        }
        try sendKey(to: window, characters: "\u{f702}", code: 123, modifiers: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(preferences.language == .simplifiedChinese,
                    "Left Arrow selects Simplified Chinese and keeps the language segment focused")
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try require(!version.isEmpty, "Packaged app provides its release version")
        let versionValue = build.isEmpty ? version : "\(version) (\(build))"
        for language in AppLanguage.allCases {
            settings.selectPage(.general)
            try await Task.sleep(nanoseconds: 100_000_000)
            try pressAccessible("settings.language.\(language.rawValue)", in: window)
            try require(preferences.language == language, "Native language segment changes the app language: \(language.rawValue)")
            try await Task.sleep(nanoseconds: 100_000_000)
            let versionLabel = language == .english ? "Version \(versionValue)" : "版本 \(versionValue)"
            let versionElement = findAccessible("app.version", in: window)
            let observedVersion = ["accessibilityValue", "accessibilityLabel"].compactMap { attribute -> String? in
                let selector = NSSelectorFromString(attribute)
                guard versionElement?.responds(to: selector) == true,
                      let value = versionElement?.perform(selector)?.takeUnretainedValue() as? String,
                      !value.isEmpty else { return nil }
                return value
            }.first
            print("DIAGNOSTIC: settings-version language=\(language.rawValue) expected=\(versionLabel) observed=\(observedVersion ?? "<missing>")")
            try require(observedVersion == versionLabel,
                        "Settings version matches bundle metadata and updates immediately in \(language.rawValue); expected=\(versionLabel), observed=\(observedVersion ?? "<missing>")")
            for page in SettingsPage.allCases {
                preferences.appearance = "light"
                try pressAccessible("settings.page.\(page.rawValue)", in: window)
                try await Task.sleep(nanoseconds: 100_000_000)
                let expected: [SettingsPage: [String]] = [.general: ["settings.language", "settings.launchAtLogin", "settings.shortcut.recorder"],
                    .appearance: ["settings.floatingWindow", "settings.appearance"],
                    .editing: ["settings.spellChecking", "settings.automaticLinks"], .storage: ["settings.databasePath"]]
                for identifier in expected[page]! {
                    try require(findAccessible(identifier, in: window) != nil,
                                "Native \(page.rawValue) page exposes \(identifier) in \(language.rawValue)")
                }
                try captureWindow(window, folder: folder, suffix: "settings-\(page.rawValue)-\(language.rawValue)-light")
                if page == .general {
                    preferences.appearance = "dark"
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try captureWindow(window, folder: folder, suffix: "settings-general-\(language.rawValue)-dark")
                }
            }
        }
        settings.selectPage(.general)
        settings.show()
    }

    private static func recorder(in root: NSView) -> RecorderButton? {
        if let value = root as? RecorderButton { return value }
        return root.subviews.lazy.compactMap { recorder(in: $0) }.first
    }

    private static func postShortcut(_ value: KeyboardShortcut) {
        var flags: CGEventFlags = []
        if value.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if value.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if value.modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if value.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(value.keyCode), keyDown: down)
            event?.flags = down ? flags : []
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func verifyCustomShortcut(_ delegate: AppDelegate, controller: NoteWindowController,
                                            settings: SettingsWindowController, folder: URL,
                                            permitDesktopInterference: Bool = false) async throws {
        guard let window = settings.window else { throw VerificationFailure("Missing Settings window") }
        settings.selectPage(.general)
        settings.update(shortcut: delegate.activeShortcut, problem: nil)
        settings.onRecordingChange = { delegate.setShortcutRecording($0) }
        settings.onChooseShortcut = { value in
            do { try delegate.registerShortcut(value); return nil }
            catch { return localizedError(error, language: AppPreferences.shared.language) }
        }
        settings.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let recorder = recorder(in: window.contentView!) else { throw VerificationFailure("Missing native shortcut recorder") }
        let text = controller.editor.textView
        let before = NSAttributedString(attributedString: text.attributedString())
        let selection = text.selectedRange()
        let persisted = AppPreferences.shared.shortcut
        let count = delegate.workflowShortcutTriggerCount
        recorder.performClick(nil)
        try require(recorder.isRecording && delegate.isShortcutRecording,
                    "Clicking the native recorder pauses the existing global hot key")
        try captureWindow(window, folder: folder, suffix: "settings-shortcut-recording")
        if CGPreflightPostEventAccess(), case .keyboard(let prior) = persisted {
            postShortcut(prior)
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(!recorder.isRecording && delegate.workflowShortcutTriggerCount == count,
                        "Recording the existing physical shortcut does not trigger its global callback")
        } else { recorder.endRecording(); print("SKIP: Existing physical hot-key recording needs event posting permission") }
        recorder.performClick(nil)
        try sendKey(to: window, characters: "a", code: 0, modifiers: [])
        try require(recorder.isRecording && AppPreferences.shared.shortcut == persisted,
                    "An unmodified key is rejected without changing the saved shortcut")
        try sendKey(to: window, characters: "\u{1b}", code: 53, modifiers: [])
        try require(!recorder.isRecording && !delegate.isShortcutRecording && delegate.activeShortcut == persisted,
                    "Escape cancels recording and restores the physical global shortcut")
        if !permitDesktopInterference || (window.isKeyWindow && NSApp.isActive) {
            recorder.performClick(nil)
            let focusDestination = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 100),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
            focusDestination.isReleasedWhenClosed = false
            focusDestination.title = "Isolated recorder focus destination"
            defer { focusDestination.close() }
            focusDestination.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            print("DIAGNOSTIC: recorder-focus-loss recorder=\(recorder.isRecording) paused=\(delegate.isShortcutRecording) " +
                  "active=\(delegate.activeShortcut?.title ?? "none") settingsKey=\(window.isKeyWindow) " +
                  "destinationKey=\(focusDestination.isKeyWindow) appActive=\(NSApp.isActive)")
            if permitDesktopInterference && !focusDestination.isKeyWindow {
                recorder.endRecording()
                print("INCONCLUSIVE: Shared desktop focus changed during the recorder window-switch setup")
            } else {
                try require(focusDestination.isKeyWindow && !window.isKeyWindow && !recorder.isRecording &&
                            !delegate.isShortcutRecording && delegate.activeShortcut == persisted,
                            "Window focus loss cancels recording and restores the global shortcut")
            }
            focusDestination.close()
            settings.show()
        } else { print("INCONCLUSIVE: Recorder focus-loss setup needs the Settings window to be key and the app active") }
        let occupied = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘8"))
        let owner = GlobalShortcutController()
        defer { owner.unregister() }
        try owner.register(occupied)
        recorder.performClick(nil)
        try sendKey(to: window, characters: "8", code: UInt16(kVK_ANSI_8), modifiers: [.control, .option, .shift, .command])
        try require(settings.selectedShortcut == persisted && delegate.activeShortcut == persisted &&
                    AppPreferences.shared.shortcut == persisted && settings.shortcutProblem != nil,
                    "An actual Carbon conflict leaves the old shortcut selected, registered and persisted")
        try captureWindow(window, folder: folder, suffix: "settings-shortcut-conflict")
        owner.unregister()
        recorder.performClick(nil)
        try sendKey(to: window, characters: "9", code: UInt16(kVK_ANSI_9), modifiers: [.control, .option, .shift, .command])
        let custom = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘9"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(settings.selectedShortcut == custom && delegate.activeShortcut == custom &&
                    AppPreferences.shared.shortcut == custom && recorder.title == custom.title && settings.shortcutProblem == nil,
                    "The native recorder commits the custom numeric combination after successful Carbon registration")
        try require(text.attributedString().isEqual(to: before) && text.selectedRange() == selection,
                    "Recording, cancellation and conflict leave the note's rich text and selection unchanged")
        try captureWindow(window, folder: folder, suffix: "settings-shortcut-custom")
        if CGPreflightPostEventAccess() {
            if permitDesktopInterference, case .keyboard(let value) = custom {
                // Verify the actual registered callback independently of focus arbitration.
                controller.window?.orderOut(nil)
                let baseline = delegate.workflowShortcutTriggerCount
                postShortcut(value)
                try await Task.sleep(nanoseconds: 250_000_000)
                try require(delegate.workflowShortcutTriggerCount == baseline + 1 && controller.window?.isVisible == true,
                            "The recorded numeric shortcut opens the note through the actual Carbon callback")
                if controller.window?.isKeyWindow == true && NSApp.isActive {
                    postShortcut(value)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try require(delegate.workflowShortcutTriggerCount == baseline + 2 && controller.window?.isVisible == false,
                                "The recorded numeric shortcut hides the focused note through Carbon")
                } else { print("INCONCLUSIVE: Shared desktop focus prevents the repeat-hide precondition") }
            } else { try await verifyShortcut(delegate, controller: controller, shortcut: custom) }
        } else { print("SKIP: Custom Carbon callback needs event posting permission") }
    }

    private static func captureToolbarWidths(_ controller: NoteWindowController, folder: URL, language: String) throws {
        guard let window = controller.window else { throw VerificationFailure("Missing note window") }
        let originalFrame = window.frame
        let originalText = NSAttributedString(attributedString: controller.editor.textView.attributedString())
        let originalSelection = controller.editor.textView.selectedRange()
        defer {
            controller.dismissFormatting()
            window.setFrame(originalFrame, display: true)
        }
        for (name, size) in [("default", NSSize(width: 660, height: 620)), ("narrow", NSSize(width: 420, height: 360))] {
            controller.dismissFormatting()
            window.setContentSize(size)
            controller.show()
            controller.toggleFormatting(nil)
            try captureWindow(controller.formattingWindow, folder: folder, suffix: "toolbar-\(language)-\(name)") { appearance in
                try verifyToolbarSymbolLayout(controller, context: "\(language)/\(name)/\(appearance)")
            }
            try require(controller.editor.textView.attributedString().isEqual(to: originalText)
                        && controller.editor.textView.selectedRange() == originalSelection,
                        "Toolbar layout verification preserves rich text and selection: \(language)/\(name)")
        }
    }

    private static func verifyToolbarSymbolLayout(_ controller: NoteWindowController, context: String) throws {
        guard let root = controller.formattingWindow?.contentView else { throw VerificationFailure("Missing toolbar") }
        root.layoutSubtreeIfNeeded()
        let symbols = descendantViews(in: root).compactMap { $0 as? NSButton }
            .filter { $0.image != nil && !($0 is NSPopUpButton) }
        try require(symbols.count == 14 && symbols.allSatisfy { $0.imagePosition == .imageOnly && $0.title.isEmpty },
                    "Formatting controls display symbols without overlapping native placeholder text: \(context)")
        try require(symbols.allSatisfy { $0.toolTip?.isEmpty == false && $0.accessibilityLabel()?.isEmpty == false },
                    "Icon-only toolbar controls retain readable tooltips and accessibility labels: \(context)")
        let frames = symbols.map { $0.convert($0.bounds, to: root) }
        try require(frames.allSatisfy { root.bounds.contains($0) } && frames.enumerated().allSatisfy { index, frame in
            frames.dropFirst(index + 1).allSatisfy { !frame.insetBy(dx: 0.5, dy: 0.5).intersects($0.insetBy(dx: 0.5, dy: 0.5)) }
        }, "Toolbar icon controls fit the palette without intersecting each other: \(context)")
    }

    private static func verifyPreferences(_ controller: NoteWindowController, folder: URL) throws {
        let suite = "QuickNote.Verification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.spellChecking = false
        preferences.automaticLinks = false
        preferences.floatingWindow = false
        preferences.appearance = "dark"
        controller.applyPreferences(preferences)
        try require(!controller.editor.textView.isContinuousSpellCheckingEnabled && !controller.editor.textView.isAutomaticLinkDetectionEnabled && controller.window?.level == .normal,
                    "Editing preferences apply to the real native editor and window")
        let reloaded = AppPreferences(defaults: defaults)
        try require(!reloaded.spellChecking && !reloaded.automaticLinks && !reloaded.floatingWindow && reloaded.appearance == "dark",
                    "Editing and appearance preferences survive a preferences reload")
        controller.applyPreferences(AppPreferences.shared)
    }

    private static func findButton(in view: NSView, toolTip: String) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == toolTip { return button }
        for child in view.subviews {
            if let button = findButton(in: child, toolTip: toolTip) { return button }
        }
        return nil
    }

    private static func findStylePopup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for child in view.subviews {
            if let popup = findStylePopup(in: child) { return popup }
        }
        return nil
    }

    private static func findMorePopup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.toolTip == "字体、文字颜色与查找" { return popup }
        for child in view.subviews { if let popup = findMorePopup(in: child) { return popup } }
        return nil
    }

    private static func verifyChecklistClick(_ controller: NoteWindowController) throws {
        let text = controller.editor.textView
        let caret = text.selectedRange()
        guard let layout = text.layoutManager, let container = text.textContainer, let window = text.window else {
            throw VerificationFailure("Native checkbox requires a laid-out editor")
        }
        layout.ensureLayout(for: container)
        let location = (text.string as NSString).range(of: "准备下一步").location
        let glyph = layout.glyphIndexForCharacter(at: location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = NSPoint(x: text.textContainerOrigin.x + 12, y: text.textContainerOrigin.y + line.minY + 12)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: text.convert(point, to: nil),
                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw VerificationFailure("Unable to create checkbox click")
        }
        text.mouseDown(with: event)
        let afterClick = try controller.editor.snapshot()
        try require(afterClick.indices.contains(2) && !afterClick[2].isChecked, "Clicking the native checklist marker changes its checked state")
        text.undoManager?.undo()
        let afterUndo = try controller.editor.snapshot()
        try require(afterUndo.indices.contains(2) && afterUndo[2].isChecked, "Checklist click supports Undo")
        text.setSelectedRange(caret)
    }

    private static func verifyFnShortcut(_ delegate: AppDelegate, controller: NoteWindowController) async throws {
        guard AXIsProcessTrusted() else {
            do {
                try delegate.registerShortcut(.fnQ, persist: false)
                throw VerificationFailure("Fn Q must not register without accessibility authorization")
            } catch is GlobalShortcutError {
                try require(delegate.activeShortcut == .controlOptionN, "Missing Fn Q permission preserves the existing shortcut")
            }
            print("SKIP: Fn Q tap injection requires existing accessibility authorization; no permission prompt was requested")
            return
        }
        try delegate.registerShortcut(.fnQ, persist: false)
        let original = controller.editor.textView.string
        controller.show()
        // The preceding physical hide returns focus asynchronously to the prior app.
        // Settle that return before preparing the focused-note Fn repeat scenario.
        try await Task.sleep(nanoseconds: 150_000_000)
        controller.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(controller.window?.isKeyWindow == true && NSApp.isActive,
                    "Fn repeat scenario starts with the note editor in the foreground")
        for repeatIndex in 0...2 {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true)
            event?.flags = .maskSecondaryFn
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: repeatIndex == 0 ? 0 : 1)
            event?.post(tap: .cghidEventTap)
        }
        let release = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false)
        release?.flags = []
        release?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(controller.window?.isVisible == false, "Fn Q event tap triggers once despite key repeats")
        try require(controller.editor.textView.string == original, "Fn Q does not type q into the editor")
        try delegate.registerShortcut(.controlOptionN, persist: false)
        controller.show()
    }

    private static func verifyShortcut(_ delegate: AppDelegate, controller: NoteWindowController,
                                       shortcut: GlobalShortcut = .controlOptionN) async throws {
        var callbackBaseline = delegate.workflowShortcutTriggerCount
        guard case .keyboard(let keyboard) = shortcut else { throw VerificationFailure("Expected a Carbon shortcut") }
        func press() { postShortcut(keyboard) }
        func isEditorFocused() -> Bool {
            controller.window?.isVisible == true && controller.window?.isKeyWindow == true &&
                NSApp.isActive && controller.window?.firstResponder === controller.editor.textView
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            try Task.checkCancellation()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func waitForCallback(after baseline: Int, post: String) async throws {
            try await waitUntil { delegate.workflowShortcutTriggerCount > baseline }
            guard delegate.workflowShortcutTriggerCount > baseline else {
                throw VerificationFailure("No shortcut callback after \(post) physical post within 2 seconds " +
                                          "(onTrigger count \(baseline) -> \(delegate.workflowShortcutTriggerCount))")
            }
        }
        func diagnose(_ stage: String) {
            let window = controller.window
            let responder = window?.firstResponder
            let responderType = responder.map { String(reflecting: type(of: $0)) } ?? "none"
            print("DIAGNOSTIC: physical-shortcut stage=\(stage) " +
                  "visible=\(window?.isVisible == true) key=\(window?.isKeyWindow == true) " +
                  "appActive=\(NSApp.isActive) firstResponderType=\(responderType) " +
                  "editorOwnsFirstResponder=\(responder === controller.editor.textView) " +
                  "formattingVisible=\(controller.isFormattingVisible) " +
                  "formattingKey=\(controller.formattingWindow?.isKeyWindow == true) " +
                  "observer=onTrigger callbackSequence=\(delegate.workflowShortcutTriggerCount) " +
                  "callbackBaseline=\(callbackBaseline) callbackDelta=\(delegate.workflowShortcutTriggerCount - callbackBaseline) " +
                  "uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        do {
            controller.hide()
            callbackBaseline = delegate.workflowShortcutTriggerCount
            diagnose("before-first")
            press()
            diagnose("after-first-post")
            try await waitForCallback(after: callbackBaseline, post: "first")
            diagnose("after-first-callback")
            try await waitUntil { isEditorFocused() }
            try require(controller.window?.isVisible == true, "Posted global shortcut opens the note through Carbon callback")
            try require(isEditorFocused(), "Posted global shortcut activates the note and focuses its native editor")
            callbackBaseline = delegate.workflowShortcutTriggerCount
            diagnose("before-repeat")
            press()
            diagnose("after-repeat-post")
            try await waitForCallback(after: callbackBaseline, post: "second")
            diagnose("after-repeat-callback")
            try await waitUntil { controller.window?.isVisible == false }
            try require(controller.window?.isVisible == false, "Repeated global shortcut hides the focused note")
            controller.show()
        } catch {
            diagnose("failure")
            throw error
        }
    }

    private static func capture(_ controller: NoteWindowController, folder: URL, suffix: String,
                                validate: ((String) throws -> Void)? = nil) throws {
        try captureWindow(controller.window, folder: folder, suffix: suffix, validate: validate)
    }

    private static func captureWindow(_ window: NSWindow?, folder: URL, suffix: String,
                                      validate: ((String) throws -> Void)? = nil) throws {
        guard let content = window?.contentView else { return }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window?.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try validate?(name)
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw VerificationFailure("Unable to capture native window")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw VerificationFailure("Unable to encode native window")
            }
            try png.write(to: folder.appendingPathComponent("window-\(suffix)-\(name).png"))
        }
        window?.appearance = nil
    }
}
