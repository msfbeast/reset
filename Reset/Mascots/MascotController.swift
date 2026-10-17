import AppKit
import Observation
import SwiftUI

/// A borderless, transparent, always-on-top panel that never steals focus.
final class MascotPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one panel per visible mascot and keeps them placed: free-floating, perched on the active
/// window, beside the notch, or above the Dock.
@Observable
final class MascotController {
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "mascotsEnabled"); sync() } }
    var placement: Placement { didSet { UserDefaults.standard.set(placement.rawValue, forKey: "mascotPlacement"); layout(animated: true) } }
    var size: Double { didSet { UserDefaults.standard.set(size, forKey: "mascotSize"); rebuildAll() } }
    var hidden: Set<String> { didSet { UserDefaults.standard.set(Array(hidden), forKey: "mascotHidden"); sync() } }

    private weak var store: Store?
    private var panels: [String: MascotPanel] = [:]
    /// For the self-test: how many mascot panels are alive.
    var panelCount: Int { panels.count }
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var lastReset: [String: Date] = [:]
    private var wasActive: [String: Bool] = [:]
    private var tracker: Timer?
    /// One "panel moved" observer per mascot id, so each can be removed with its panel. A flat list
    /// was never drained, which kept every removed panel alive and its observer firing.
    private var moveObservers: [String: NSObjectProtocol] = [:]

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "mascotsEnabled") as? Bool ?? true
        placement = Placement(rawValue: d.string(forKey: "mascotPlacement") ?? "") ?? .float
        size = d.object(forKey: "mascotSize") as? Double ?? 84
        hidden = Set(d.stringArray(forKey: "mascotHidden") ?? [])
    }

    func attach(_ store: Store) {
        self.store = store
        tracker = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout(animated: false) }
        sync()
    }

    /// Statuses that get a mascot right now.
    private var shown: [WindowStatus] {
        guard enabled, let store else { return [] }
        return Self.shown(store.visible, activeClaude: store.activeClaudeId).filter { !hidden.contains($0.id) }
    }

    /// One mascot per tool. Claude's shows the account you're using (Store.activeClaudeId), so after switching
    /// accounts in the desktop app it naps or wakes with that account's window, not the terminal's. It keeps the id
    /// "claude", and with it its place on screen and whether it's hidden; its name label says which account it is.
    static func shown(_ visible: [WindowStatus], activeClaude: String) -> [WindowStatus] {
        visible.compactMap { s in
            guard MascotArt.providers.contains(s.id) else { return nil }
            guard s.id == "claude", activeClaude != "claude", var active = visible.first(where: { $0.id == activeClaude }) else { return s }
            active.id = "claude"
            return active
        }
    }

    private var panelSize: NSSize { NSSize(width: size * 1.25, height: size * 1.55 + 26) }

    /// Called after every rescan: create, refresh, or remove panels.
    func sync() {
        let list = shown
        let ids = Set(list.map(\.id))
        for (id, p) in panels where !ids.contains(id) {
            p.orderOut(nil)
            removeMoveObserver(id)
            panels[id] = nil
            hosts[id] = nil
        }
        for s in list {
            // A window that was running and is now ready just reset: play the waking pose for a minute. Not when
            // Claude's mascot moved to another account, whose window simply isn't running.
            let active = s.resetsAt != nil
            let sameAccount = shownAccount[s.id] == s.account
            if wasActive[s.id] == true && !active && sameAccount { lastReset[s.id] = Date() }
            wasActive[s.id] = active
            shownAccount[s.id] = s.account
            if panels[s.id] == nil { makePanel(for: s) }
        }
        refreshViews()
        layout(animated: false)
    }

    private func makePanel(for s: WindowStatus) {
        let p = MascotPanel(size: panelSize)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(origin: .zero, size: panelSize)
        p.contentView = host
        panels[s.id] = p
        hosts[s.id] = host
        if let saved = UserDefaults.standard.string(forKey: "mascotOrigin-\(s.id)") {
            p.setFrameOrigin(NSPointFromString(saved))
        } else {
            p.setFrameOrigin(defaultFloatOrigin(index: panels.count - 1))
        }
        removeMoveObserver(s.id)
        moveObservers[s.id] = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self, weak p] _ in
            guard let self, let p, self.placement == .float, !self.isPlacing else { return }
            UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: "mascotOrigin-\(s.id)")
        }
        p.orderFrontRegardless()
    }

    /// Stops watching a mascot's panel; called whenever that panel is torn down.
    private func removeMoveObserver(_ id: String) {
        if let token = moveObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
    }

    deinit {
        for token in moveObservers.values { NotificationCenter.default.removeObserver(token) }
    }

    private func rebuildAll() {
        for id in Array(moveObservers.keys) { removeMoveObserver(id) }
        for (_, p) in panels { p.orderOut(nil) }
        panels = [:]
        hosts = [:]
        sync()
    }

    private func refreshViews() {
        guard let store else { return }
        for s in shown {
            guard let host = hosts[s.id] else { continue }
            let justReset = lastReset[s.id].map { Date().timeIntervalSince($0) < 75 } ?? false
            let mood = Mood.of(s, justReset: justReset)
            host.rootView = AnyView(
                MascotView(status: s, mood: mood, size: size, now: store.now,
                           onPlacement: { [weak self] p in self?.placement = p },
                           onHide: { [weak self] in self?.hidden.insert(s.id) })
                    .frame(width: panelSize.width, height: panelSize.height, alignment: .bottom)
            )
        }
    }

    /// Which Claude account each mascot last showed (see `shown`).
    private var shownAccount: [String: String?] = [:]

    private var tickCount = 0
    private func tick() {
        tickCount += 1
        // Countdown labels only need a refresh once a second; perching follows the window at 15 fps.
        if tickCount % 15 == 0 { refreshViews() }
        if placement == .perch { layout(animated: false) }
    }

    // MARK: Placement

    private var isPlacing = false

    private func layout(animated: Bool) {
        let ids = shown.map(\.id).filter { panels[$0] != nil }
        guard !ids.isEmpty else { return }
        isPlacing = true
        defer { isPlacing = false }
        let sz = panelSize
        let origins: [NSPoint]
        switch placement {
        case .float:
            if animated {
                for (i, id) in ids.enumerated() {
                    let o = UserDefaults.standard.string(forKey: "mascotOrigin-\(id)").map(NSPointFromString) ?? defaultFloatOrigin(index: i)
                    move(panels[id]!, to: o, animated: true)
                }
            }
            return
        case .perch:
            guard let frame = frontWindowFrame() else { return }
            // Sit on the top edge, lined up from the right, feet on the title bar.
            origins = ids.indices.map { i in
                NSPoint(x: frame.maxX - CGFloat(i + 1) * (sz.width * 0.8) - 40, y: frame.maxY - sz.height * 0.22)
            }
        case .notch:
            let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
            let f = screen.frame
            let notchRight: CGFloat
            if let right = screen.auxiliaryTopRightArea { notchRight = right.minX } else { notchRight = f.midX + 100 }
            let top = f.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            // Hang just under the menu bar, starting at the right edge of the notch.
            origins = ids.indices.map { i in NSPoint(x: notchRight + 6 + CGFloat(i) * sz.width * 0.85, y: top - sz.height + 6) }
        case .dock:
            let screen = NSScreen.main!
            let v = screen.visibleFrame
            let total = CGFloat(ids.count) * sz.width * 0.85
            origins = ids.indices.map { i in NSPoint(x: v.midX - total / 2 + CGFloat(i) * sz.width * 0.85, y: v.minY - 6) }
        }
        for (i, id) in ids.enumerated() { move(panels[id]!, to: origins[i], animated: animated) }
    }

    private func move(_ p: NSPanel, to o: NSPoint, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().setFrameOrigin(o)
            }
        } else if p.frame.origin != o {
            p.setFrameOrigin(o)
        }
    }

    private func defaultFloatOrigin(index: Int) -> NSPoint {
        let v = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: v.maxX - panelSize.width * CGFloat(index + 1) - 24, y: v.minY + 24)
    }

    /// Frame of the frontmost app's main window, in Cocoa screen coordinates. Window bounds come from
    /// the window server and need no Accessibility or Screen Recording permission.
    private func frontWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 200, height > 120 else { continue }
            return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
        }
        return nil
    }
}
