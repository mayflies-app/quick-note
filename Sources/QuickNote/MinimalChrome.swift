import AppKit

/// A single material per window, with the native frame clipped to the same curve.
@MainActor
enum MinimalChrome {
    static func surface(content: NSView, cornerRadius: CGFloat = 18, interactive: Bool = false) -> NSView {
        let forceStandard = CommandLine.arguments.contains("--verify-workflow")
            && CommandLine.arguments.contains("--standard-appearance")
        return MacAppGlass.makeSurface(content: content, cornerRadius: cornerRadius,
                                      forceStandard: forceStandard, interactive: interactive).view
    }

    static func roundFrame(of window: NSWindow, cornerRadius: CGFloat = 18) {
        guard let frame = window.contentView?.superview else { return }
        frame.wantsLayer = true
        frame.layer?.cornerRadius = cornerRadius
        frame.layer?.masksToBounds = true
    }

    static func symbolButton(_ symbol: String, label: String, target: AnyObject?, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let button = NSButton(image: image, target: target, action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.refusesFirstResponder = false
        button.contentTintColor = .secondaryLabelColor
        button.image = image.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: MacAppDesignTokens.symbolButtonExtent).isActive = true
        button.heightAnchor.constraint(equalToConstant: MacAppDesignTokens.symbolButtonExtent).isActive = true
        return button
    }
}
