import AppKit
import SwiftUI
import QuickNoteCore

/// The same native title-label and focus surface used by Big Bang's shortcut recorder.
@MainActor
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let palette: SettingsPalette
    let language: AppLanguage
    var onRecord: (GlobalShortcut) -> Void
    var onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.isBordered = false
        button.focusRingType = .none
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        button.setAccessibilityIdentifier("settings.shortcut.recorder")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.updateShortcutTitle(shortcut.title)
        button.palette = palette
        button.language = language
        button.onRecord = onRecord
        button.onRecordingChange = onRecordingChange
        button.setAccessibilityLabel(AppLocalization.text("唤出备忘录", language: language))
        button.setAccessibilityValue(shortcut.title)
        button.toolTip = AppLocalization.text("点击录入快捷键，按 Esc 取消。", language: language)
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.endRecording() }
}

@MainActor
final class RecorderButton: NSButton {
    var palette = SettingsPalette(dark: false) { didSet { updateTitlePresentation(); needsDisplay = true } }
    private let titleLabel = RecorderTitleLabel(labelWithString: "")
    override var title: String { didSet { updateTitlePresentation() } }
    private(set) var isRecording = false
    private var hovered = false
    private var previousTitle = ""
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    var onRecord: ((GlobalShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var language: AppLanguage = .english {
        didSet { if isRecording { title = AppLocalization.text("按下快捷键…", language: language) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTitleLabel()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTitleLabel()
    }
    private func configureTitleLabel() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateTitlePresentation()
    }
    private func updateTitlePresentation() {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: isRecording ? 10 : 12, weight: .medium)
        titleLabel.textColor = palette.nativeText
    }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func updateShortcutTitle(_ value: String) { if !isRecording { title = value } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        (hovered ? palette.nativeHover : palette.nativeField).setFill(); outline.fill()
        (focused || isRecording ? palette.nativeAccent : palette.nativeBorder).setStroke()
        outline.lineWidth = focused || isRecording ? 1.5 : 1; outline.stroke()
    }
    @objc func beginRecording() {
        guard !isRecording, let window, window.makeFirstResponder(self) else { return }
        previousTitle = title
        isRecording = true
        title = AppLocalization.text("按下快捷键…", language: language)
        onRecordingChange?(true)
        needsDisplay = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.window === self.window else { self.endRecording(); return event }
            self.keyDown(with: event)
            return nil
        }
        let notifications: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window), (NSApplication.didResignActiveNotification, NSApp)
        ]
        observers = notifications.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording() }
            }
        }
    }
    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if isRecording {
            isRecording = false
            title = previousTitle
            onRecordingChange?(false)
        }
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { endRecording(); needsDisplay = true; return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { endRecording(); window?.makeFirstResponder(nil); return }
        guard !event.isARepeat else { return }
        let value: GlobalShortcut
        if event.keyCode == 12, event.modifierFlags.contains(.function),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { value = .fnQ }
        else if let keyboard = KeyboardShortcut.capture(event) { value = .keyboard(keyboard) }
        else { NSSound.beep(); return }
        endRecording()
        // Registration owns the displayed value; a conflict leaves the old title intact.
        onRecord?(value)
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

private final class RecorderTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
