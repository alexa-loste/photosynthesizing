import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A panel that can take typing without activating the app, so the strip appearing never
/// pulls focus away from Claude. Clicking into the composer makes it key.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let width: CGFloat = 440
    static let margin: CGFloat = 12
    /// Turns shorter than this never show the strip; it would only flash.
    static let showDelay: TimeInterval = 4
    /// After Claude finishes, how long the "done" badge stays before the strip slides away.
    static let hideDelay: TimeInterval = 1.5

    private var panel: StripPanel!
    private var model: StripModel!
    private var visible = false
    private var doneSince: Date?
    /// Close hides the strip for the turn that's running; a newer prompt brings it back.
    private var dismissedUntilAfter: Date?
    /// `--show` keeps the strip up regardless of Claude, for trying it out.
    private let forceShow = CommandLine.arguments.contains("--show")
    /// Opened from the menu bar or ⌃⌥Space: stays until you close it, whatever Claude does.
    private var openedByHand = false
    /// Sessions that were working on the previous tick, to spot the moment one finishes.
    private var lastWorking: Set<String> = []
    private var openedByHandAt = Date.distantPast
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = StripModel(config: Self.loadConfig())
        if CommandLine.arguments.contains("--keep-in-touch") { model.tab = .keepInTouch }
        if CommandLine.arguments.contains("--all") { model.tab = .all }
        // `--open <thread key>` (with --show --snapshot) renders one conversation.
        if let flag = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > flag + 1 {
            model.tab = .all
            model.selected[.all] = CommandLine.arguments[flag + 1]
        }

        panel = StripPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Only take the keyboard when you click into a text field, never just by appearing:
        // the strip slides in while you're typing to Claude.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: StripView(
            model: model,
            onClose: { [weak self] in self?.dismiss() },
            onBackToClaude: { [weak self] in self?.backToClaude() }
        ))

        model.startListening()
        if !forceShow {
            installMenuBarItem()
            installHotKey()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > flag + 1 {
            snapshot(to: CommandLine.arguments[flag + 1])
        }
    }

    /// `--show --snapshot out.png` renders the strip to a file once it has loaded, for
    /// checking the layout without screen-recording permission.
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    /// One line per show/hide, so the trigger logic can be checked without watching the screen.
    static func log(_ line: String) {
        // Snapshot runs are separate processes; keep their show/hide out of the live log.
        guard !CommandLine.arguments.contains("--show") else { return }
        let file = ClaudeWatch.root.appendingPathComponent("app.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    static func loadConfig() -> ServerConfig? {
        let file = ClaudeWatch.root.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    // MARK: - Show and hide

    private func tick() {
        let now = Date()
        let sessions = ClaudeWatch.sessions(now: now)
        let running = sessions.filter(\.isWorking)
        let waiting = sessions.filter(\.needsYou)
        model.sessions = sessions

        // Any one session that just finished, or just stopped to ask you something, gets
        // the glow at the edge of the screen, even while others keep working: with several
        // going, that's the one you're waiting on.
        let finished = sessions.filter { $0.isDone && lastWorking.contains($0.id) }
        let blocked = sessions.filter { $0.needsYou && lastWorking.contains($0.id) }
        if !blocked.isEmpty {
            ScreenGlow.pulse(color: .systemOrange)
        } else if !finished.isEmpty {
            ScreenGlow.pulse(color: .systemGreen)
        }
        lastWorking = Set(running.map(\.id))

        if let since = running.map(\.started).min() {
            model.claude = .working(since: since, projects: running.map(\.project))
            doneSince = nil
            let newest = running.map(\.started).max() ?? since
            // A prompt sent after you opened the strip yourself hands it back to the
            // automatic rule, so it minimizes when that turn ends.
            if openedByHand && newest > openedByHandAt { openedByHand = false }
            let dismissed = dismissedUntilAfter.map { newest <= $0 } ?? false
            if !visible && !dismissed && now.timeIntervalSince(since) >= Self.showDelay {
                show()
            }
        } else if visible || forceShow {
            if case .working = model.claude { doneSince = now }
            model.claude = waiting.isEmpty
                ? (doneSince == nil && (forceShow || openedByHand) ? .idle : .done)
                : .needsYou(projects: waiting.map(\.project))
            let settled = doneSince.map { now.timeIntervalSince($0) >= Self.hideDelay } ?? true
            if visible && !forceShow && !openedByHand && !model.pinned && !model.isMidReply && settled {
                hide()
            }
        } else {
            model.claude = .idle
        }

        if forceShow && !visible { show() }
    }

    private func isWorking(_ claude: StripModel.Claude) -> Bool {
        if case .working = claude { return true }
        return false
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    private func backToClaude() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleID)
            .first?.activate()
        if !model.pinned { hide() }
    }

    private func dismiss() {
        dismissedUntilAfter = Date()
        openedByHand = false
        hide()
    }

    // MARK: - Opening by hand

    /// `open -g claudetv://toggle` (or /show, /hide), for scripts and shortcuts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "claudetv" {
            switch url.host {
            case "show": if !visible { toggle() }
            case "hide": if visible { dismiss() }
            default: toggle()
            }
        }
    }

    @objc func toggle() {
        if visible {
            dismiss()
        } else {
            openedByHand = true
            openedByHandAt = Date()
            show()
        }
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Remembers where you ⌘-drag it to across launches.
        item.autosaveName = "ClaudeTV"
        item.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "Photosynthesizing")
        item.button?.toolTip = "Photosynthesizing (⌃⌥Space)"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
        // Where the icon landed, for when it seems missing (the notch hides overflow).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let frame = item.button?.window?.frame ?? .zero
            let screen = NSScreen.main?.frame ?? .zero
            Self.log("menu bar icon at x=\(Int(frame.minX)) w=\(Int(frame.width)) visible=\(item.isVisible) screen w=\(Int(screen.width)) safe-top=\(Int(NSScreen.main?.safeAreaInsets.top ?? 0))")
        }
    }

    /// ⌃⌥Space from anywhere. A Carbon hot key needs no Accessibility permission, unlike
    /// a global NSEvent monitor.
    private func installHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    (NSApp.delegate as? AppDelegate)?.toggle()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x43_54_56_31), id: 1)  // "CTV1"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func frames() -> (shown: NSRect, hidden: NSRect) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let area = screen.visibleFrame
        let shown = NSRect(
            x: area.maxX - Self.width - Self.margin,
            y: area.minY + Self.margin,
            width: Self.width,
            height: area.height - Self.margin * 2
        )
        return (shown, shown.offsetBy(dx: Self.width + Self.margin * 2, dy: 0))
    }

    private func show() {
        visible = true
        // Test renders draw off-screen, so they never cover your screen or catch a keystroke.
        if CommandLine.arguments.contains("--snapshot") {
            panel.setFrame(NSRect(x: -20_000, y: 0, width: Self.width, height: 900), display: true)
            panel.orderBack(nil)
            Task { await model.reload() }
            return
        }
        Self.log("show")
        let (shown, hidden) = frames()
        panel.setFrame(hidden, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(shown, display: true)
            panel.animator().alphaValue = 1
        }
        Task { await model.reload() }
    }

    private func hide() {
        visible = false
        openedByHand = false
        Self.log("hide")
        // If you were typing in the strip, hand the keyboard back to Claude rather than
        // leaving it with whatever app happened to be behind.
        if panel.isKeyWindow {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleID)
                .first?.activate()
        }
        doneSince = nil
        let (_, hidden) = frames()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hidden, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
