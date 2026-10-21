import AppKit
import Carbon
import QuickNoteCore
import XCTest
@testable import QuickNote

@MainActor
final class SettingsTests: XCTestCase {
    func testPermissionFailurePreservesWorkingShortcutAndExplainsFnRequirements() {
        let model = SettingsModel(databaseURL: URL(fileURLWithPath: "/tmp/notes.sqlite"))
        model.update(shortcut: .controlOptionN, problem: nil)
        model.onChooseShortcut = { _ in "Fn Q 需要辅助功能权限。" }
        model.chooseShortcut(.fnQ)
        XCTAssertEqual(model.selectedShortcut, .controlOptionN)
        XCTAssertEqual(model.problem, "Fn Q 需要辅助功能权限。")
        XCTAssertTrue(model.showsFnDetails)
    }

    func testSuccessfulShortcutChangeClearsPreviousFailure() {
        let model = SettingsModel(databaseURL: URL(fileURLWithPath: "/tmp/notes.sqlite"))
        model.update(shortcut: .controlOptionN, problem: "Fn Q 需要辅助功能权限。")
        var requestedPreset: GlobalShortcut?
        model.onChooseShortcut = { requestedPreset = $0; return nil }
        let custom = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥9"))
        model.chooseShortcut(custom)
        XCTAssertEqual(requestedPreset, custom)
        XCTAssertEqual(model.selectedShortcut, custom)
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.showsFnDetails)
    }

    func testStartupFallbackShowsPermissionHelpWithoutSelectingUnavailableFnQ() {
        let model = SettingsModel(databaseURL: URL(fileURLWithPath: "/tmp/notes.sqlite"))
        model.update(shortcut: .controlOptionN, problem: "Fn Q 无法启用，请允许辅助功能权限。")
        XCTAssertEqual(model.selectedShortcut, .controlOptionN)
        XCTAssertTrue(model.showsFnDetails)
        model.update(shortcut: .fnQ, problem: nil)
        XCTAssertTrue(model.showsFnDetails)
        XCTAssertNil(model.problem)
    }

    private func preferences() -> (AppPreferences, UserDefaults, String) {
        let name = "QuickNote.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (AppPreferences(defaults: defaults, preferredLanguages: ["en"]), defaults, name)
    }

    private func event(code: UInt16, text: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: text,
                         charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    func testCapturedCustomCombinationPersistsAndRestoresOnRestart() throws {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let captured = try XCTUnwrap(KeyboardShortcut.capture(event(code: 25, text: "9", flags: [.control, .option, .shift, .command])))
        XCTAssertEqual(captured.keyCode, UInt32(kVK_ANSI_9))
        XCTAssertEqual(captured.modifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(captured.label, "⌃⌥⇧⌘9")
        let controller = GlobalShortcutController()
        defer { controller.unregister() }
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        try app.registerShortcut(.keyboard(captured))
        XCTAssertEqual(app.activeShortcut, .keyboard(captured))
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut, .keyboard(captured))
    }

    func testUnmodifiedAndShiftOnlyKeysAreRejectedWithoutSaving() throws {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(KeyboardShortcut.capture(event(code: 0, text: "a")))
        XCTAssertNil(KeyboardShortcut.capture(event(code: 0, text: "A", flags: [.shift])))
        let controller = GlobalShortcutController()
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        XCTAssertThrowsError(try app.registerShortcut(.keyboard(.init(keyCode: 0, modifiers: UInt32(shiftKey), label: "⇧A"))))
        XCTAssertNil(defaults.data(forKey: "globalShortcut"))
        XCTAssertEqual(preferences.shortcut, .controlOptionN)
    }

    func testUnsupportedFnCombinationsDoNotDropFnButNavigationAndFunctionKeysRemainRecordable() throws {
        XCTAssertNil(KeyboardShortcut.capture(event(code: UInt16(kVK_ANSI_Q), text: "q", flags: [.function, .command])))
        XCTAssertNil(KeyboardShortcut.capture(event(code: UInt16(kVK_ANSI_9), text: "9", flags: [.function, .control, .option])))
        let arrow = try XCTUnwrap(KeyboardShortcut.capture(event(code: UInt16(kVK_RightArrow), text: "\u{f703}", flags: [.function, .command])))
        XCTAssertEqual(arrow.keyCode, UInt32(kVK_RightArrow))
        XCTAssertEqual(arrow.label, "⌘→")
        let function = try XCTUnwrap(KeyboardShortcut.capture(event(code: UInt16(kVK_F18), text: "\u{f715}", flags: [.function, .control, .option])))
        XCTAssertEqual(function.keyCode, UInt32(kVK_F18))
        XCTAssertEqual(function.label, "⌃⌥F18")
    }

    func testActualCarbonConflictKeepsWorkingRegistrationAndPersistedValue() throws {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘8"))
        let occupied = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘9"))
        let controller = GlobalShortcutController()
        let owner = GlobalShortcutController()
        defer { controller.unregister(); owner.unregister() }
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        try app.registerShortcut(previous)
        try owner.register(occupied)
        let saved = defaults.data(forKey: "globalShortcut")
        XCTAssertThrowsError(try app.registerShortcut(occupied))
        XCTAssertEqual(app.activeShortcut, previous)
        XCTAssertEqual(defaults.data(forKey: "globalShortcut"), saved)
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut, previous)
    }

    func testRecordingReleasesPhysicalRegistrationAndFailedRestoreIsReported() throws {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let value = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘7"))
        let controller = GlobalShortcutController()
        let claimant = GlobalShortcutController()
        defer { controller.unregister(); claimant.unregister() }
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        try app.registerShortcut(value)
        XCTAssertNil(app.setShortcutRecording(true))
        XCTAssertTrue(controller.isPaused)
        // Success proves the OS registration has been physically released for recording.
        try claimant.register(value)
        XCTAssertNotNil(app.setShortcutRecording(false))
        XCTAssertNil(app.activeShortcut)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut, value)
        XCTAssertNil(app.setShortcutRecording(true))
        XCTAssertNotNil(app.setShortcutRecording(false))
        XCTAssertNil(app.activeShortcut)
        XCTAssertNotNil(app.shortcutError)
        preferences.language = .simplifiedChinese
        XCTAssertTrue(app.shortcutError?.contains("无法注册全局快捷键") == true)
        preferences.language = .english
        XCTAssertTrue(app.shortcutError?.contains("Cannot register") == true)
        claimant.unregister()
        XCTAssertNil(app.setShortcutRecording(true))
        XCTAssertNil(app.setShortcutRecording(false))
        XCTAssertEqual(app.activeShortcut, value)
        XCTAssertNil(app.shortcutError)
    }

    func testCancellingRecorderWithoutAnyRegistrationReportsUnavailableShortcut() {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = GlobalShortcutController()
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        XCTAssertNil(app.setShortcutRecording(true))
        XCTAssertNotNil(app.setShortcutRecording(false))
        XCTAssertNil(app.activeShortcut)
        XCTAssertNotNil(app.shortcutError)
        XCTAssertNil(defaults.data(forKey: "globalShortcut"))
    }

    func testNativeRecorderRejectsBareKeysAndRestoresOnEscapeAndFocusLoss() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = RecorderButton(frame: NSRect(x: 0, y: 0, width: 104, height: 36))
        window.contentView!.addSubview(recorder)
        let (preferences, defaults, name) = preferences()
        let shortcut = GlobalShortcut.keyboard(.init(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "⌃⌥⇧⌘6"))
        let controller = GlobalShortcutController()
        let app = AppDelegate(preferences: preferences, shortcutController: controller)
        try app.registerShortcut(shortcut)
        recorder.title = shortcut.title
        var recorded: [GlobalShortcut] = []
        var boundaries: [Bool] = []
        recorder.onRecord = { recorded.append($0) }
        recorder.onRecordingChange = { recording in
            boundaries.append(recording)
            XCTAssertNil(app.setShortcutRecording(recording))
        }
        defer { recorder.endRecording(); controller.unregister(); window.close(); defaults.removePersistentDomain(forName: name) }
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(controller.isPaused)
        XCTAssertNil(app.activeShortcut)
        recorder.keyDown(with: event(code: 0, text: "a"))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorded.isEmpty)
        recorder.keyDown(with: event(code: 53, text: "\u{1b}"))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.title, shortcut.title)
        XCTAssertEqual(boundaries, [true, false])
        XCTAssertEqual(app.activeShortcut, shortcut)
        XCTAssertFalse(controller.isPaused)
        recorder.beginRecording()
        XCTAssertTrue(controller.isPaused)
        XCTAssertNil(app.activeShortcut)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.title, shortcut.title)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(boundaries, [true, false, true, false])
        XCTAssertEqual(app.activeShortcut, shortcut)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut, shortcut)
    }

}
