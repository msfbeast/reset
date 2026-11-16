import AppKit
import SwiftUI

/// Shows its content only while the window it's in can be seen. A closed dashboard or menu keeps its window, and
/// SwiftUI kept recomputing and redrawing everything in it once a second as the clock ticked: after the dashboard
/// had been opened once, Reset sat at about 440 MB (260 MB of it graphics) and 6% CPU for good, against 86 MB
/// before. The content is dropped 10 seconds after its window closes, or 5 minutes after it's merely covered or on
/// another Space (so a glance at another app doesn't lose your place), and comes back the moment it shows again.
struct WhileVisible<Content: View>: View {
    @State private var shown = true
    /// The content's last size, held while it's dropped so the window (the menu's panel sizes to fit) doesn't jump.
    @State private var size: CGSize?
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            WindowVisibilityProbe { shown = $0 }
            if shown {
                content.background(GeometryReader { g in
                    Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
                })
            } else {
                Color.clear.frame(width: size?.width, height: size?.height)
            }
        }
    }
}

private struct WindowVisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> WindowVisibilityView { WindowVisibilityView(onChange: onChange) }
    func updateNSView(_ view: WindowVisibilityView, context: Context) { view.onChange = onChange }
}

final class WindowVisibilityView: NSView {
    var onChange: (Bool) -> Void {
        didSet { report = onChange }
    }
    /// Whether each window's content is loaded, by window title, for the `-cycleWindows` check.
    static var loaded: [String: Bool] = [:]
    private var report: (Bool) -> Void = { _ in }
    private func set(_ shown: Bool) {
        Self.loaded[window?.title.isEmpty == false ? window!.title : "menu"] = shown
        report(shown)
    }
    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    /// How long content outlives its window being closed, or covered while still open.
    static let closedDelay: TimeInterval = 10, coveredDelay: TimeInterval = 300

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        self.report = onChange
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { [observer, closeObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        [observer, closeObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        observer = nil; closeObserver = nil
        guard let window else { return }
        // Closing is watched too: a window on another Space is already "not visible", so closing it changes nothing
        // there and no visibility notice comes.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in self?.closed() }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                          queue: .main) { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        guard let window else { return }
        pending?.cancel()
        if window.occlusionState.contains(.visible) { set(true); return }
        // Closed or just covered is decided when the short wait is up, not now: the "no longer visible" notice can
        // arrive a moment before the window counts as closed, which left a closed dashboard loaded for 5 minutes.
        schedule(after: Self.closedDelay) { [weak self] in
            guard let self, let w = self.window else { return }
            if !w.isVisible { self.set(false); return }
            self.schedule(after: Self.coveredDelay - Self.closedDelay) { [weak self] in self?.set(false) }
        }
    }

    private func closed() {
        pending?.cancel()
        schedule(after: Self.closedDelay) { [weak self] in
            guard let self, let w = self.window, !w.isVisible else { return }
            self.set(false)
        }
    }

    /// Runs `then` after the wait, unless the window has become visible again or another change came in first.
    private func schedule(after delay: TimeInterval, then: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let w = self?.window, !w.occlusionState.contains(.visible) else { return }
            then()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
