import SwiftUI

struct DashboardView: View {
    @Bindable var store: Store
    @Bindable var usage: UsageStore
    /// For rendering to an image: lay everything out at full height instead of scrolling.
    var flat = false
    @State private var editingPlan = false
    @State private var sharing = false
    @Environment(\.openWindow) private var openWindow

    private var claude: WindowStatus? { store.statuses.first { $0.id == "claude" } }

    /// The account the top of the dashboard is about: the one picked in the account switch, else the main one.
    /// The cards below followed the switch while the countdown stayed on Team.
    private var shown: WindowStatus? {
        if let id = usage.account, let s = store.statuses.first(where: { $0.id == id }) { return s }
        return claude
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
                scrolling {
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            heroCard.frame(maxWidth: .infinity)
                            valueCard.frame(width: 360)
                        }
                        windowsCard
                        HStack(alignment: .top, spacing: 16) {
                            mixCard
                            heatCard
                        }
                        HStack(alignment: .top, spacing: 16) {
                            sessionsCard
                            sessionDetailCard
                        }
                        projectsCard
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 1120, minHeight: 760)
        .onAppear {
            if usage.lastScan == nil { usage.refresh() }
            if usage.shareRequested { usage.shareRequested = false; sharing = true }
        }
        .onChange(of: usage.shareRequested) { _, v in if v { usage.shareRequested = false; sharing = true } }
    }

    @ViewBuilder private func scrolling<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if flat { c() } else { ScrollView { c() } }
    }

    // MARK: Top bar

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let first = Demo.isOn ? "" : (NSFullUserName().split(separator: " ").first.map(String.init) ?? "")
        return first.isEmpty ? part + "." : "\(part), \(first)."
    }

    private var nextWindowLine: String {
        guard let c = shown else { return "" }
        let name = c.id == "claude" && usage.account == nil ? "Claude" : c.name
        if c.state == .ready { return "A fresh \(name) window is ready." }
        if let r = c.resetsAt { return "Your next \(name) window opens at \(Fmt.when(r, now: store.now))." }
        return ""
    }

    private func pickerChip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12))
                .foregroundStyle(selected ? .white : Dash.dim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.white.opacity(0.1) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            (Text(greeting + " ").foregroundColor(Dash.dim) + Text(nextWindowLine).foregroundColor(.white))
                .font(.system(size: 15))
            Spacer()
            // With more than one Claude account, choose whose costs, windows and projects the dashboard shows.
            if usage.accounts.count > 1 {
                HStack(spacing: 2) {
                    pickerChip("All", selected: usage.account == nil) { usage.account = nil }
                    ForEach(usage.accounts, id: \.id) { a in
                        pickerChip(a.name.components(separatedBy: " · ").last ?? a.name, selected: usage.account == a.id) { usage.account = a.id }
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.04)))
            }
            HStack(spacing: 2) {
                ForEach(Array(UsageRange.allCases.enumerated()), id: \.element) { i, r in
                    Button { usage.range = r } label: {
                        Text(r.rawValue).font(.system(size: 12))
                            .foregroundStyle(usage.range == r ? .white : Dash.dim)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(usage.range == r ? Color.white.opacity(0.1) : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // ⌘1…⌘4 switch range.
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .help("\(r.rawValue) (⌘\(i + 1))")
                    .accessibilityAddTraits(usage.range == r ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            if usage.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if usage.lastScan == nil {
                        Text(usage.filesRead > 0 ? "Reading your history · \(usage.filesRead) files" : "Reading your history…")
                            .font(.system(size: 12)).foregroundStyle(Dash.dim)
                    }
                }
            }
            Button { sharing = true } label: {
                Text("Share card").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $sharing) { ShareSheet(usage: usage) }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Providers").font(Dash.label).foregroundStyle(Dash.dim).padding(.horizontal, 10).padding(.bottom, 4)
            // Second Claude accounts ("claude-<org>") too: they share Claude's art, and the exact-id check hid them.
            ForEach(store.visible.filter { MascotArt.providers.contains($0.id) || $0.id.hasPrefix("claude-") }) { s in
                HStack(spacing: 10) {
                    WindowArc(progress: arcProgress(s), color: Theme.color(for: s.id), lineWidth: 1.6)
                        .accessibilityHidden(true)
                        .frame(width: 22, height: 13)
                    Text(s.name).font(.system(size: 13)).foregroundStyle(s.id == "claude" ? .white : Color.white.opacity(0.75))
                    Spacer()
                    Text(sidebarValue(s)).font(Dash.num(12)).foregroundStyle(Theme.color(for: s.id))
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(s.id == "claude" ? Color.white.opacity(0.06) : .clear))
            }
            Text("Automations").font(Dash.label).foregroundStyle(Dash.dim).padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 4)
            sideToggle("Auto-start", on: store.prefs(for: "claude").autoStart,
                       help: "Start the next Claude window automatically when one runs out") { v in
                store.setPrefs("claude") { $0.autoStart = v }
            }
            sideToggle("Phone alerts", on: store.phoneEnabled,
                       help: store.ntfyTopic.isEmpty ? "Set a topic in Settings → Phone alerts first" : "Send reset alerts to your phone through ntfy") { v in
                if v && store.ntfyTopic.isEmpty {
                    // Phone alerts live on the General tab; open there rather than wherever Settings was left.
                    UserDefaults.standard.set("general", forKey: "settingsTab")
                    NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings"); return
                }
                store.phoneEnabled = v
            }
            sideToggle("Mascots", on: store.mascots.enabled, help: "Show the desktop mascots") { v in
                store.mascots.enabled = v
            }
            sideToggle("Stay awake", on: store.keepAwake.mode != .off,
                       detail: store.keepAwake.mode == .off ? nil : (store.keepAwake.isHolding ? "holding" : "on battery"),
                       help: "Keep the Mac from idle-sleeping when plugged in, so auto-start and alerts run on time") { v in
                store.keepAwake.mode = v ? .pluggedIn : .off
            }
            Spacer()
            if let t = usage.lastScan {
                // A button, ⌘R: the dashboard otherwise rescans every 5 minutes, and "Rescan now" lived only in the menu.
                Button { store.refresh(); usage.refresh() } label: {
                    Label("Usage read \(Fmt.clock.string(from: t))", systemImage: "arrow.clockwise")
                        .font(.system(size: 11)).foregroundStyle(Dash.faint)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")
                .help("Read usage again (⌘R)")
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 10)
        .frame(width: 220)
    }

    /// A real switch: clicking the row flips the setting, the same one Settings changes.
    private func sideToggle(_ name: String, on: Bool, detail: String? = nil, help: String, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.85))
                    if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Dash.faint) }
                }
                Spacer()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Dash.claude.opacity(0.85) : Color.white.opacity(0.14)).frame(width: 30, height: 17)
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: on)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // The capsule is drawn, so VoiceOver would only hear the name; say it's a switch and whether it's on.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(help)
    }

    private func arcProgress(_ s: WindowStatus) -> Double {
        if let u = s.usedPercent { return u / 100 }
        if case .active(let end) = s.state {
            let w: Double = s.id == "gemini" ? 86400 : 5 * 3600
            return 1 - min(1, end.timeIntervalSince(store.now) / w)
        }
        return 0
    }

    private func sidebarValue(_ s: WindowStatus) -> String {
        switch s.state {
        case .ready: return "ready"
        case .unavailable: return "--"
        case .active(let end):
            if let u = s.usedPercent { return "\(Int(u.rounded()))%" }
            return Fmt.short(end.timeIntervalSince(store.now))
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        // Sign-in, the forecast and budgets belong to the account Claude Code is signed in to.
        let main = shown?.id == "claude"
        return HeroCard(status: shown, now: store.now, subtitle: heroSubtitle(shown), signedOut: main && store.liveNeedsSignIn,
                        signingIn: store.signingIn, runsOutAt: main ? store.runsOut : nil, budget: main ? store.budget : nil,
                        budgetUsed: store.budgetUsed, onSignIn: { store.fixClaudeSignIn() }, onClearBudget: { store.clearBudget() })
    }

    /// Where the numbers come from, and why they're a guess when they are, e.g. "Estimated from your activity ·
    /// live usage off". An estimate shouldn't read as confidently as a live reading.
    private func heroSubtitle(_ c: WindowStatus?) -> String {
        guard let c else { return "" }
        let base = c.isEstimate ? "Estimated from your activity" : c.source
        guard let note = store.estimateNote(for: c) else { return base }
        // The note starts with "estimated" or "usage unknown"; only its reason adds anything to the base line.
        let why = note.components(separatedBy: " · ").last ?? note
        return c.isEstimate ? "\(base) · \(why)" : "\(base) · usage unknown, \(why)"
    }


    // MARK: Value

    private var valueCard: some View {
        GlowCard(glow: Dash.green, glowAt: UnitPoint(x: 1.0, y: 1.0), glowSize: 260, glowOpacity: 0.45) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Value \(rangePhrase)", subtitle: "API price of your tokens vs what you pay")
                Spacer(minLength: 0)
                if let m = usage.valueMultiple {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Group {
                            Text(String(format: m >= 100 ? "%.0f" : "%.1f", m)).font(Dash.hero(92)).foregroundStyle(.white)
                            Text("×").font(Dash.hero(34)).foregroundStyle(Dash.dim)
                        }
                        .help(multipleHelp)
                        Spacer()
                        planButton("Edit plan")
                    }
                    (Text(Dash.money(usage.totalCost)).foregroundColor(.white) + Text(" of API value on ").foregroundColor(Dash.dim)
                        + Text(Dash.money(usage.planCostForRange)).foregroundColor(.white) + Text(" of plan").foregroundColor(Dash.dim))
                        .font(.system(size: 13))
                } else {
                    Text(Dash.money(usage.totalCost)).font(Dash.hero(72)).foregroundStyle(.white)
                    Text("of API value \(rangePhrase).").font(.system(size: 13)).foregroundStyle(Dash.dim)
                    planButton("Add your plan price to see the multiple").padding(.top, 10)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cache saved you").font(Dash.label).foregroundStyle(Dash.dim)
                        Text(Dash.money(usage.cacheSaved)).font(Dash.num(24, .light)).foregroundStyle(Dash.green)
                    }
                    .help("What these tokens would have cost read as fresh input, minus what reading them from Claude's cache cost, at API prices.")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Responses").font(Dash.label).foregroundStyle(Dash.dim)
                        Text(NumberFormatter.localizedString(from: NSNumber(value: usage.inRange.count), number: .decimal))
                            .font(Dash.num(24, .light)).foregroundStyle(.white)
                    }
                    .help("Replies from Claude \(rangePhrase), counting each step of a tool-using turn.")
                }
            }
            .frame(height: 312)
        }
    }

    /// How the multiple is worked out: the plan price is spread over the days in the range, so short ranges
    /// (Today early in the morning) can read high.
    private var multipleHelp: String {
        let days = usage.range.days(now: Date())
        let d = days < 1 ? String(format: "%.0f hours", days * 24) : String(format: days < 10 ? "%.1f days" : "%.0f days", days)
        return "\(Dash.money(usage.totalCost)) of API value ÷ \(Dash.money(usage.planCostForRange)), which is \(d) of a "
            + "\(Dash.money(usage.effectivePlan))/month plan."
    }

    private func planButton(_ title: String) -> some View {
        Button { editingPlan = true } label: {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editingPlan, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What you pay per month").font(.system(size: 13, weight: .medium))
                // One field per account shown: the chosen one, or every account under All, which adds them up.
                ForEach(planAccounts, id: \.id) { a in
                    HStack {
                        if planAccounts.count > 1 || usage.accounts.count > 1 {
                            Text(a.name).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                        }
                        Text("$")
                        TextField("20", value: Binding(get: { usage.planMonthly(for: a.id) }, set: { usage.setPlanMonthly($0, for: a.id) }),
                                  format: .number).frame(width: 90)
                            .onSubmit { editingPlan = false }
                    }
                }
                Text(usage.accounts.count > 1 ? "Each account's own plan. All adds them up. Used only on this Mac to work out the multiple."
                                              : "Your Claude plan's price. Used only on this Mac to work out the multiple.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
            }
            .padding(14)
        }
    }

    /// The accounts whose plan price the popover edits.
    private var planAccounts: [(id: String, name: String)] {
        guard usage.accounts.count > 1 else { return [("claude", "Claude")] }
        if let a = usage.account, let entry = usage.accounts.first(where: { $0.id == a }) { return [(entry.id, entry.name)] }
        return usage.accounts.map { ($0.id, $0.name) }
    }

    /// The ranges are rolling ("7 days" back from now), so "this week" and "this month" described something else.
    private var rangePhrase: String {
        switch usage.range {
        case .today: return "today"
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .all: return "in the last \(Int(UsageStore.historyDays)) days"
        }
    }

    // MARK: Windows

    private var windowsCard: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardHeader(title: "Your windows", subtitle: "Every 5-hour Claude window, last 7 days")
                    Spacer()
                    HStack(spacing: 16) {
                        LegendDot(color: Dash.claude, text: "you started it")
                        LegendDot(color: Dash.claude, text: "auto-start", outlined: true)
                        LegendDot(color: Color(hex: 0xFF5C3A), text: "hit the limit")
                    }
                }
                WindowBarcode(windows: usage.windows(days: 7, scoped: true)).frame(height: 230)
            }
        }
    }

    // MARK: Mix and heatmap

    private var mixCard: some View {
        let mix = usage.tokenMix
        let pct: (Int) -> String = { n in
            let p = mix.total > 0 ? Double(n) / Double(mix.total) * 100 : 0
            return p >= 10 ? String(format: "%.0f%%", p) : String(format: "%.1f%%", p)
        }
        return GlowCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    CardHeader(title: "Token mix", subtitle: "Each square is 1% of tokens \(rangePhrase)")
                    Spacer()
                    Text(Dash.tokens(mix.total)).font(Dash.num(28, .light)).foregroundStyle(.white)
                }
                HStack(alignment: .center, spacing: 22) {
                    TokenGrid(mix: mix).frame(width: 300)
                    VStack(spacing: 0) {
                        legendRow(Dash.blue, "Cache read", pct(mix.cacheRead), first: true)
                        legendRow(Dash.violet, "Cache write", pct(mix.cacheWrite))
                        legendRow(Dash.claude, "Output", pct(mix.output))
                        legendRow(.white.opacity(0.85), "Input", pct(mix.input))
                    }
                }
            }
        }
    }

    private func legendRow(_ c: Color, _ name: String, _ v: String, first: Bool = false) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(name).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            Text(v).font(Dash.num(13))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Dash.line).frame(height: 1) } }
    }

    private var heatCard: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    CardHeader(title: "When you build", subtitle: "Output by weekday and hour, last 5 weeks")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(usage.busiestHour.map(hourLabel) ?? "--").font(Dash.num(28, .light)).foregroundStyle(.white)
                        Text("busiest hour").font(Dash.label).foregroundStyle(Dash.dim)
                    }
                }
                Heatmap(grid: usage.scopedHeatmap, labels: true).frame(height: 120)
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        Fmt.hourLabel(h)
    }

    // MARK: Sessions

    private var sessionsCard: some View {
        let list = Array(usage.sessions.prefix(8))
        return GlowCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sessions").font(Dash.title)
                    Spacer()
                    Text("by cost").font(Dash.label).foregroundStyle(Dash.dim)
                }
                .padding(.bottom, 4)
                if list.isEmpty {
                    Text(usage.loading ? "Reading your sessions…" : "No sessions in this range").font(.system(size: 13)).foregroundStyle(Dash.dim)
                }
                ForEach(list) { s in
                    let selected = shownSession(in: list) == s.id
                    Button { usage.selectedSession = s.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 13)).foregroundStyle(selected ? .white : Color.white.opacity(0.8)).lineLimit(1)
                                Text("\(Fmt.when(s.end, now: store.now)) · \(s.projectName)\(usage.sessionAccount(s).map { " · " + $0.name } ?? "")")
                                    .font(.system(size: 11)).foregroundStyle(Dash.faint).lineLimit(1)
                            }
                            Spacer()
                            Text(Dash.money(s.cost)).font(Dash.num(14)).foregroundStyle(selected ? Dash.claude : .white)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white.opacity(0.06) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(s.title)
                    .contextMenu {
                        // Resuming carries on under whichever account the terminal's Claude Code is signed in to,
                        // so say when that isn't the one the session ran under.
                        if let a = usage.sessionAccount(s), a.otherThanCLI == true {
                            Text("Ran on \(a.name); Claude Code in Terminal is signed in to \(a.cliName ?? "another account")")
                        }
                        Button(usage.sessionAccount(s).map { "Copy command to resume it (\($0.name))" } ?? "Copy command to resume it") {
                            copyToClipboard(Self.resumeCommand(project: s.project, session: s.id))
                        }
                        folderActions(s.project)
                    }
                }
            }
        }
    }

    private var sessionDetailCard: some View {
        let list = Array(usage.sessions.prefix(8))
        let s = list.first { $0.id == shownSession(in: list) }
        return GlowCard(glow: Dash.claude, glowAt: UnitPoint(x: 1, y: 0), glowSize: 220, glowOpacity: 0.3) {
            if let s {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(Dash.title).lineLimit(1)
                            Text([prettyModel(s.topModel), s.apiMillis.map { "\(Dash.duration($0)) of API time" }].compactMap { $0 }.joined(separator: " · "))
                                .font(Dash.label).foregroundStyle(Dash.dim)
                        }
                        Spacer()
                        Text(Dash.money(s.cost)).font(Dash.num(32, .light))
                    }
                    shareBar(s)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], spacing: 0) {
                        StatRow(label: "Output", value: Dash.tokens(s.output))
                        StatRow(label: "Cache read", value: Dash.tokens(s.cacheRead))
                        StatRow(label: "Cache write", value: Dash.tokens(s.cacheWrite))
                        StatRow(label: "Cache hit", value: String(format: "%.0f%%", s.cacheHit * 100))
                        StatRow(label: "Tool calls", value: "\(s.tools)")
                        StatRow(label: "MCP calls", value: "\(s.mcpCalls)")
                        StatRow(label: "Web searches", value: "\(s.webSearches)")
                        StatRow(label: "Subagent calls", value: "\(s.subagentCalls)")
                    }
                }
            } else {
                Text(list.isEmpty ? "No sessions in this range" : "Pick a session").foregroundStyle(Dash.dim)
            }
        }
    }

    /// The picked session while it's still listed, else the top one. A pick left over from another range or account
    /// used to leave nothing highlighted and the detail card blank.
    private func shownSession(in list: [SessionSummary]) -> String? {
        if let id = usage.selectedSession, list.contains(where: { $0.id == id }) { return id }
        return list.first?.id
    }

    // MARK: Projects

    @State private var renaming: String?
    @State private var draftName = ""

    private var projectsCard: some View {
        let list = Array(usage.projects.prefix(12))
        let maxCost = max(0.01, list.first?.cost ?? 1)
        return GlowCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CardHeader(title: "Projects", subtitle: "Click a name to rename it. Subfolders and worktrees count as one project.")
                    Spacer()
                    Text("\(usage.projects.count) projects \(rangePhrase)").font(Dash.label).foregroundStyle(Dash.dim)
                }
                .padding(.bottom, 8)
                ForEach(list) { p in
                    HStack(spacing: 14) {
                        Group {
                            if renaming == p.root {
                                TextField("Name", text: $draftName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                                    .onSubmit { ProjectNames.shared.rename(p.root, to: draftName); renaming = nil }
                                    .onExitCommand { renaming = nil }
                            } else {
                                Button {
                                    draftName = ProjectNames.shared.name(for: p.root); renaming = p.root
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ProjectNames.shared.name(for: p.root)).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
                                        Text(p.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(Dash.faint).lineLimit(1).truncationMode(.middle)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Rename")
                            }
                        }
                        .frame(width: 300, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.05))
                                Capsule().fill(Dash.claude.opacity(0.8)).frame(width: max(4, g.size.width * p.cost / maxCost))
                            }
                        }
                        .frame(height: 6)
                        Text("\(p.sessions) session\(p.sessions == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Dash.dim).frame(width: 70, alignment: .trailing)
                        Text(Dash.money(p.cost)).font(Dash.num(13)).frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Dash.line).frame(height: 1) }
                    .contentShape(Rectangle())
                    .contextMenu {
                        folderActions(p.root)
                        Button("Rename…") { draftName = ProjectNames.shared.name(for: p.root); renaming = p.root }
                    }
                }
            }
        }
    }

    /// Right-click actions for a project folder; rows could only be renamed or selected before.
    @ViewBuilder private func folderActions(_ path: String) -> some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            .disabled(!FileManager.default.fileExists(atPath: path))
        Button("Copy path") { copyToClipboard(path) }
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// The Terminal line that reopens a session where it was: its folder, then `claude --resume`.
    static func resumeCommand(project: String, session: String) -> String {
        "cd '\(project.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(session)"
    }

    private func shareBar(_ s: SessionSummary) -> some View {
        let total = max(0.0001, s.cost)
        var parts: [(String, Double, Color)] = [("Main", s.mainCost, Dash.claude), ("Subagents", s.subagentCost, Color(hex: 0xFFC98F))]
        let palette = [Dash.blue, Dash.violet, Dash.green, Color(hex: 0xFF5C7A)]
        for (i, (k, v)) in s.mcpCost.sorted(by: { $0.value > $1.value }).prefix(4).enumerated() { parts.append((k, v, palette[i % palette.count])) }
        parts = parts.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("What used the window").font(Dash.label).foregroundStyle(Dash.dim)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].2).frame(width: max(2, (g.size.width - CGFloat(parts.count - 1) * 2) * parts[i].1 / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(parts.indices, id: \.self) { i in
                    Text("\(parts[i].0) \(Int((parts[i].1 / total * 100).rounded()))%")
                        .font(.system(size: 11)).foregroundStyle(i == 0 ? Color.white.opacity(0.85) : Dash.dim).lineLimit(1)
                }
            }
        }
    }

    private func prettyModel(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let fam = parts.first else { return id }
        let ver = parts.dropFirst().prefix(2).filter { $0.count <= 2 }.joined(separator: ".")
        return fam.prefix(1).uppercased() + fam.dropFirst() + (ver.isEmpty ? "" : " \(ver)")
    }
}
