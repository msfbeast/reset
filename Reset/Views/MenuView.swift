import SwiftUI

/// The menu bar panel: one glanceable status, a few numbers, today's windows, and quiet tools.
struct MenuView: View {
    @Bindable var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var showingNotes = false
    /// How the other tools and accounts are drawn: compact rows, or a card each (Settings → Appearance).
    @AppStorage("menuOthers") private var othersAs = "rows"
    /// The visible height of the display the panel is on, once the panel has said (see PanelScreen).
    @State private var panelScreen: CGFloat?

    private var claude: WindowStatus? { store.visible.first { $0.id == "claude" } }
    /// The account you're using now (see Store.activeClaudeId), else the terminal's, else the first tool.
    private var hero: WindowStatus? { store.visible.first { $0.id == store.activeClaudeId } ?? claude ?? store.visible.first }
    private var others: [WindowStatus] { store.visible.filter { $0.id != hero?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.liveNeedsSignIn {
                signInBanner(title: "Live usage paused", detail: "Claude Code is signed out, so Claude is estimated.")
            } else if store.autoStartNeedsSignIn {
                signInBanner(title: "Auto-start can't run", detail: "Claude Code is signed out, so the next window won't start by itself.")
            }
            if let u = store.updater.available { updateBanner(u) }
            VStack(alignment: .leading, spacing: 12) {
                if let h = hero {
                    LookCard(look: store.look, d: store.cardData(for: h), now: store.now)
                        .frame(height: 128)
                        .help(h.source)
                    notices(for: h)
                } else {
                    Text("No tools switched on yet. Open Settings to pick yours.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.vertical, 20)
                }
                if let id = hero?.id, id == "claude" || id.hasPrefix("claude-") { stats; todayStrip }
                if !others.isEmpty {
                    if othersAs == "cards" {
                        let banners = (store.liveNeedsSignIn || store.autoStartNeedsSignIn ? 1 : 0) + (store.updater.available == nil ? 0 : 1)
                        OtherCards(statuses: others, look: store.look, now: store.now,
                                   room: OtherCards.room(screen: panelScreen ?? OtherCards.screenHeight(), banners: banners),
                                   card: store.cardData)
                            .background(PanelScreen(height: $panelScreen))
                    } else {
                        VStack(spacing: 0) { ForEach(others) { MiniProviderRow(store: store, status: $0) } }
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            toolbar
        }
        .frame(width: 380)
        .background(
            ZStack {
                Color(hex: 0x0B0B0C)
                RadialGradient(colors: [Theme.color(for: hero?.id ?? "claude").opacity(0.16), .clear],
                               center: .top, startRadius: 0, endRadius: 260)
            }
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let h = hero, let img = MascotArt.image(h.id, Mood.of(h, justReset: false)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(subline).font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Text(Fmt.clock.string(from: store.now)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 14).padding(.top, 12)
    }

    private var headline: String {
        guard let h = hero else { return "Reset" }
        switch h.state {
        case .ready: return "\(h.name) · fresh window ready"
        case .unavailable: return h.name
        case .active:
            if let b = h.blockedUntil, b > store.now { return "\(h.name) · weekly limit reached" }
            if let u = h.usedPercent { return "\(h.name) · \(Int((100 - u).rounded()))% left" }
            if let r = h.resetsAt { return "\(h.name) · \(Fmt.countdown(r.timeIntervalSince(store.now))) left" }
            return "\(h.name) · window running"
        }
    }

    private var subline: String {
        guard let h = hero else { return "" }
        if let b = h.blockedUntil, b > store.now { return "Back \(h.blockedEstimate ? "by about " : "")\(Fmt.when(b, now: store.now))" }
        if let r = h.resetsAt {
            // With the sign-in banner showing, the reason is already on screen; "estimated" alone is enough here.
            let note = store.liveNeedsSignIn && h.id == "claude" ? (h.isEstimate ? "estimated" : nil) : store.estimateNote(for: h)
            var line = "Resets \(Fmt.when(r, now: store.now))" + (note.map { " · " + $0 } ?? "")
            if let asOf = h.usageAsOf, h.usedPercent != nil {
                let m = Int(store.now.timeIntervalSince(asOf) / 60)
                if m >= 3 { line += m < 60 ? " · updated \(m) min ago" : " · updated \(Fmt.when(asOf, now: store.now))" }
            }
            return line
        }
        if case .unavailable(let why) = h.state { return why }
        return "Send a message to start the clock"
    }

    /// One banner for both things a signed-out Claude Code breaks; live usage wins when both apply.
    private func signInBanner(title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFB13D))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            Spacer()
            // "Sign in", as the notifications and Settings call it.
            Button(store.signingIn ? "Waiting…" : "Sign in") { store.fixClaudeSignIn() }
                .buttonStyle(PillButtonStyle(tint: Color(hex: 0xFFB13D)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFB13D).opacity(0.1)))
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private func updateBanner(_ u: Updater.Release) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Dash.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reset \(u.version) is available").font(.system(size: 12, weight: .semibold))
                Button("What's new") { showingNotes = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.dim)
                    .popover(isPresented: $showingNotes, arrowEdge: .bottom) { UpdateNotes(release: u) }
            }
            Spacer()
            Button("Skip") { store.updater.skip(u) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.dim)
                .help("Don't offer \(u.version) again")
            Button(Updater.builtFromSource ? "How to update" : "Download") { UpdateNotes.act(on: u) }
                .buttonStyle(PillButtonStyle(tint: Dash.green))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Dash.green.opacity(0.1)))
        .padding(.horizontal, 14).padding(.top, 10)
    }

    @ViewBuilder private func notices(for h: WindowStatus) -> some View {
        // The run-out forecast is the terminal account's (it follows live usage); under another account's card it
        // says whose, rather than vanishing from the menu.
        if h.id == "claude" || claude != nil, let out = store.runsOut {
            Label((h.id == "claude" ? "" : "\(claude?.name ?? "Claude"): ") + "At this pace you run out around \(Fmt.clock.string(from: out))",
                  systemImage: "flame")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xFF8A5C))
                .help((store.forecast.basis.map { $0 + ". " } ?? "") + "Slow down and the warning clears.")
        }
        if let b = store.budget, store.budgetEntry?.id == h.id { budgetNotice(b) }
        if h.id.hasPrefix("claude-"), let c = claude {
            // Read live through the desktop app, only auto-start and the widgets are left with the terminal's account.
            Label("\(store.desktopReading(for: h) == nil ? "Live usage and auto-start" : "Auto-start and the widgets") follow \(c.name), the account Claude Code in Terminal is signed in to",
                  systemImage: "terminal")
                .font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(2)
        }
        if let sec = h.secondary { LimitLine(limit: sec, now: store.now) }
    }

    /// The pacing budget an agent set through reset-mcp. Coloured once it needs attention; clearing it lives on the dashboard.
    private func budgetNotice(_ b: Budget) -> some View {
        let used = store.budgetUsed
        let status = b.status(used: used)
        let color: Color = status == .over ? Color(hex: 0xFF5C3A) : status == .wrapUp ? Color(hex: 0xFFB13D) : Theme.dim
        let state: String = {
            switch status {
            case .normal: return "on pace"
            case .wrapUp: return "wrap up"
            case .over: return b.downshiftModel.map { "over, switch to \($0)" } ?? "over, stop"
            case .unknown: return "usage unknown"
            }
        }()
        return Label("Budget \(b.maxPercent)% · \(b.task) · \(state)", systemImage: "gauge.with.dots.needle.67percent")
            .font(.system(size: 11, weight: status == .normal ? .regular : .medium)).foregroundStyle(color)
            .lineLimit(1).truncationMode(.middle)
            .help(b.advice(used: used))
    }

    // MARK: Numbers

    private var stats: some View {
        let today = store.usage.todayCost
        let week = store.usage.weekCost
        // Every account's week against every account's plan, like the widget; not the dashboard's account filter.
        let plan = store.usage.planCost(since: Date().addingTimeInterval(-7 * 86400), account: nil)
        return HStack(spacing: 8) {
            StatChip(value: Dash.money(today), label: "today")
            StatChip(value: Dash.money(week), label: "7 days")
            if plan > 0 {
                StatChip(value: String(format: "%.1f×", week / plan), label: "value", tint: Dash.green)
            } else {
                StatChip(value: "\(store.usage.windows(days: 7).count)", label: "windows")
            }
        }
    }

    private var todayStrip: some View {
        let wins = store.usage.windows(days: 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer()
                Text("\(wins.count) window\(wins.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            WindowBarcode(windows: wins, days: 1, showLabels: false, rowHeight: 14).frame(height: 14)
            HStack {
                ForEach([0, 6, 12, 18].map(Fmt.hourLabel) + [""], id: \.self) { t in
                    Text(t).font(.system(size: 9)).foregroundStyle(Theme.dim.opacity(0.7))
                    if !t.isEmpty { Spacer() }
                }
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ToolButton(icon: "square.grid.2x2", label: "Dashboard") { open("dashboard") }
                .keyboardShortcut("d")
            ToolButton(icon: "square.and.arrow.up", label: "Share") { store.usage.shareRequested = true; open("dashboard") }
            ToolButton(icon: store.mascots.enabled ? "pawprint.fill" : "pawprint", label: "Pets",
                       active: store.mascots.enabled) { store.mascots.enabled.toggle() }
            ToolButton(icon: "gearshape", label: "Settings") { open("settings") }
                .keyboardShortcut(",")
            Spacer()
            Menu {
                if claude != nil {
                    Button("I just used Claude on the web") { store.markClaudeUsedElsewhere() }
                }
                ForEach(store.visible.filter { $0.canAutoStart && $0.state == .ready && store.commands[$0.id]?.isEmpty == false }) { s in
                    Button("Start a \(s.name) window now") { store.kickNow(s.id) }
                }
                ForEach(store.visible.filter { $0.id.hasPrefix("custom-") }) { s in
                    Button("I started \(s.name)") { store.startCustom(s.id) }
                }
                Button("Rescan now") { store.refresh(); store.usage.refresh() }
                    .keyboardShortcut("r")
                Divider()
                Button("Quit Reset") { quit() }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    /// Auto-start only runs while Reset is open, which nothing said; with it on, ask first. (Phone alerts are
    /// queued on the ntfy server ahead of time, so those still arrive.)
    private func quit() {
        let armed = store.visible.filter { $0.canAutoStart && store.prefs(for: $0.id).autoStart }
        guard !armed.isEmpty else { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = "Quit Reset?"
        alert.informativeText = "Auto-start won't open your next \(armed.map(\.name).joined(separator: " or ")) window while Reset is closed."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

/// The other tools and accounts drawn like the top card, in the same look with their own colour, mascot and weekly
/// line (Settings → Appearance → Other tools in the menu → Cards). Past `room` they scroll, so the menu stays on screen.
struct OtherCards: View {
    let statuses: [WindowStatus]
    let look: Look
    let now: Date
    var room: CGFloat = .infinity
    let card: (WindowStatus) -> CardData

    var body: some View {
        let cards = VStack(alignment: .leading, spacing: 12) {
            ForEach(statuses) { s in
                LookCard(look: look, d: card(s), now: now)
                    .frame(height: 128)
                    .help(s.source)
                if let sec = s.secondary { LimitLine(limit: sec, now: now) }
            }
        }
        if Self.height(statuses) <= room {
            cards
        } else {
            ScrollView { cards }.frame(height: room)
        }
    }

    /// 128 a card, plus a line for each weekly limit, 12 apart.
    static func height(_ statuses: [WindowStatus]) -> CGFloat {
        statuses.reduce(-12) { $0 + 140 + ($1.secondary == nil ? 0 : 26) }
    }

    /// Until the panel reports its own display: the menu opens on the display whose menu bar was clicked, which is
    /// where the pointer is. NSScreen.main is the one with keyboard focus, which on a second display can be much taller.
    static func screenHeight() -> CGFloat {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame.height ?? 900
    }

    /// The screen less the rest of the menu (header, the top card and its notes, today's numbers, the toolbar) and any
    /// banners, and never less than one card.
    static func room(screen: CGFloat, banners: Int) -> CGFloat {
        max(128, screen - 480 - CGFloat(banners) * 60)
    }
}

/// Reports the visible height of the display the menu's panel is on. It's read when the panel is shown or moves to
/// another display, so the cards don't switch between scrolling and not while the pointer wanders to another one.
struct PanelScreen: NSViewRepresentable {
    @Binding var height: CGFloat?

    func makeNSView(context: Context) -> Probe { Probe { h in DispatchQueue.main.async { if height != h { height = h } } } }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let report: (CGFloat) -> Void
        init(report: @escaping (CGFloat) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(read), name: name, object: window)
            }
            read()
        }

        @objc private func read() { if let h = window?.screen?.visibleFrame.height { report(h) } }
    }
}

/// A longer limit under its card: when it resets and how much is used. Amber from 80%: when the weekly limit runs
/// out, a fresh 5-hour window won't help.
struct LimitLine: View {
    let limit: WindowStatus.Secondary
    let now: Date

    var body: some View {
        Label("\(limit.label) resets \(Fmt.when(limit.resetsAt, now: now))\(limit.usedPercent.map { " · \(Int($0.rounded()))% used" } ?? "")",
              systemImage: "calendar")
            .font(.system(size: 11, weight: limit.isHigh ? .medium : .regular))
            .foregroundStyle(limit.isHigh ? Color(hex: 0xFFB13D) : Theme.dim)
    }
}

/// A compact row for providers other than the main one.
struct MiniProviderRow: View {
    let store: Store
    let status: WindowStatus

    var body: some View {
        let d = store.cardData(for: status)
        HStack(spacing: 10) {
            if let img = MascotArt.image(status.id, Mood.of(status, justReset: false)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 26, height: 26)
            } else {
                Circle().fill(Theme.color(for: status.id)).frame(width: 8, height: 8).frame(width: 26)
            }
            Text(status.name).font(.system(size: 12, weight: .medium))
            Spacer()
            // The weekly limit under the 5-hour one, or instead of it, as chosen in Settings → Appearance.
            let weekly = store.limitsShown == .session ? nil : MenuBarGlance.weeklyLeft(status, now: store.now)
            VStack(alignment: .trailing, spacing: 3) {
                if store.limitsShown != .weekly || weekly == nil {
                    HealthDots(left: d.left(at: store.now), color: Theme.color(for: status.id))
                }
                // Dimmer, like the weekly line in the menu bar pill, so the two rows read apart.
                if let w = weekly { HealthDots(left: w / 100, color: Theme.color(for: status.id).opacity(0.6), what: "weekly limit") }
            }
            Group {
                if store.limitsShown == .weekly, weekly != nil, let r = status.secondary?.resetsAt {
                    Text("wk " + MenuBarGlance.roughly(r.timeIntervalSince(store.now)))
                } else {
                    CountdownText(d: d, now: store.now)
                }
            }
            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help(status.source)
    }
}

struct HealthDots: View {
    let left: Double?
    let color: Color
    /// What VoiceOver says the dots are for, when it isn't the 5-hour window.
    var what: String? = nil
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { i in
                let lit = left.map { Double(i) < ($0 * 6).rounded(.up) } ?? true
                Capsule().fill(lit ? (left == nil ? color.opacity(0.3) : color) : Color.white.opacity(0.12)).frame(width: 7, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel((what.map { $0 + ", " } ?? "") + (left.map { "\(Int(($0 * 100).rounded())) percent left" } ?? "usage unknown"))
    }
}

struct StatChip: View {
    let value: String
    let label: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

struct ToolButton: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(.system(size: 9))
            }
            .foregroundStyle(active ? Theme.accent : (hover ? Color.white : Color.white.opacity(0.7)))
            .frame(width: 62, height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
