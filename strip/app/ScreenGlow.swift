import AppKit

/// A soft coloured border around the whole screen that fades in and out once.
/// Click-through and above everything, so it never gets in the way.
@MainActor
enum ScreenGlow {
    private static var windows: [NSWindow] = []

    static func pulse(color: NSColor) {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = GlowView(color: color)
            window.alphaValue = 0
            window.orderFrontRegardless()
            return window
        }
        let shown = windows
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            shown.forEach { $0.animator().alphaValue = 1 }
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1.2
                shown.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    shown.forEach { $0.orderOut(nil) }
                    windows.removeAll { shown.contains($0) }
                }
            })
        })
    }

    private final class GlowView: NSView {
        let color: NSColor
        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            // Concentric strokes with falling alpha read as a glow without a blur filter.
            for step in 0..<14 {
                let inset = CGFloat(step) * 1.5
                color.withAlphaComponent(0.55 * (1 - CGFloat(step) / 14)).setStroke()
                let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}
