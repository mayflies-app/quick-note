import AppKit

/// Restored window positions can refer to a disconnected display or a larger
/// workspace. Keep the user's position whenever it still fits a visible screen.
enum WindowPlacement {
    static func frame(for frame: NSRect, visibleFrames: [NSRect], fallback: NSRect? = nil) -> NSRect {
        let screens = visibleFrames.filter { !$0.isEmpty && !$0.isInfinite }
        guard let first = screens.first else { return frame }
        if screens.contains(where: { $0.contains(frame) }) { return frame }
        let intersecting = screens.max {
            area($0.intersection(frame)) < area($1.intersection(frame))
        }
        let target: NSRect
        if let intersecting, area(intersecting.intersection(frame)) > 0 {
            target = intersecting
        } else {
            target = fallback.flatMap { screens.contains($0) ? $0 : nil } ?? first
        }
        let size = NSSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        return NSRect(x: max(target.minX, min(frame.minX, target.maxX - size.width)),
                      y: max(target.minY, min(frame.minY, target.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }

    @MainActor
    static func keepVisible(_ window: NSWindow?) {
        guard let window else { return }
        let screens = NSScreen.screens
        let fallback = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? screens.first
        let frame = Self.frame(for: window.frame, visibleFrames: screens.map(\.visibleFrame), fallback: fallback?.visibleFrame)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
    }
}
