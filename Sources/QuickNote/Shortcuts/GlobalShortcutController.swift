import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import QuickNoteCore

struct KeyboardShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    var isValid: Bool {
        let required = UInt32(controlKey | optionKey | cmdKey)
        let allowed = required | UInt32(shiftKey)
        return keyCode <= 127 && modifiers & required != 0 && modifiers & ~allowed == 0 && !label.isEmpty
    }

    static func capture(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !event.isARepeat, !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        // AppKit marks navigation and F keys as .function even without a physical Fn press.
        // A physical Fn combined with an ordinary key cannot be represented by Carbon.
        let intrinsicFunctionKeys: Set<UInt16> = [64, 71, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106,
            107, 109, 111, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126]
        guard !flags.contains(.function) || intrinsicFunctionKeys.contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        label += special[event.keyCode] ?? (event.characters(byApplyingModifiers: [])?.uppercased() ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        return .init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}

enum GlobalShortcut: Codable, Equatable, Sendable {
    case keyboard(KeyboardShortcut)
    case fnQ
    static let controlOptionN = Self.keyboard(.init(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥N"))
    var title: String {
        switch self { case .keyboard(let value): return value.label; case .fnQ: return "Fn Q" }
    }
    var isValid: Bool {
        switch self { case .keyboard(let value): return value.isValid; case .fnQ: return true }
    }
}

enum GlobalShortcutError: LocalizedError {
    case carbon(OSStatus)
    case accessibilityRequired
    case eventTapUnavailable
    case invalidCombination
    case recordingInProgress
    case notRegistered

    var errorDescription: String? { description(language: .systemDefault()) }

    func description(language: AppLanguage) -> String {
        switch self {
        case .carbon(let status):
            return language.format("无法注册全局快捷键（错误 %lld）。该组合可能已被其他应用占用。", Int64(status))
        case .accessibilityRequired:
            return language.text("Fn Q 需要辅助功能权限，以截获快捷键并避免把 Q 输入其他应用。请在系统设置中允许随记，然后重新选择此快捷键。")
        case .invalidCombination:
            return language.text("请使用包含 Command、Control 或 Option 的快捷键。")
        case .notRegistered:
            return language.text("快捷键尚未注册，请重新录入或恢复默认快捷键。")
        case .recordingInProgress:
            return language.text("请先完成或取消快捷键录入。")
        case .eventTapUnavailable:
            return language.text("无法截获 Fn Q。请确认辅助功能权限已生效，必要时退出并重新打开应用。")
        }
    }
}

/// Only accepts a plain Fn Q key-down. Other keyboard input is always untouched.
enum FnQEventMatcher {
    static func matches(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return keyCode == Int64(kVK_ANSI_Q)
            && flags.contains(.maskSecondaryFn)
            && flags.intersection(otherModifiers).isEmpty
            && !isRepeat
    }
}

/// Tracks the physical Q press so its repeats and matching release cannot leak
/// into the original frontmost application, even if Fn is released first.
struct FnQEventProcessor {
    enum Result: Equatable {
        case passThrough
        case consume
        case triggerAndConsume
    }

    private var capturedQDown = false

    mutating func process(type: CGEventType, keyCode: Int64,
                          flags: CGEventFlags, isRepeat: Bool) -> Result {
        guard keyCode == Int64(kVK_ANSI_Q) else { return .passThrough }
        if type == .keyUp {
            guard capturedQDown else { return .passThrough }
            capturedQDown = false
            return .consume
        }
        guard type == .keyDown else { return .passThrough }
        if capturedQDown { return .consume }
        guard FnQEventMatcher.matches(keyCode: keyCode, flags: flags, isRepeat: false) else {
            return .passThrough
        }
        capturedQDown = true
        return isRepeat ? .consume : .triggerAndConsume
    }

    mutating func reset() { capturedQDown = false }
}

private final class ShortcutCallbackBox: @unchecked Sendable {
    let trigger: @Sendable () -> Void
    let carbonIdentifier: UInt32?
    var tap: CFMachPort?
    var fnQEvents = FnQEventProcessor()

    init(carbonIdentifier: UInt32? = nil, trigger: @escaping @Sendable () -> Void) {
        self.carbonIdentifier = carbonIdentifier
        self.trigger = trigger
    }
}

private final class CarbonShortcutRegistration {
    let callback: ShortcutCallbackBox
    var handler: EventHandlerRef?
    var hotKey: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, identifier: UInt32,
         trigger: @escaping @Sendable () -> Void) throws {
        callback = ShortcutCallbackBox(carbonIdentifier: identifier, trigger: trigger)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callbackPointer = Unmanaged.passUnretained(callback).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches this handler only for this registration's hot-key ID.
            var eventID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &eventID)
            guard status == noErr, eventID.signature == 0x514E5445 else {
                return OSStatus(eventNotHandledErr)
            }
            let box = Unmanaged<ShortcutCallbackBox>.fromOpaque(context).takeUnretainedValue()
            guard eventID.id == box.carbonIdentifier else { return OSStatus(eventNotHandledErr) }
            box.trigger()
            return noErr
        }, 1, &eventType, callbackPointer, &handler)
        guard handlerStatus == noErr else { throw GlobalShortcutError.carbon(handlerStatus) }

        let status = RegisterEventHotKey(keyCode, modifiers,
                                         EventHotKeyID(signature: 0x514E5445, id: identifier),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw GlobalShortcutError.carbon(status)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

private final class FnQShortcutRegistration {
    let callback: ShortcutCallbackBox
    let tap: CFMachPort
    let source: CFRunLoopSource

    init(trigger: @escaping @Sendable () -> Void) throws {
        callback = ShortcutCallbackBox(trigger: trigger)
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                            place: .headInsertEventTap,
                                            options: .defaultTap,
                                            eventsOfInterest: (CGEventMask(1) << CGEventType.keyDown.rawValue)
                                                | (CGEventMask(1) << CGEventType.keyUp.rawValue),
                                            callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<ShortcutCallbackBox>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                box.fnQEvents.reset()
                if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            switch box.fnQEvents.process(type: type,
                                        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                        flags: event.flags,
                                        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            case .triggerAndConsume:
                box.trigger()
                return nil
            case .consume:
                return nil
            case .passThrough:
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: Unmanaged.passUnretained(callback).toOpaque()) else {
            throw GlobalShortcutError.eventTapUnavailable
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            throw GlobalShortcutError.eventTapUnavailable
        }
        tap = newTap
        source = newSource
        callback.tap = newTap
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        callback.tap = nil
    }
}

@MainActor
final class GlobalShortcutController {
    var onTrigger: (() -> Void)?
    private(set) var activeShortcut: GlobalShortcut?
    private(set) var isPaused = false
    private var carbonRegistration: CarbonShortcutRegistration?
    private var fnRegistration: FnQShortcutRegistration?
    private var generation: UInt32 = 0
    // Retain the last accepted choice independently of the live OS registration.
    private var shortcutToRestore: GlobalShortcut?

    /// Registration is transactional: failures preserve the previous shortcut.
    func register(_ preset: GlobalShortcut, requestPermission: Bool = false) throws {
        guard !isPaused else { throw GlobalShortcutError.recordingInProgress }
        guard preset.isValid else { throw GlobalShortcutError.invalidCombination }
        guard activeShortcut != preset || (carbonRegistration == nil && fnRegistration == nil) else { return }
        let nextGeneration = generation &+ 1
        let trigger: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == nextGeneration, self.activeShortcut == preset && !self.isPaused else { return }
                self.onTrigger?()
            }
        }

        var newCarbon: CarbonShortcutRegistration?
        var newFn: FnQShortcutRegistration?
        switch preset {
        case .keyboard(let value):
            newCarbon = try CarbonShortcutRegistration(keyCode: value.keyCode, modifiers: value.modifiers,
                                                       identifier: nextGeneration, trigger: trigger)
        case .fnQ:
            var accessibility = AXIsProcessTrusted()
            if !accessibility && requestPermission {
                accessibility = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            guard accessibility else { throw GlobalShortcutError.accessibilityRequired }
            newFn = try FnQShortcutRegistration(trigger: trigger)
        }
        carbonRegistration = newCarbon
        fnRegistration = newFn
        generation = nextGeneration
        activeShortcut = preset
        shortcutToRestore = preset
    }

    /// Unregister while recording so the existing shortcut reaches the native input client.
    /// Invalidate callbacks already queued before the recording boundary.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        activeShortcut = nil
        generation &+= 1
        carbonRegistration = nil
        fnRegistration = nil
    }

    func resume() throws {
        guard isPaused else { return }
        isPaused = false
        guard let saved = shortcutToRestore else { throw GlobalShortcutError.notRegistered }
        do { try register(saved) }
        catch { activeShortcut = nil; throw error }
    }

    func unregister() {
        generation &+= 1
        activeShortcut = nil
        shortcutToRestore = nil
        isPaused = false
        carbonRegistration = nil
        fnRegistration = nil
    }

    static func openPrivacySettings() {
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
