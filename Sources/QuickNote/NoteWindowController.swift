import AppKit
import QuickNoteCore

final class NotePanel: NSPanel {
    static let cornerRadius: CGFloat = 16
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        MinimalChrome.roundFrame(of: self, cornerRadius: Self.cornerRadius)
    }
}

private final class FormattingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class SaveErrorSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let borderWidth: CGFloat = 0.5
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                xRadius: 14, yRadius: 14)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class LinkInput: NSObject, NSTextFieldDelegate {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    let hint = NSTextField(labelWithString: "请输入有效的网址。")
    weak var completionButton: NSButton?
    var value: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var url: URL? {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              let url = URL(string: value.contains(":") ? value : "https://\(value)"), url.scheme != nil else { return nil }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty != false { return nil }
        return url
    }
    override init() {
        super.init()
        field.placeholderString = "https://example.com"
        field.delegate = self
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .systemOrange
        hint.isHidden = true
    }
    func controlTextDidChange(_ notification: Notification) { validate() }
    func validate() {
        let valid = value.isEmpty || url != nil
        completionButton?.isEnabled = valid
        hint.isHidden = valid
    }
}

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let editor = NoteEditorViewController()
    var onHide: (() -> Void)?
    var onRetrySave: (() -> Void)?
    private let formatPanel = FormattingPanel(contentRect: NSRect(x: 0, y: 0, width: 282, height: 276),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let alignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let morePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let metadataLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private var formatButton: NSButton!
    private var inlineButtons: [NSButton] = []
    private var highlightButtons: [NSButton] = []
    private var errorSurface: NSView!
    private var errorConstraints: [NSLayoutConstraint] = []
    private weak var writingRoot: NSView?
    private var editorBottom: NSLayoutConstraint!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    enum SaveStatus {
        case saved, saving, unsaved(Error), failed(Error), custom(String, isError: Bool)
        func message(language: AppLanguage) -> String {
            switch self {
            case .saved: return AppLocalization.text("所有更改已保存", language: language)
            case .saving: return AppLocalization.text("正在保存…", language: language)
            case .unsaved(let error): return language.text("内容尚未保存：") + localizedError(error, language: language)
            case .failed(let error): return language.text("保存失败：") + localizedError(error, language: language)
            case .custom(let text, _): return text
            }
        }
        var isError: Bool {
            switch self { case .unsaved, .failed: return true; case .custom(_, let error): return error; default: return false }
        }
    }
    private var language = AppPreferences.shared.language
    private var saveStatus: SaveStatus = .saved
    private var savedMessage: String { saveStatus.message(language: language) }
    private weak var linkInput: LinkInput?
    private weak var linkAlert: NSAlert?
    private var characterCount = 0
    private var updatedAt = Date()
    private var characterCountNeedsRefresh = false
    private var shortcut: GlobalShortcut?
    private let kinds: [BlockKind] = [.title, .heading, .subheading, .body, .bullet, .dashed, .numbered, .checklist, .quote, .code]
    private let kindTitles = ["标题", "小标题", "副标题", "正文", "项目列表", "虚线列表", "编号列表", "勾选事项", "引用", "等宽文本"]

    var isFormattingVisible: Bool { formatPanel.isVisible }
    var acceptsEditorCommands: Bool {
        guard window?.attachedSheet == nil, !editor.textView.hasMarkedText() else { return false }
        return (window?.isKeyWindow == true && window?.firstResponder === editor.textView) || formatPanel.isKeyWindow
    }
    var isSaveErrorVisible: Bool { errorSurface.superview != nil }
    var formattingWindow: NSWindow? { formatPanel }

    init() {
        let panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "随记"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 360)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow
        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        if !CommandLine.arguments.contains("--verify-workflow") {
            panel.setFrameAutosaveName("QuickNoteWindow")
            if !panel.setFrameUsingName("QuickNoteWindow") { panel.center() }
        } else { panel.center() }
        buildContent(panel)
        editor.onFormatStateChange = { [weak self] _ in self?.updateFormatControls() }
        updateFormatControls()
        refreshLanguage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(_ panel: NSPanel) {
        let root = NSView()
        writingRoot = root
        panel.contentView = MinimalChrome.surface(content: root, cornerRadius: NotePanel.cornerRadius)
        root.addSubview(editor.view)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        editor.textView.textContainerInset = NSSize(width: 20, height: 14)
        formatButton = MinimalChrome.symbolButton("textformat", label: EditorShortcuts.Command.formatting.tooltip, target: self, action: #selector(toggleFormatting(_:)))
        root.addSubview(formatButton)
        formatButton.translatesAutoresizingMaskIntoConstraints = false
        buildFormatPanel()
        buildErrorSurface(in: root)
        editorBottom = editor.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            editor.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), editorBottom,
            formatButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            formatButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8)
        ])
        updateMetadata()
        MinimalChrome.roundFrame(of: panel, cornerRadius: NotePanel.cornerRadius)
    }

    private func buildFormatPanel() {
        formatPanel.backgroundColor = .clear
        formatPanel.isOpaque = false
        formatPanel.hasShadow = true
        formatPanel.hidesOnDeactivate = false
        formatPanel.isReleasedWhenClosed = false
        formatPanel.onEscape = { [weak self] in self?.closeFormatting(focusEditor: true) }
        stylePopup.addItems(withTitles: kindTitles)
        stylePopup.selectItem(at: 3)
        stylePopup.bezelStyle = .inline
        stylePopup.isBordered = false
        stylePopup.font = .systemFont(ofSize: 15, weight: .medium)
        stylePopup.refusesFirstResponder = false
        stylePopup.target = self
        stylePopup.action = #selector(changeStyle)
        stylePopup.toolTip = "段落样式"
        stylePopup.setAccessibilityLabel("段落样式")
        for (item, kind) in zip(stylePopup.itemArray, kinds) {
            let command: EditorShortcuts.Command
            switch kind {
            case .title: command = .title
            case .heading: command = .heading
            case .subheading: command = .subheading
            case .body: command = .body
            case .bullet: command = .bullet
            case .dashed: command = .dashed
            case .numbered: command = .numbered
            case .checklist: command = .checklist
            case .quote: command = .quote
            case .code: command = .code
            }
            item.keyEquivalent = command.key
            item.keyEquivalentModifierMask = command.modifiers
        }
        inlineButtons = [
            MinimalChrome.symbolButton("bold", label: EditorShortcuts.Command.bold.tooltip, target: self, action: #selector(bold)),
            MinimalChrome.symbolButton("italic", label: EditorShortcuts.Command.italic.tooltip, target: self, action: #selector(italic)),
            MinimalChrome.symbolButton("underline", label: EditorShortcuts.Command.underline.tooltip, target: self, action: #selector(underline)),
            MinimalChrome.symbolButton("strikethrough", label: EditorShortcuts.Command.strikethrough.tooltip, target: self, action: #selector(strikethrough)),
            MinimalChrome.symbolButton("link", label: EditorShortcuts.Command.link.tooltip, target: self, action: #selector(editLink))
        ]
        let colors: [NSColor] = [.systemPurple, .systemPink, .systemOrange, .systemMint, .systemBlue]
        let colorNames = ["紫色", "粉色", "橙色", "薄荷绿", "蓝色"]
        for (index, color) in colors.enumerated() {
            let button = MinimalChrome.symbolButton("circle.fill", label: "\(colorNames[index])高亮", target: self, action: #selector(highlight(_:)))
            button.tag = index
            button.contentTintColor = color.withAlphaComponent(0.8)
            highlightButtons.append(button)
        }
        let clear = MinimalChrome.symbolButton("circle.slash", label: "移除高亮", target: self, action: #selector(clearHighlight))
        alignmentPopup.addItems(withTitles: ["左对齐", "居中", "右对齐", "两端对齐"])
        alignmentPopup.bezelStyle = .inline
        alignmentPopup.isBordered = false
        alignmentPopup.font = .systemFont(ofSize: 12)
        alignmentPopup.toolTip = "段落对齐"
        alignmentPopup.setAccessibilityLabel("段落对齐")
        alignmentPopup.target = self
        alignmentPopup.action = #selector(changeAlignment)
        let paragraph = row([
            MinimalChrome.symbolButton("decrease.indent", label: EditorShortcuts.Command.outdent.tooltip, target: self, action: #selector(outdent)),
            MinimalChrome.symbolButton("increase.indent", label: EditorShortcuts.Command.indent.tooltip, target: self, action: #selector(increaseIndent)),
            MinimalChrome.symbolButton("checklist", label: EditorShortcuts.Command.checklist.tooltip, target: self, action: #selector(checklist)), alignmentPopup
        ], spacing: 7)
        metadataLabel.font = .systemFont(ofSize: 10)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        morePopup.addItems(withTitles: ["更多", "字体与字号…", "文字颜色…", "完成 / 取消完成", "查找…"])
        morePopup.bezelStyle = .inline
        morePopup.isBordered = false
        morePopup.font = .systemFont(ofSize: 11)
        morePopup.toolTip = "字体、文字颜色与查找"
        morePopup.setAccessibilityLabel("更多文本工具")
        morePopup.target = self
        morePopup.action = #selector(moreTools(_:))
        if let completion = morePopup.item(at: 3) {
            completion.keyEquivalent = EditorShortcuts.Command.checked.key
            completion.keyEquivalentModifierMask = EditorShortcuts.Command.checked.modifiers
        }
        if let find = morePopup.item(at: 4) { find.keyEquivalent = "f"; find.keyEquivalentModifierMask = .command }
        let clearFormattingButton = NSButton(title: "清除格式", target: self, action: #selector(clearFormatting))
        clearFormattingButton.bezelStyle = .inline
        clearFormattingButton.isBordered = false
        clearFormattingButton.font = .systemFont(ofSize: 12)
        clearFormattingButton.contentTintColor = .secondaryLabelColor
        clearFormattingButton.toolTip = EditorShortcuts.Command.clear.tooltip
        clearFormattingButton.setAccessibilityLabel("清除格式")
        clearFormattingButton.setAccessibilityIdentifier("clear-formatting")
        let clearShortcut = NSTextField(labelWithString: EditorShortcuts.Command.clear.shortcut)
        clearShortcut.font = .systemFont(ofSize: 11)
        clearShortcut.textColor = .tertiaryLabelColor
        let clearRow = row([clearFormattingButton, NSView(), clearShortcut], spacing: 8)
        clearFormattingButton.setContentHuggingPriority(.required, for: .horizontal)
        clearShortcut.setContentHuggingPriority(.required, for: .horizontal)
        clearFormattingButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let info = row([metadataLabel, morePopup], spacing: 8)
        let stack = NSStackView(views: [caption("文本样式"), stylePopup, row(inlineButtons, spacing: 6),
            row(highlightButtons + [clear], spacing: 6), paragraph, clearRow, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stylePopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clearRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        formatPanel.contentView = MinimalChrome.surface(content: content, cornerRadius: 16)
        MinimalChrome.roundFrame(of: formatPanel, cornerRadius: 16)
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    private func caption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func updateFormatControls() {
        let state = editor.formatState
        stylePopup.selectItem(at: kinds.firstIndex(of: state.kind) ?? 3)
        let flags = [state.bold, state.italic, state.underline, state.strikethrough, false]
        for (button, selected) in zip(inlineButtons, flags) { mark(button, selected: selected) }
        for (index, button) in highlightButtons.enumerated() {
            mark(button, selected: state.highlight == EditorHighlight.allCases[index])
        }
        let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
        alignmentPopup.selectItem(at: alignments.firstIndex(of: state.alignment) ?? 0)
    }

    private func mark(_ button: NSButton, selected: Bool) {
        button.state = selected ? .on : .off
        button.wantsLayer = true
        button.layer?.cornerRadius = MacAppDesignTokens.controlRadius
        button.layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.09).cgColor : nil
        button.setAccessibilityValue(selected ? AppLocalization.text("已选中", language: language) : "")
    }

    private func buildErrorSurface(in root: NSView) {
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .labelColor
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "保存失败")!)
        icon.contentTintColor = .systemOrange
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        retryButton.bezelStyle = .inline
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retrySave)
        retryButton.setAccessibilityLabel("重试保存")
        let content = NSView()
        let stack = row([icon, errorLabel, retryButton], spacing: 10)
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        let inlineContainer = SaveErrorSurface(frame: .zero)
        inlineContainer.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: inlineContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: inlineContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: inlineContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: inlineContainer.bottomAnchor)
        ])
        inlineContainer.setAccessibilityElement(true)
        inlineContainer.setAccessibilityRole(.group)
        inlineContainer.setAccessibilityLabel("保存失败")
        inlineContainer.setAccessibilityIdentifier("quick-note-save-error")
        errorSurface = inlineContainer
        errorSurface.translatesAutoresizingMaskIntoConstraints = false
        errorConstraints = [
            errorSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            errorSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            errorSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ]
    }

    @objc func toggleFormatting(_ sender: Any?) {
        if isFormattingVisible { closeFormatting(focusEditor: true); return }
        guard let window, let screen = window.screen else { return }
        if characterCountNeedsRefresh {
            characterCount = editor.textView.string.reduce(0) { $0 + ($1 == "\n" ? 0 : 1) }
            characterCountNeedsRefresh = false
        }
        updateMetadata(showDetails: true)
        updateFormatControls()
        formatPanel.appearance = window.appearance
        formatPanel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        let anchor = window.convertToScreen(formatButton.convert(formatButton.bounds, to: nil))
        let available = screen.visibleFrame
        let size = formatPanel.frame.size
        let x = min(max(anchor.maxX - size.width, available.minX + 8), available.maxX - size.width - 8)
        var y = anchor.minY - size.height - 7
        if y < available.minY + 8 { y = min(anchor.maxY + 7, available.maxY - size.height - 8) }
        formatPanel.setFrameOrigin(NSPoint(x: x, y: y))
        window.addChildWindow(formatPanel, ordered: .above)
        formatPanel.makeKeyAndOrderFront(nil)
        MinimalChrome.roundFrame(of: formatPanel, cornerRadius: 16)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeFormatting(focusEditor: true)
                return nil
            }
            if event.type != .keyDown, event.window !== self.formatPanel,
               (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue {
                // The launcher action owns this click, so it can close an already-open palette.
                if event.window === self.window,
                   self.formatButton.bounds.contains(self.formatButton.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.closeFormatting(focusEditor: false)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeFormatting(focusEditor: false)
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeFormatting(focusEditor: false) }
            }
        keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let key = notification.object as? NSWindow,
                          key !== self.window, key !== self.formatPanel else { return }
                    self.closeFormatting(focusEditor: false)
                }
            }
    }

    private func closeFormatting(focusEditor: Bool) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver); self.keyWindowObserver = nil }
        window?.removeChildWindow(formatPanel)
        formatPanel.orderOut(nil)
        if focusEditor, window?.isVisible == true { window?.makeKey(); editor.focus() }
    }

    func applyPreferences(_ preferences: AppPreferences) {
        language = preferences.language
        refreshLanguage()
        window?.appearance = preferences.nativeAppearance
        formatPanel.appearance = preferences.nativeAppearance
        window?.level = preferences.floatingWindow ? .floating : .normal
        if isFormattingVisible { formatPanel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1) }
        editor.textView.isContinuousSpellCheckingEnabled = preferences.spellChecking
        editor.textView.isAutomaticLinkDetectionEnabled = preferences.automaticLinks
    }

    private func refreshLanguage() {
        window?.title = language.appName
        if let root = window?.contentView { AppLocalization.refresh(root, language: language, excluding: editor.view) }
        if let root = formatPanel.contentView { AppLocalization.refresh(root, language: language) }
        if let errorSurface { AppLocalization.refresh(errorSurface, language: language) }
        updateFormatControls()
        editor.language = language
        editor.textView.needsDisplay = true
        if let alert = linkAlert {
            alert.messageText = AppLocalization.text("编辑链接", language: language)
            alert.informativeText = AppLocalization.text("为所选文字添加网址，留空可移除链接。", language: language)
            alert.buttons.first?.title = AppLocalization.text("完成", language: language)
            if alert.buttons.count > 1 { alert.buttons[1].title = AppLocalization.text("取消", language: language) }
            linkInput?.hint.stringValue = AppLocalization.text("请输入有效的网址。", language: language)
        }
        setSaveStatus(saveStatus)
        updateMetadata(showDetails: true)
    }

    func dismissFormatting() { closeFormatting(focusEditor: false) }

    func show() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = frontmost }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        WindowPlacement.keepVisible(window)
        window?.makeKeyAndOrderFront(nil)
        editor.focus()
    }

    func toggle() {
        if window?.isVisible == true && (window?.isKeyWindow == true || isFormattingVisible) { hide() } else { show() }
    }

    func hide() {
        closeFormatting(focusEditor: false)
        onHide?()
        window?.orderOut(nil)
        previousApplication?.activate(options: [])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification: Notification) { onHide?() }
    func windowDidResize(_ notification: Notification) { if let window { MinimalChrome.roundFrame(of: window, cornerRadius: NotePanel.cornerRadius) } }
    func windowWillMiniaturize(_ notification: Notification) { closeFormatting(focusEditor: false); onHide?() }

    func setSaveState(_ text: String, isError: Bool = false) {
        setSaveStatus(.custom(text, isError: isError))
    }

    func setSaveStatus(_ status: SaveStatus) {
        saveStatus = status
        let text = savedMessage
        let isError = status.isError
        if isError {
            errorLabel.stringValue = text
            errorLabel.toolTip = text
            errorLabel.setAccessibilityLabel(text)
            if errorSurface.superview == nil, let writingRoot {
                writingRoot.addSubview(errorSurface)
                NSLayoutConstraint.activate(errorConstraints)
            }
        } else {
            NSLayoutConstraint.deactivate(errorConstraints)
            errorSurface.removeFromSuperview()
        }
        editorBottom.constant = isError ? -76 : 0
        updateMetadata()
    }

    func updateDocumentInfo(_ document: NoteDocument) {
        characterCount = document.blocks.reduce(0) { $0 + $1.text.count }
        characterCountNeedsRefresh = false
        updatedAt = document.updatedAt
        updateMetadata()
    }

    func didEdit(at date: Date) {
        updatedAt = date
        characterCountNeedsRefresh = true
    }

    func setShortcut(_ shortcut: GlobalShortcut?) { self.shortcut = shortcut; updateMetadata() }

    private func updateMetadata(showDetails: Bool = false) {
        formatButton?.toolTip = language.format("command.tooltip", language.text("显示 / 隐藏格式工具"), "⌘⌥T") + "\n" + savedMessage
        guard showDetails || isFormattingVisible else { return }
        metadataLabel.stringValue = language.format("%lld 字  ·  %@", Int64(characterCount), savedMessage)
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let date = formatter.string(from: updatedAt)
        let trigger = shortcut?.title ?? AppLocalization.text("菜单栏", language: language)
        metadataLabel.toolTip = date + "\n" + language.format("%@ 唤出 · Esc 收起", trigger)
    }

    @objc func editLink() {
        closeFormatting(focusEditor: true)
        guard let window else { return }
        let selection = editor.textView.selectedRange()
        let input = LinkInput()
        linkInput = input
        let field = input.field
        if selection.location < editor.textView.textStorage!.length,
           let link = editor.textView.textStorage?.attribute(.link, at: selection.location, effectiveRange: nil) {
            field.stringValue = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        }
        let alert = NSAlert()
        linkAlert = alert
        alert.messageText = AppLocalization.text("编辑链接", language: language)
        alert.informativeText = AppLocalization.text("为所选文字添加网址，留空可移除链接。", language: language)
        let accessory = NSStackView(views: [field, input.hint])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = accessory
        alert.addButton(withTitle: AppLocalization.text("完成", language: language))
        alert.addButton(withTitle: AppLocalization.text("取消", language: language))
        input.completionButton = alert.buttons[0]
        input.hint.stringValue = AppLocalization.text("请输入有效的网址。", language: language)
        input.validate()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                guard input.value.isEmpty || input.url != nil else { return }
                self.editor.textView.setSelectedRange(selection)
                self.editor.setLink(input.url)
            }
            self.linkInput = nil
            self.linkAlert = nil
            self.editor.focus()
        }
    }

    private func returnToWriting() { closeFormatting(focusEditor: true) }
    @objc private func changeStyle() { editor.apply(kinds[stylePopup.indexOfSelectedItem]); returnToWriting() }
    @objc private func bold() { editor.toggleBold(); returnToWriting() }
    @objc private func italic() { editor.toggleItalic(); returnToWriting() }
    @objc private func underline() { editor.toggleUnderline(); returnToWriting() }
    @objc private func strikethrough() { editor.toggleStrikethrough(); returnToWriting() }
    @objc private func clearFormatting() { editor.clearFormatting(); returnToWriting() }
    @objc private func highlight(_ sender: NSButton) { editor.setHighlight(EditorHighlight.allCases[sender.tag]); returnToWriting() }
    @objc private func clearHighlight() { editor.setHighlight(nil); returnToWriting() }
    @objc private func checklist() { editor.toggleChecklist(); returnToWriting() }
    @objc private func increaseIndent() { editor.indent(); returnToWriting() }
    @objc private func outdent() { editor.outdent(); returnToWriting() }
    @objc private func changeAlignment() {
        let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
        editor.setAlignment(alignments[alignmentPopup.indexOfSelectedItem]); returnToWriting()
    }
    @objc private func moreTools(_ sender: NSPopUpButton) {
        let command = sender.indexOfSelectedItem
        sender.selectItem(at: 0)
        returnToWriting()
        switch command {
        case 1:
            let manager = NSFontManager.shared
            manager.target = editor.textView
            manager.action = #selector(NSTextView.changeFont(_:))
            let range = editor.textView.selectedRange()
            let attributes = range.location < editor.textView.attributedString().length
                ? editor.textView.attributedString().attributes(at: range.location, effectiveRange: nil) : editor.textView.typingAttributes
            manager.setSelectedFont(attributes[.font] as? NSFont ?? .systemFont(ofSize: 17), isMultiple: false)
            manager.orderFrontFontPanel(nil)
        case 2:
            let panel = NSColorPanel.shared
            panel.setTarget(editor.textView)
            panel.setAction(#selector(NSTextView.changeColor(_:)))
            panel.makeKeyAndOrderFront(nil)
        case 3: editor.toggleChecked()
        case 4:
            let action = NSMenuItem()
            action.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            editor.textView.performFindPanelAction(action)
        default: break
        }
    }
    @objc private func retrySave() { onRetrySave?() }
}
