import AppKit
import SwiftUI
import Foundation
import Observation
import ServiceManagement
import WidgetKit
import UserNotifications

/// Per-provider switches, saved in UserDefaults.
struct ProviderPrefs: Codable, Equatable {
    var enabled = true
    var alert = true
    var autoStart = false
}

@Observable
final class Store {
    private(set) var statuses: [WindowStatus] = []
    private(set) var lastRefresh = Date.distantPast
    private(set) var log: [String] = []
    var now = Date()

    // Saved settings
    var prefs: [String: ProviderPrefs] { didSet { save(prefs, "prefs") } }
    var custom: [CustomProvider] { didSet { save(custom, "custom"); refresh() } }
    var claudeExtraStarts: [Date] { didSet { save(claudeExtraStarts, "claudeExtraStarts"); refresh() } }
    var leadMinutes: Int { didSet { UserDefaults.standard.set(leadMinutes, forKey: "leadMinutes"); scheduleAlertSync() } }
    var phoneEnabled: Bool { didSet { UserDefaults.standard.set(phoneEnabled, forKey: "phoneEnabled"); scheduleAlertSync() } }
    var ntfyServer: String { didSet { UserDefaults.standard.set(ntfyServer, forKey: "ntfyServer"); scheduleAlertSync() } }
    var ntfyTopic: String { didSet { UserDefaults.standard.set(ntfyTopic, forKey: "ntfyTopic"); scheduleAlertSync() } }
    var commands: [String: String] { didSet { save(commands, "commands") } }
    var liveClaudeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveClaudeEnabled, forKey: "liveClaude")
            if liveClaudeEnabled {
                note("Live Claude usage on")
                // Switching live usage off dropped the desktop app's key; get it back if that option is still on.
                if desktopAccountsEnabled { allowDesktop() }
            } else { liveClaude.reset(); dropDesktopLive() }
            refresh()
        }
    }
    /// Its schedule and last reading are saved, so restarts respect a "slow down" (demo mode never touches it).
    let liveClaude = LiveClaude(scheduleURL: Demo.isOn ? nil : LiveClaude.scheduleURL)
    /// Live usage for the Claude desktop app's other accounts too (see ClaudeDesktopSignIn). Only with live usage on.
    var desktopAccountsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(desktopAccountsEnabled, forKey: "liveClaudeDesktop")
            if desktopAccountsEnabled { allowDesktop() } else { dropDesktopLive(); refresh() }
        }
    }
    /// One per other account signed in to the desktop app, by organization.
    private var desktopLive: [String: LiveClaude] = [:]
    private(set) var desktopState: ClaudeDesktopSignIn.State = .off
    /// How many accounts are read through the desktop app, beyond the one Claude Code is signed in to.
    private(set) var desktopAccounts = 0
    /// Listed, but their sign-in has expired until the desktop app is opened and renews it.
    private(set) var desktopExpired = 0

    /// Reads the desktop app's key (macOS asks, unless it was told "Always Allow"), then rescans.
    func allowDesktop() {
        ClaudeDesktopSignIn.allow { [weak self] ok in
            self?.note(ok ? "Reading the Claude desktop app's accounts" : "No access to the Claude desktop app's sign-in")
            self?.refresh()
        }
    }

    private func dropDesktopLive() {
        desktopLive.values.forEach { $0.reset() }
        desktopLive = [:]
        desktopState = .off
        desktopAccounts = 0
        desktopExpired = 0
        ClaudeDesktopSignIn.forget()
    }
    /// Saved across restarts, except in demo mode, which mustn't touch real files.
    let forecast = Forecast(storeURL: Demo.isOn ? nil : Forecast.defaultURL)
    var look: Look = Look(rawValue: UserDefaults.standard.string(forKey: "look") ?? "") ?? .glow {
        didSet { UserDefaults.standard.set(look.rawValue, forKey: "look"); lastWidgetData = nil; writeWidgetSnapshot() }
    }
    /// Which limits the menu bar pill and the menu's rows show (Settings → Appearance).
    var limitsShown: MenuBarGlance.Limits = MenuBarGlance.Limits(rawValue: UserDefaults.standard.string(forKey: "limitsShown") ?? "") ?? .session {
        didSet { UserDefaults.standard.set(limitsShown.rawValue, forKey: "limitsShown") }
    }

    /// What a look card needs for one provider, with the mascot in its current mood.
    func cardData(for s: WindowStatus) -> CardData {
        let window = s.windowLength ?? WindowStatus.length(of: s.id)
        return CardData(id: s.id, name: s.name, color: Theme.color(for: s.id), windowStart: s.resetsAt?.addingTimeInterval(-window),
                        resetsAt: s.resetsAt, ready: s.state == .ready, blockedUntil: s.blockedUntil, used: s.usedPercent,
                        mascot: MascotArt.image(s.id, Mood.of(s, justReset: false)).map { Image(nsImage: $0) }, windowLength: window,
                        estimate: estimateNote(for: s))
    }

    /// "estimated · live usage off" and the like, or nil when the numbers are solid. Only Claude has a live
    /// source to fall back from; the others are exact from their own logs or plainly labelled as estimates.
    func estimateNote(for s: WindowStatus) -> String? {
        if s.id.hasPrefix("claude-") {
            // Read live through the desktop app: estimated only while that reading fails, and then it says why.
            if let live = desktopReading(for: s) {
                var problem: String?
                if case .problem(let p) = live.state { problem = p }
                return UsageAccuracy.desktopAccountNote(isEstimate: s.isEstimate, usageKnown: s.usedPercent != nil, problem: problem)
            }
            return UsageAccuracy.otherAccountNote(isEstimate: s.isEstimate, usageKnown: s.usedPercent != nil,
                                                  desktopOn: liveClaudeEnabled && desktopAccountsEnabled)
        }
        guard s.id == "claude" else { return nil }
        if case .unavailable = s.state { return nil }
        // Only a reported problem counts as not working; still loading is "waiting", not "unavailable".
        var working = true
        if case .problem = liveClaude.state { working = false }
        return UsageAccuracy.note(isEstimate: s.isEstimate, usageKnown: s.usedPercent != nil, liveEnabled: liveClaudeEnabled,
                                  liveWorking: working, needsSignIn: liveClaude.needsSignIn, expired: liveClaude.signInExpired)
    }

    let alerts = Alerts()
    let kicker = Kicker()
    let mascots = MascotController()
    let usage = UsageStore()
    let keepAwake = KeepAwake()
    let updater = Updater()
    let network = NetworkWatch()
    /// So "waiting for the network" is noted once per wait, not every second.
    private var notedOffline = false
    private var tick: Timer?
    private var lastScan = Date.distantPast
    private var scanning = false
    private var rescanQueued = false
    private let scanQueue = DispatchQueue(label: "reset.scan", qos: .utility)

    /// Auto-start bookkeeping (see AutoStartState), saved on every change so a restart picks up where it left off.
    private var auto = AutoStartState.load(from: AutoStartState.url) {
        didSet { if auto != oldValue, !Demo.isOn { auto.save(to: autoURL) } }
    }
    /// Where the state is saved; tests point this at a temporary file so they never touch the real one.
    var autoURL = AutoStartState.url

    init() {
        let d = UserDefaults.standard
        prefs = Self.load("prefs") ?? [:]
        custom = Self.load("custom") ?? []
        claudeExtraStarts = Self.load("claudeExtraStarts") ?? []
        leadMinutes = d.object(forKey: "leadMinutes") as? Int ?? 0
        phoneEnabled = d.bool(forKey: "phoneEnabled")
        ntfyServer = d.string(forKey: "ntfyServer") ?? "https://ntfy.sh"
        ntfyTopic = d.string(forKey: "ntfyTopic") ?? ""
        commands = Self.load("commands") ?? Kicker.defaultCommands()
        liveClaudeEnabled = d.bool(forKey: "liveClaude")
        desktopAccountsEnabled = d.bool(forKey: "liveClaudeDesktop")
        if prefs["antigravity"] == nil {
            let has = FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
            prefs["antigravity"] = ProviderPrefs(enabled: has, alert: has)
        }
        // Off until switched on: reading Cursor sends its sign-in to Cursor's servers (see CursorSource).
        if prefs["cursor"] == nil {
            prefs["cursor"] = ProviderPrefs(enabled: false, alert: false)
        }
        if prefs["gemini"] == nil {
            let hasGemini = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gemini")
            prefs["gemini"] = ProviderPrefs(enabled: hasGemini, alert: false)
        }
    }

    func start() {
        alerts.requestPermission()
        mascots.attach(self)
        keepAwake.start()
        updater.start()
        usage.start()
        CursorSource.onUpdate = { [weak self] in self?.cursorUpdated() }
        refresh()
        // The desktop app's key is kept in memory only, so it's read again each launch; scans never read it.
        if !Demo.isOn, liveClaudeEnabled && desktopAccountsEnabled { allowDesktop() }
        // A 1 s tick keeps the countdowns live; disk is rescanned every 60 s or on demand.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.onTick() }
        startListener = StartRequest.Listener(name: StartRequest.name("claude")) { [weak self] in self?.startFromWidget("claude") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.note("Mac woke up, rescanning")
            self?.refresh()
            // Wi-Fi is often still reconnecting right after wake; rescan again so phone pushes retry soon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.refresh() }
        }
    }

    private func onTick() {
        now = Date()
        let crossedReset = statuses.contains { s in s.resetsAt.map { $0 <= now } ?? false }
        if crossedReset || now.timeIntervalSince(lastScan) >= 60 { refresh() }
        if now.timeIntervalSince(lastStatusLine) >= 30 { writeStatusLine(); if !Demo.isOn { Heartbeat.beat() } }
        // The MCP server sets budgets from another process; a 5-second look keeps the dashboard current.
        if now.timeIntervalSince(lastBudgetLook) >= 5 { lastBudgetLook = now; reloadBudget() }
        runAutoStarts()
    }

    // MARK: Pacing budget

    /// The pacing budget an agent set through reset-mcp, if any. Read-only here apart from clearing it.
    private(set) var budget: Budget?
    private var lastBudgetLook = Date.distantPast
    /// Where the budget lives; tests point this at a temporary file so they never touch the real one.
    var budgetURL = Budget.url

    func reloadBudget() {
        let b = Demo.isOn ? Demo.budget : Budget.load(from: budgetURL)
        // Assigning an equal value would still wake every view observing it.
        guard b != budget else { return }
        budget = b
        // The terminal status line otherwise waits up to 30 s to show a budget an agent just set.
        writeStatusLine()
    }

    /// Window used % that budgets are judged against: 0 once a fresh window is ready, nil when unknown.
    var budgetUsed: Double? {
        guard let c = budgetEntry else { return nil }
        return c.state == .ready ? 0 : c.usedPercent
    }

    /// The account the budget is judged on: the one whose agent set it, else the terminal's.
    var budgetEntry: WindowStatus? {
        budget?.org.flatMap { org in statuses.first { $0.account == org && ($0.id == "claude" || $0.id.hasPrefix("claude-")) } }
            ?? statuses.first { $0.id == "claude" }
    }

    func clearBudget() {
        // Demo mode never touches the real file; its made-up budget simply comes back on the next look.
        if !Demo.isOn { Budget.clear(at: budgetURL) }
        budget = nil
        writeStatusLine()
        note("Pacing budget cleared")
    }

    func prefs(for id: String) -> ProviderPrefs { prefs[id] ?? ProviderPrefs() }

    func setPrefs(_ id: String, _ update: (inout ProviderPrefs) -> Void) {
        var p = prefs(for: id)
        let wasAuto = p.autoStart, wasEnabled = p.enabled
        update(&p)
        prefs[id] = p
        mascots.sync()
        if p.autoStart && !wasAuto { auto.armedAt[id] = Date(); auto.kickDue[id] = nil }
        syncAlerts()
        // Cursor only reads while it's on, so read it now rather than at the next scan.
        if id == "cursor", p.enabled, !wasEnabled { CursorSource.retrySoon(); refresh() }
    }

    /// A Cursor reading landed. Shown straight away, since a full scan can take a while, then rescanned so
    /// alerts and anything else that follows the statuses catch up.
    private func cursorUpdated() {
        if let i = statuses.firstIndex(where: { $0.id == "cursor" }) {
            statuses[i] = CursorSource(enabled: prefs(for: "cursor").enabled).read(now: Date())
        }
        refresh()
    }

    var visible: [WindowStatus] { statuses.filter { prefs(for: $0.id).enabled } }

    /// The Claude entry for the account you're using now (see ClaudeSource.activeOrg): the menu's top card and the
    /// menu bar follow it. "claude" stays the terminal's account, which live usage, auto-start and widgets go through.
    private(set) var activeClaudeId = "claude"

    /// Remembered across launches, so a restart doesn't put a different account on top.
    private func updateActiveClaude(_ list: [WindowStatus], configOrg: String?, now: Date) {
        let d = UserDefaults.standard
        let claudes = list.filter { $0.id == "claude" || $0.id.hasPrefix("claude-") }
        if let c = configOrg, c != d.string(forKey: "claudeConfigOrg") {
            // The first sighting isn't a switch, only a later change is.
            if d.string(forKey: "claudeConfigOrg") != nil { d.set(now, forKey: "claudeConfigChangedAt") }
            d.set(c, forKey: "claudeConfigOrg")
        }
        let current = d.string(forKey: "activeClaudeOrg")
        let lastUse = Dictionary(claudes.compactMap { s in s.account.flatMap { a in s.lastTaggedActivity.map { (a, $0) } } },
                                 uniquingKeysWith: max)
        let next = ClaudeSource.activeOrg(current: current, chosenAt: d.object(forKey: "activeClaudeChosenAt") as? Date,
                                          configOrg: configOrg, configChangedAt: d.object(forKey: "claudeConfigChangedAt") as? Date,
                                          listed: Set(claudes.compactMap(\.account)), lastUse: lastUse, now: now)
        if next != current {
            d.set(next, forKey: "activeClaudeOrg")
            d.set(now, forKey: "activeClaudeChosenAt")
        }
        let id = claudes.count > 1 ? claudes.first { $0.account != nil && $0.account == next }?.id ?? "claude" : "claude"
        if id != activeClaudeId { activeClaudeId = id; note("Top card follows \(claudes.first { $0.id == id }?.name ?? id)") }
    }

    /// The window that resets soonest, for the menu bar label.
    /// Providers you asked to be alerted about drive the menu bar; the rest only show in the menu.
    private var barCandidates: [WindowStatus] {
        let alerted = visible.filter { prefs(for: $0.id).alert }
        return alerted.isEmpty ? visible : alerted
    }

    /// The entry whose countdown the bar shows (see MenuBarGlance.pick).
    var soonest: WindowStatus? { MenuBarGlance.pick(barCandidates, main: activeClaudeId, now: now).soonest }

    /// A tracked provider whose longer (weekly) limit is used up, which the menu bar shows ahead of everything.
    var blockedForBar: WindowStatus? { MenuBarGlance.pick(barCandidates, main: activeClaudeId, now: now).blocked }

    /// When Claude's window runs out at today's pace, if that's still ahead and before its reset (see Forecast.current).
    var runsOut: Date? {
        guard liveClaudeEnabled else { return nil }
        return forecast.current(now: Date(), resetsAt: statuses.first { $0.id == "claude" }?.resetsAt)
    }

    /// A window to bring up ("dashboard"), set from outside any view (a notification click); MenuBarLabel opens it.
    var openRequest: String?

    /// What the menu bar shows right now (see MenuBarGlance).
    var glance: MenuBarGlance? {
        let p = MenuBarGlance.pick(barCandidates, main: activeClaudeId, now: now)
        return MenuBarGlance.make(ready: p.ready, soonest: p.soonest, blocked: p.blocked, runsOutAt: runsOut,
                                  signedOut: liveNeedsSignIn, limits: limitsShown, now: now)
    }

    /// A tracked provider with a fresh window waiting, shown in the bar ahead of any countdown.
    var readyForBar: WindowStatus? { MenuBarGlance.pick(barCandidates, main: activeClaudeId, now: now).ready }

    func refresh() {
        lastScan = Date()
        if Demo.isOn {
            statuses = [Demo.claude()]
            reloadBudget()
            lastRefresh = Date()
            now = Date()
            mascots.sync()
            // `-renderMenu` works in demo mode too, for screenshots with made-up numbers (after the usage loads).
            if let path = UserDefaults.standard.string(forKey: "renderMenu"), !renderedMenu {
                renderedMenu = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    let r = ImageRenderer(content: MenuView(store: self)); r.scale = 2
                    if let img = r.nsImage, let t = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            return
        }
        // One scan at a time; a request during a scan runs once more afterwards with fresh inputs.
        guard !scanning else { rescanQueued = true; return }
        scanning = true
        let extras = claudeExtraStarts
        let custom = self.custom
        let signIn = liveClaudeEnabled ? liveClaude.tokenAccount : nil
        let desktopOn = liveClaudeEnabled && desktopAccountsEnabled
        let cursorOn = prefs(for: "cursor").enabled
        scanQueue.async { [weak self] in
            let t = Date()
            let cli = ClaudeCLI.resolve(signIn: signIn, status: ClaudeCLI.account(now: t))
            let configOrg = ClaudeCLI.configOrg()
            // Only the organizations and plans leave this queue; the tokens are read again for each fetch.
            let desktop = desktopOn ? ClaudeDesktopSignIn.read(now: t) : (state: .off, accounts: [:])
            let desktopState = desktop.state
            let desktopPlans = desktop.accounts.filter { $0.key != cli?.orgId }.mapValues(\.plan)
            let desktopUsable = Set(desktop.accounts.filter { ClaudeDesktopSignIn.usable($0.value, now: t) }.keys)
            // One Claude entry per account (see ClaudeSource.readAll), then the other tools.
            var list = ClaudeSource(extraStarts: extras).readAll(now: t, account: cli, desktop: desktopPlans)
            list += [
                CodexSource().read(now: t),
                GeminiSource().read(now: t),
                AntigravitySource().read(now: t),
                CursorSource(enabled: cursorOn).read(now: t),
            ]
            list += custom.map { $0.status(now: t) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                var list = list
                if self.liveClaudeEnabled, let i = list.firstIndex(where: { $0.id == "claude" }) {
                    self.liveClaude.apply(to: &list[i], now: Date())
                    self.liveClaude.poll(interval: LiveClaude.interval(lastActivity: list[i].lastActivity)) { [weak self] in self?.refresh() }
                    if !list[i].isEstimate, let u = list[i].usedPercent {
                        self.forecast.record(used: u, resetsAt: list[i].resetsAt)
                        self.warnIfRunningOut(list[i])
                    }
                }
                // Checked again here: the option may have been turned off while this scan ran.
                if desktopOn, self.liveClaudeEnabled, self.desktopAccountsEnabled {
                    self.desktopState = desktopState
                    var liveCount = 0, expired = 0
                    for org in desktopPlans.keys {
                        guard let i = list.firstIndex(where: { $0.id == "claude-" + org.prefix(8) }) else { continue }
                        let live = self.desktopLive[org] ?? LiveClaude(scheduleURL: LiveClaude.scheduleURL(org: org), source: .desktop(org: org))
                        self.desktopLive[org] = live
                        live.apply(to: &list[i], now: Date())
                        live.poll(interval: LiveClaude.interval(lastActivity: list[i].lastActivity)) { [weak self] in self?.refresh() }
                        if desktopUsable.contains(org) { liveCount += 1 } else { expired += 1 }
                    }
                    self.desktopAccounts = liveCount
                    self.desktopExpired = expired
                }
                // Every account's weekly limit, not only the CLI's: here Team has none, and Pro's reached 90% unwarned.
                for s in list where s.id == "claude" || s.id.hasPrefix("claude-") {
                    if let sec = s.secondary { self.warnIfWeeklyHigh(s.id, s.name, sec) }
                }
                self.statuses = list
                self.updateActiveClaude(list, configOrg: configOrg, now: t)
                self.usage.accounts = list.filter { $0.id == "claude" || $0.id.hasPrefix("claude-") }.map { ($0.id, $0.name, $0.account) }
                if self.usage.signedInOrg != cli?.orgId { self.usage.signedInOrg = cli?.orgId }
                self.lastRefresh = t
                self.reloadBudget()
                self.checkCLISignInIfNeeded()
                self.now = Date()
                self.trackResets()
                self.writeWidgetSnapshot()
                self.writeStatusLine()
                self.mascots.sync()
                self.syncAlerts()
                self.runAutoStarts()
                if self.rescanQueued { self.rescanQueued = false; self.refresh() }
                if let path = UserDefaults.standard.string(forKey: "selfTest"), !self.wroteSelfTest {
                    self.wroteSelfTest = true
                    // Give live usage, the update check and the usage scan a moment to land first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.writeSelfTest(to: path) }
                }
                // Test hook: `--args -renderOnboarding /dir` renders every setup step once.
                if let dir = UserDefaults.standard.string(forKey: "renderOnboarding"), !self.renderedOnboarding {
                    self.renderedOnboarding = true
                    for s in OnboardingView.Step.allCases {
                        let r = ImageRenderer(content: OnboardingView(store: self, startAt: s) {}); r.scale = 2
                        if let img = r.nsImage, let t = img.tiffRepresentation,
                           let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("step-\(s.rawValue).png"))
                        }
                    }
                }
                // Test hook: `--args -renderMenu /path/menu.png` renders the menu panel once.
                if let path = UserDefaults.standard.string(forKey: "renderMenu"), !self.renderedMenu {
                    self.renderedMenu = true
                    let r = ImageRenderer(content: MenuView(store: self)); r.scale = 2
                    if let img = r.nsImage, let t = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    private var pendingAlertSync: DispatchWorkItem?

    /// Settings fields change on every keystroke; wait for a 0.5 s pause so typing a topic causes one
    /// sync (and at most one ntfy withdraw or repost) instead of one per character.
    private func scheduleAlertSync() {
        pendingAlertSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncAlerts() }
        pendingAlertSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func syncAlerts() {
        let targets = visible.filter { prefs(for: $0.id).alert }
        let startable = Set(visible.filter { $0.canAutoStart && !(commands[$0.id] ?? "").isEmpty }.map(\.id))
        let autoStarting = startable.filter { prefs(for: $0).enabled && prefs(for: $0).autoStart }
        alerts.sync(targets, leadMinutes: leadMinutes, autoStarting: autoStarting, startable: startable)
        alerts.syncPhone(targets, server: ntfyServer, topic: ntfyTopic, enabled: phoneEnabled, log: note)
    }

    /// Remembers each provider's reset time while a window runs, and marks a kick as due once that time
    /// passes with auto-start on. A new window (from you or from a kick) clears it.
    private func trackResets() {
        auto.track(statuses, now: Date()) { s in
            let p = prefs(for: s.id)
            return s.canAutoStart && p.enabled && p.autoStart
        }
    }

    private func runAutoStarts() {
        let t = Date()
        for (id, due) in auto.kickDue {
            guard let s = statuses.first(where: { $0.id == id }), prefs(for: id).autoStart,
                  let cmd = commands[id], !cmd.isEmpty else { auto.kickDue[id] = nil; continue }
            if let b = s.blockedUntil, b > t {
                note("\(s.name): \(s.secondary?.label ?? "longer") limit still exhausted, not auto-starting")
                auto.kickDue[id] = nil
                continue
            }
            // Two minutes of slack past the reset, so a slightly early estimate does not burn a kick.
            guard s.state == .ready, t >= due.reset.addingTimeInterval(120) else { continue }
            // Offline, a run can only time out; wait for the network without spending one of the 4 tries.
            guard network.isOnline else {
                if !notedOffline { notedOffline = true; note("\(s.name): auto-start waiting for the network") }
                continue
            }
            notedOffline = false
            guard due.attempts < 4 else {
                auto.kickDue[id] = nil
                note("\(s.name): auto-start gave up after 4 tries")
                let last = kickLog.last { $0.id == id }?.summary ?? "it kept failing"
                warnAutoStart(id, title: "Auto-start couldn't start \(s.name)",
                              body: "Gave up after 4 tries: \(last). Send a message to start the window yourself.")
                continue
            }
            kicker.kick(id, name: s.name, command: cmd, log: note) { [weak self] outcome in
                guard let self else { return }
                self.recordKick(id, outcome)
                switch outcome {
                case .started:
                    self.auto.kickDue[id] = nil
                case .signedOut:
                    // Retrying signed out only burns attempts; wait for a sign-in instead.
                    self.auto.kickDue[id] = nil
                    self.auto.pausedKick[id] = due.reset
                    self.warnAutoStart(id, title: "Auto-start couldn't start \(s.name)",
                                       body: "Claude Code is signed out. Press Sign in; the window starts right after.", signIn: true)
                default:
                    if var d = self.auto.kickDue[id] { d.attempts += 1; self.auto.kickDue[id] = d }
                }
                self.refresh()
            }
        }
    }

    /// API value per day of the current month (index 0 is the 1st). Rows outside the month are skipped,
    /// including future-dated ones from a clock that runs behind the server, which used to index past the end.
    static func monthBuckets<C: Collection<Call>>(_ calls: C, monthStart: Date, daysInMonth: Int, calendar cal: Calendar) -> [Double] {
        var days = Array(repeating: 0.0, count: max(0, daysInMonth))
        for c in calls where c.time >= monthStart {
            guard let i = cal.dateComponents([.day], from: monthStart, to: c.time).day, i >= 0, i < days.count else { continue }
            days[i] += c.cost
        }
        return days
    }

    // MARK: Claude Code status line

    private var lastStatusLine = Date.distantPast

    /// One line for Claude Code's status bar, read with `cat` by a statusLine command.
    func writeStatusLine() {
        guard !Demo.isOn else { return }
        guard let c = statuses.first(where: { $0.id == "claude" }) else { return }
        lastStatusLine = Date()
        var parts: [String] = []
        switch c.state {
        case .ready: parts.append("Claude ready")
        case .unavailable: parts.append("Claude --")
        case .active(let end):
            var s = "Claude"
            if let u = c.usedPercent { s += " \(Int((100 - u).rounded()))% left" }
            s += " · \(Fmt.countdown(end.timeIntervalSince(Date()))) to \(Fmt.clock.string(from: end))"
            parts.append(s)
        }
        if let b = c.blockedUntil, b > Date() { parts.append("weekly limit until \(c.blockedEstimate ? "about " : "")\(Fmt.when(b))") }
        else if let sec = c.secondary, sec.isHigh, let u = sec.usedPercent { parts.append("wk \(Int(u.rounded()))%") }
        if let out = runsOut { parts.append("runs out ~\(Fmt.clock.string(from: out))") }
        if let b = budget { parts.append(b.tag(used: budgetUsed)) }
        let today = usage.todayCost
        if today > 0 { parts.append(String(format: "$%.0f today", today)) }
        let line = "◷ " + parts.joined(separator: " · ")
        let url = WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("statusline.txt")
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }

    /// On quit: the status line says so (even the older plain `cat` one), and the heartbeat stops.
    func markQuit() {
        guard !Demo.isOn else { return }
        Heartbeat.stop()
        usage.flushCache()
        let url = WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("statusline.txt")
        try? "◷ Reset isn't running".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Self-test

    /// Test hook: `-selfTest /path.json` writes Reset's internal state once, so every feature can be
    /// checked against what it is really doing, not what a label says.
    func writeSelfTest(to path: String) {
        let iso = ISO8601DateFormatter()
        func d(_ x: Date?) -> Any { x.map { iso.string(from: $0) } ?? NSNull() }
        var out: [String: Any] = [:]
        out["statuses"] = statuses.map { s -> [String: Any] in
            ["id": s.id, "enabled": prefs(for: s.id).enabled, "state": "\(s.state)", "used": s.usedPercent ?? NSNull(),
             "resetsAt": d(s.resetsAt), "estimate": s.isEstimate, "source": s.source, "blockedUntil": d(s.blockedUntil)]
        }
        out["live"] = ["enabled": liveClaudeEnabled, "state": "\(liveClaude.state)", "needsSignIn": liveClaude.needsSignIn,
                       "verifiedOrg": liveClaude.tokenAccount != nil]
        out["liveDesktop"] = ["enabled": desktopAccountsEnabled, "state": "\(desktopState)", "accounts": desktopAccounts, "expired": desktopExpired]
        out["forecast"] = d(forecast.runsOutAt)
        out["autoStart"] = ["claude": prefs(for: "claude").autoStart, "command": commands["claude"] ?? "",
                            "kickDue": auto.kickDue.mapValues { "\(iso.string(from: $0.reset)) tries \($0.attempts)" },
                            "watchingReset": auto.lastSeenReset.mapValues { iso.string(from: $0) }]
        out["phone"] = ["enabled": phoneEnabled, "topicSet": !ntfyTopic.isEmpty, "server": ntfyServer, "queued": alerts.queuedSummary]
        out["keepAwake"] = ["mode": keepAwake.mode.rawValue, "holding": keepAwake.isHolding, "onPower": keepAwake.onPower]
        out["mascots"] = ["enabled": mascots.enabled, "panels": mascots.panelCount, "placement": mascots.placement.rawValue]
        out["widgets"] = ["snapshotWritten": d(WidgetSnapshot.load()?.updated), "lastReload": d(lastWidgetReload == .distantPast ? nil : lastWidgetReload)]
        out["updater"] = ["automatic": updater.automatic, "lastChecked": d(updater.lastChecked), "available": updater.available?.version ?? NSNull(),
                          "error": updater.lastError ?? NSNull(), "current": Updater.current]
        out["usage"] = ["calls": usage.calls.count, "lastScan": d(usage.lastScan), "projects": usage.projects.count,
                        "planMonthly": usage.planMonthlyUSD, "planTotal": usage.totalPlanMonthly]
        out["autoStartLog"] = kickLog.suffix(5).map { ["id": $0.id, "time": iso.string(from: $0.time), "kind": $0.kind, "summary": $0.summary] }
        out["autoStartNeedsSignIn"] = autoStartNeedsSignIn
        out["activity"] = Array(log.prefix(10))
        let lastUse = statuses.first { $0.id == "claude" }?.lastActivity
        out["network"] = ["online": network.isOnline]
        let month = Date().addingTimeInterval(-30 * 86400)
        out["usageByAccount"] = Dictionary(uniqueKeysWithValues: usage.accounts.map { a in
            (a.name, (UsageStore.scope(usage.calls, accounts: usage.accounts, account: a.id).filter { $0.time >= month }.reduce(0) { $0 + $1.cost } * 100).rounded() / 100)
        })
        // All time per account, and the first response each one has, to check attribution against the transcripts.
        out["usageByAccountAllTime"] = Dictionary(uniqueKeysWithValues: usage.accounts.map { a in
            let mine = UsageStore.scope(usage.calls, accounts: usage.accounts, account: a.id)
            return (a.name, ["cost": (mine.reduce(0) { $0 + $1.cost } * 100).rounded() / 100, "responses": mine.count,
                             "first": d(mine.first?.time)] as [String: Any])
        })
        out["usageAllTime"] = ["cost": (usage.calls.reduce(0) { $0 + $1.cost } * 100).rounded() / 100, "responses": usage.calls.count]
        let hits = liveClaude.limitHits
        let dayAgo = Date().addingTimeInterval(-86400)
        out["livePolling"] = ["lastClaudeActivity": d(lastUse), "intervalSeconds": LiveClaude.interval(lastActivity: lastUse),
                              "slowDownsLast24h": hits.filter { $0.at > dayAgo }.count,
                              "slowDowns": hits.suffix(10).map { ["at": iso.string(from: $0.at), "retryAfter": $0.retryAfter.map { $0 as Any } ?? NSNull()] }]
        out["problemReport"] = problemReportURL().flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value } ?? NSNull()
        out["logFormat"] = ["verdict": usage.format.verdict.rawValue, "summary": usage.format.summary,
                            "checked": usage.format.checked, "lines": usage.format.lines, "problems": usage.format.problems]
        out["statusLine"] = (try? String(contentsOf: WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("statusline.txt"))) ?? NSNull()
        out["look"] = look.rawValue
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                out["macNotifications"] = ["authorized": settings.authorizationStatus == .authorized,
                                           "pending": reqs.map { r -> String in
                                               let when = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                                                   ?? (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                                               return "\(r.content.title) @ \(when.map { Fmt.when($0) } ?? "?")"
                                           }]
                if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    // MARK: Sign-in

    /// Live usage is on but blocked by Claude Code's sign-in.
    var liveNeedsSignIn: Bool { liveClaudeEnabled && liveClaude.needsSignIn }
    private(set) var signingIn = false

    func fixClaudeSignIn() {
        guard !signingIn else { return }
        signingIn = true
        note("Opening the browser to sign Claude Code in")
        ClaudeCLI.signIn { [weak self] ok in
            guard let self else { return }
            self.signingIn = false
            self.note(ok ? "Claude Code signed in" : "Claude Code sign-in didn't finish")
            // It may be a different account now; look again instead of trusting the cached one.
            if ok { ClaudeCLI.forgetAccount(); self.resumeAfterSignIn() }
            self.liveClaude.retryNow { [weak self] in self?.refresh() }
        }
    }

    // MARK: Auto-start log

    /// Every auto-start run and its outcome, newest last, saved so a failure overnight is still there in the
    /// morning (the Activity list is in memory only). Kept to the last 30 runs.
    private(set) var kickLog: [KickRecord] = Store.loadKickLog()

    struct KickRecord: Codable, Equatable {
        var id: String
        var time: Date
        var kind: String
        var summary: String
        var ok: Bool { kind == KickOutcome.started.kind || kind == Self.signedInKind }
        /// Not a run: marks that Claude Code was signed in again, which ends a signed-out warning.
        static let signedInKind = "signed_in"
    }

    private static var kickLogURL: URL { WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("kick-log.json") }

    private static func loadKickLog() -> [KickRecord] {
        guard let d = try? Data(contentsOf: kickLogURL) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([KickRecord].self, from: d)) ?? []
    }

    private func recordKick(_ id: String, _ outcome: KickOutcome) {
        appendKickRecord(KickRecord(id: id, time: Date(), kind: outcome.kind, summary: outcome.summary))
    }

    private func appendKickRecord(_ r: KickRecord) {
        kickLog = Array((kickLog + [r]).suffix(30))
        guard !Demo.isOn else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(kickLog) { try? d.write(to: Self.kickLogURL, options: .atomic) }
    }

    /// True while Claude's last auto-start failed for lack of a sign-in and nothing has fixed it since.
    var autoStartNeedsSignIn: Bool { Store.needsSignIn(kickLog, id: "claude") }

    static func needsSignIn(_ log: [KickRecord], id: String) -> Bool {
        log.last { $0.id == id }?.kind == KickOutcome.signedOut.kind
    }

    /// After a sign-in: clear the warning and, if the window is still waiting, run the paused kick now.
    private func resumeAfterSignIn() {
        guard Store.needsSignIn(kickLog, id: "claude") || auto.pausedKick["claude"] != nil else { return }
        appendKickRecord(KickRecord(id: "claude", time: Date(), kind: KickRecord.signedInKind, summary: "Claude Code signed in again"))
        if let r = auto.pausedKick.removeValue(forKey: "claude"),
           statuses.first(where: { $0.id == "claude" })?.state == .ready, prefs(for: "claude").autoStart {
            kicker.clearBackoff("claude")
            auto.kickDue["claude"] = .init(reset: r, attempts: 0)
        }
    }

    private var lastCLICheck = Date.distantPast
    private var cliSeenSignedOut = false

    /// While auto-start is waiting on a sign-in, look every 5 minutes for one done outside Reset
    /// (`claude auth login` in a terminal). Only a change from signed out to signed in counts: an expired
    /// token still reports "logged in", and acting on that would retry, fail, and warn again every 5 minutes.
    private func checkCLISignInIfNeeded() {
        guard autoStartNeedsSignIn, !Demo.isOn, Date().timeIntervalSince(lastCLICheck) >= 300 else { return }
        lastCLICheck = Date()
        ClaudeCLI.status { [weak self] st in
            guard let self else { return }
            if !st.signedIn { self.cliSeenSignedOut = true; return }
            guard self.cliSeenSignedOut else { return }
            self.cliSeenSignedOut = false
            self.note("Claude Code signed in again")
            self.resumeAfterSignIn()
        }
    }

    /// The pre-filled GitHub issue for Settings → Advanced → Report a problem. Built from on/off states and
    /// versions only; see ProblemReport for what is and isn't included.
    func problemReportURL() -> URL? {
        let claude = statuses.first { $0.id == "claude" }
        let live: String = {
            guard liveClaudeEnabled else { return "off" }
            switch liveClaude.state {
            case .ok: return "working"
            case .problem(let why): return "problem: \(why)"
            case .off, .loading: return "connecting"
            }
        }()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let facts = ProblemReport.Facts(
            resetVersion: Updater.current, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            macModel: ProblemReport.macModel,
            toolsOn: statuses.filter { prefs(for: $0.id).enabled && !$0.id.hasPrefix("custom-") }.map(\.name),
            liveUsage: live,
            claudeAccuracy: claude.flatMap { estimateNote(for: $0) } ?? (claude == nil ? "Claude off" : "solid"),
            logFormat: usage.format.verdict.rawValue,
            lastAutoStart: kickLog.last.map { "\($0.kind) (\($0.id))" } ?? "never",
            stayAwake: keepAwake.mode.label,
            phoneAlerts: phoneEnabled,
            widgetsSigned: ProblemReport.hasTeamSignature)
        return ProblemReport.url(repo: ResetInfo.repoURL, facts: facts)
    }

    /// Mac notification, plus a phone push when phone alerts are on, for an auto-start that needs you.
    /// One stable id per provider, so a second failure replaces the first.
    private func warnAutoStart(_ id: String, title: String, body: String, signIn: Bool = false) {
        alerts.notifyNow(title: title, body: body, id: "autostart-\(id)", category: signIn ? Alerts.Category.signIn : nil)
        if phoneEnabled { alerts.pushNow(title: title, body: body, server: ntfyServer, topic: ntfyTopic, log: note) }
    }

    // MARK: Forecast

    /// Mac notification plus an immediate phone push, once per window, when the limit is projected to arrive first.
    private func warnIfRunningOut(_ s: WindowStatus) {
        guard forecast.shouldWarn(), let out = forecast.runsOutAt, let reset = s.resetsAt else { return }
        let title = "\(s.name) will run out before it resets"
        let body = "At this pace you hit the limit around \(Fmt.clock.string(from: out)), \(Fmt.countdown(reset.timeIntervalSince(out))) before the \(Fmt.clock.string(from: reset)) reset."
        alerts.notifyNow(title: title, body: body)
        if phoneEnabled { alerts.pushNow(title: title, body: body, server: ntfyServer, topic: ntfyTopic, log: note) }
        note("Forecast: limit around \(Fmt.clock.string(from: out))")
    }

    /// When an entry's usage % was read: the live check's last good answer for Claude, else the source's own time.
    /// The desktop app's live reading for another Claude account, when Reset reads one for it.
    func desktopReading(for s: WindowStatus) -> LiveClaude? {
        guard s.id.hasPrefix("claude-"), liveClaudeEnabled, desktopAccountsEnabled, let org = s.account else { return nil }
        return desktopLive[org]
    }

    private func usageReadAt(_ s: WindowStatus) -> Date? {
        guard s.usedPercent != nil else { return nil }
        if s.id == "claude", liveClaudeEnabled, !s.isEstimate, let f = liveClaude.snapshot?.fetchedAt { return f }
        if !s.isEstimate, let f = desktopReading(for: s)?.snapshot?.fetchedAt { return f }
        return s.usageAsOf
    }

    private var liveProblemText: String? {
        if case .problem(let why) = liveClaude.state { return why }
        return nil
    }

    /// Once per weekly cycle, when the weekly limit passes 80%: by the time it's used up, a fresh 5-hour window
    /// no longer helps, and that was the first anyone heard of it.
    private func warnIfWeeklyHigh(_ id: String, _ name: String, _ sec: WindowStatus.Secondary) {
        guard sec.isHigh, (sec.usedPercent ?? 0) < 100, sec.resetsAt > Date() else { return }
        let key = Alerts.minuteKey(sec.resetsAt)
        // The reset time wobbles a little between readings; within an hour is the same cycle. One record per
        // account, so one account's warning doesn't silence another's.
        let defaultsKey = id == "claude" ? "weeklyWarnedFor" : "weeklyWarnedFor." + id
        let warned = UserDefaults.standard.integer(forKey: defaultsKey)
        guard abs(warned - key) > 60 else { return }
        UserDefaults.standard.set(key, forKey: defaultsKey)
        let title = "\(name): weekly limit \(Int((sec.usedPercent ?? 0).rounded()))% used"
        let body = "It resets \(Fmt.when(sec.resetsAt)). Once it's used up, new 5-hour windows won't help until then."
        alerts.notifyNow(title: title, body: body, id: "weekly-" + id)
        if phoneEnabled { alerts.pushNow(title: title, body: body, server: ntfyServer, topic: ntfyTopic, log: note) }
        note("Weekly limit at \(Int((sec.usedPercent ?? 0).rounded()))%")
    }

    // MARK: Widgets

    var lastWidgetData: Data?
    private var renderedMenu = false
    private var renderedOnboarding = false
    private var wroteSelfTest = false

    /// Writes what the desktop widgets show and asks WidgetKit to redraw, only when something changed.
    func writeWidgetSnapshot() {
        guard !Demo.isOn else { return }
        // Nothing here looks back more than a month, and since "All" means all time, every call on record is a lot to
        // walk on the main thread each minute; calls are in time order, so the month is found by binary search.
        let monthStartForSlice = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
        let recent = UsageStore.calls(usage.calls, since: min(Date().addingTimeInterval(-31 * 86400), monthStartForSlice))
        let week = recent.filter { $0.time >= Date().addingTimeInterval(-7 * 86400) }
        let weekCost = week.reduce(0) { $0 + $1.cost }
        let cr = week.reduce(0) { $0 + $1.cacheRead }, rest = week.reduce(0) { $0 + $1.input + $1.cw5 + $1.cw1h }
        // Each account's plan from its own first response, as the dashboard counts it.
        let plan = usage.planCost(since: Date().addingTimeInterval(-7 * 86400), account: nil)
        func provider(_ s: WindowStatus) -> WidgetSnapshot.Provider {
            var available = true
            if case .unavailable = s.state { available = false }
            return .init(id: s.id, name: s.name, resetsAt: s.resetsAt, ready: s.state == .ready, available: available,
                         used: s.usedPercent, blockedUntil: s.blockedUntil, estimate: estimateNote(for: s),
                         weeklyUsed: s.secondary?.usedPercent, weeklyResetsAt: s.secondary?.resetsAt,
                         usageAsOf: usageReadAt(s), liveFailingSince: s.id == "claude" && liveClaudeEnabled ? liveClaude.failingSince : desktopReading(for: s)?.failingSince,
                         liveProblem: s.id == "claude" && liveClaudeEnabled ? liveProblemText : desktopReading(for: s).flatMap { l in
                             if case .problem(let why) = l.state { return why } else { return nil } },
                         org: s.account, blockedEstimate: s.blockedEstimate ? true : nil)
        }
        let providers = visible.filter { MascotArt.providers.contains($0.id) }.map(provider)
        // 7 days: the week widget counts this week's windows from these (5 undercounted it); the barcode draws its own 5 rows.
        let windows = usage.windows(days: 7).map { WidgetSnapshot.Window(start: $0.start, end: $0.end, autoStart: $0.autoStart, hitLimit: $0.hitLimit) }
        var snap = WidgetSnapshot(updated: .distantPast, look: look, providers: providers, windows: windows, weekCost: weekCost,
                                  weekMultiple: plan > 0 ? weekCost / plan : nil,
                                  cacheHit: cr + rest > 0 ? Double(cr) / Double(cr + rest) : 0)
        let month = recent.filter { $0.time >= Date().addingTimeInterval(-30 * 86400) }
        let monthCost = month.reduce(0) { $0 + $1.cost }
        snap.monthCost = monthCost
        snap.claudeAccounts = statuses.filter { $0.id == "claude" || $0.id.hasPrefix("claude-") }.map(provider)
        let monthPlan = usage.planCost(since: Date().addingTimeInterval(-30 * 86400), account: nil)
        snap.monthMultiple = monthPlan > 0 ? monthCost / monthPlan : nil
        snap.monthCacheSaved = month.reduce(0) { acc, c in
            guard let p = Pricing.claude(c.model) else { return acc }
            return acc + Double(c.cacheRead) * (p.input - p.cacheRead) / 1_000_000
        }
        let mix = month.reduce(into: [0, 0, 0, 0]) { m, c in m[0] += c.cacheRead; m[1] += c.cw5 + c.cw1h; m[2] += c.output; m[3] += c.input + c.advisorTokens }
        snap.monthMix = mix
        snap.monthTokens = mix.reduce(0, +)
        let grid = usage.heatmap
        let gmax = grid.flatMap { $0 }.max() ?? 0
        snap.heatmap = gmax > 0 ? grid.map { $0.map { ($0 / gmax * 100).rounded() / 100 } } : grid
        var hours = Array(repeating: 0.0, count: 24)
        let cal = Calendar.current
        for c in recent where cal.isDateInToday(c.time) { hours[cal.component(.hour, from: c.time)] += Double(c.output) }
        let hmax = hours.max() ?? 0
        snap.today = hours.map { hmax > 0 ? ($0 / hmax * 100).rounded() / 100 : 0 }

        // Daily and hourly spend, projects, calendar.
        let today0 = cal.startOfDay(for: Date())
        var daily = Array(repeating: 0.0, count: 14)
        var hourT = Array(repeating: 0.0, count: 24), hourY = Array(repeating: 0.0, count: 24)
        var proj: [String: Double] = [:]
        // One name per folder rather than per call: naming runs regular expressions, and this loop sees every call.
        var names: [String: String] = [:]
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let daysInMonth = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        for c in recent {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: c.time), to: today0).day ?? 99
            if d >= 0 && d < 14 { daily[13 - d] += c.cost }
            if d == 0 { hourT[cal.component(.hour, from: c.time)] += c.cost }
            if d == 1 { hourY[cal.component(.hour, from: c.time)] += c.cost }
            if c.time >= Date().addingTimeInterval(-30 * 86400) {
                if names[c.project] == nil { names[c.project] = ProjectNames.shared.name(for: c.project) }
                proj[names[c.project]!, default: 0] += c.cost
            }
        }
        func cumulative(_ a: [Double]) -> [Double] { var s = 0.0; return a.map { s += $0; return (s * 100).rounded() / 100 } }
        snap.dailyCost = daily.map { ($0 * 100).rounded() / 100 }
        snap.todayCumulative = cumulative(hourT)
        snap.yesterdayCumulative = cumulative(hourY)
        snap.projects = proj.sorted { $0.value > $1.value }.prefix(6).map { .init(name: $0.key, cost: ($0.value * 100).rounded() / 100) }
        let mdays = Self.monthBuckets(recent, monthStart: monthStart, daysInMonth: daysInMonth, calendar: cal)
        snap.monthDays = mdays.map { ($0 * 100).rounded() / 100 }
        snap.claudeRunsOutAt = runsOut
        snap.startingAt = widgetStarting["claude"]
        snap.limitDays = Array(Set(usage.limitHits.filter { $0 >= monthStart }.map { cal.component(.day, from: $0) })).sorted()

        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let key = try? enc.encode(snap)
        guard key != lastWidgetData else { return }
        lastWidgetData = key
        snap.updated = Date()
        snap.save()
        // macOS gives each app a small daily budget of widget reloads (roughly 40 to 70). Asking on every
        // change got the widgets throttled and frozen on an old value, so only ask when something a widget
        // shows meaningfully changed: a state change, a 10% usage step, or 30 minutes since the last reload.
        let state = Self.widgetState(snap.providers, runsOutAt: snap.claudeRunsOutAt)
        let stale = Date().timeIntervalSince(lastWidgetReload) > 30 * 60
        if state != lastWidgetState || stale {
            lastWidgetState = state
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var lastWidgetState = ""
    private var lastWidgetReload = Date.distantPast

    /// What a widget's look depends on, coarsely: reset time, ready or blocked, usage in 10% steps,
    /// and the mascot's mood (its 35% and 70% thresholds fall between steps).
    /// The run-out forecast is part of it so the fuse widget's flag appears and moves; rounded to 10 minutes,
    /// because the projection shifts a little on every reading and each reload spends the daily budget.
    static func widgetState(_ providers: [WidgetSnapshot.Provider], runsOutAt: Date? = nil) -> String {
        let out = runsOutAt.map { "out:\(Int($0.timeIntervalSince1970 / 600))" } ?? "out:-"
        return out + "|" + providers.map { p in
            let step = p.used.map { Int($0 / 10) }.map(String.init) ?? "-"
            let mood = p.used.map { $0 >= 99.5 ? "asleep" : $0 >= 70 ? "tired" : $0 >= 35 ? "focused" : "fresh" } ?? "-"
            let reset = p.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
            let blocked = p.blockedUntil.map { $0 > Date() } ?? false
            return "\(p.id):\(reset):\(p.ready):\(blocked):\(step):\(mood):\(p.available)"
        }.joined(separator: "|")
    }

    // MARK: User actions

    /// "I just used Claude on the web or desktop chat": opens a window now if none is running.
    func markClaudeUsedElsewhere() {
        claudeExtraStarts = (claudeExtraStarts + [Date()]).filter { $0 > Date().addingTimeInterval(-36000) }
    }

    func startCustom(_ id: String) {
        guard let i = custom.firstIndex(where: { "custom-" + $0.id == id }) else { return }
        custom[i].startedAt = Date()
    }

    func clearCustom(_ id: String) {
        guard let i = custom.firstIndex(where: { "custom-" + $0.id == id }) else { return }
        custom[i].startedAt = nil
    }

    func sendTestPush(result: @escaping (String) -> Void = { _ in }) {
        alerts.sendTest(server: ntfyServer, topic: ntfyTopic, log: note, result: result)
    }

    // MARK: Start now, from a widget

    private var startListener: StartRequest.Listener?
    /// When a widget's "Start now" began a start, so the widget can say "Starting…" until it's done.
    private var widgetStarting: [String: Date] = [:]

    /// Any process on the Mac can post the request's name, so it only ever starts a window when one is
    /// actually waiting: at most one start per window, never a second while a window runs.
    static func shouldStartFromWidget(_ s: WindowStatus?, command: String?, kicking: Bool, demo: Bool, now: Date = Date()) -> Bool {
        widgetStartBlocker(s, command: command, kicking: kicking, demo: demo, now: now) == nil
    }

    /// Why Start now can't start, in words for the Activity log; nil when it can. Every refusal used to be logged
    /// as "already starting" or "a window is already running", even with no start command set.
    static func widgetStartBlocker(_ s: WindowStatus?, command: String?, kicking: Bool, demo: Bool, now: Date = Date()) -> String? {
        if demo { return "demo mode" }
        guard let s else { return "Claude isn't being tracked" }
        if kicking { return "already starting" }
        if let b = s.blockedUntil, b > now { return "the weekly limit is used up until \(Fmt.when(b, now: now))" }
        if s.state != .ready { return "a window is already running" }
        if (command ?? "").isEmpty { return "no start command is set (Settings → Advanced)" }
        return nil
    }

    /// `from` says where the press came from, for the Activity log.
    func startFromWidget(_ id: String, from: String = "a widget") {
        let s = statuses.first { $0.id == id }
        guard network.isOnline else {
            note("Start now from \(from): no network, try again once you're online")
            return
        }
        // A marker older than a run's limit is left over from a start that never reported back; ignore it.
        let kicking = widgetStarting[id].map { Date().timeIntervalSince($0) < 240 } ?? false
        if let why = Self.widgetStartBlocker(s, command: commands[id], kicking: kicking, demo: Demo.isOn) {
            note("Start now from \(from) ignored: \(why)")
            return
        }
        note("Start now pressed in \(from)")
        widgetStarting[id] = Date()
        writeWidgetSnapshot()
        // A button press is worth one reload of its own, so "Starting…" shows at once.
        WidgetCenter.shared.reloadAllTimelines()
        kickNow(id)
    }

    func kickNow(_ id: String) {
        guard let cmd = commands[id], let s = statuses.first(where: { $0.id == id }) else { widgetStarting[id] = nil; return }
        kicker.kick(id, name: s.name, command: cmd, force: true, log: note) { [weak self] outcome in
            guard let self else { return }
            self.widgetStarting[id] = nil
            // A start you asked for gets the same record and sign-in handling as an automatic one.
            self.recordKick(id, outcome)
            if outcome == .signedOut {
                self.warnAutoStart(id, title: "Couldn't start \(s.name)", body: "Claude Code is signed out. Press Sign in, then try again.", signIn: true)
            }
            self.refresh()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { note("Launch at login failed: \(error.localizedDescription)") }
        }
    }

    func note(_ s: String) {
        let line = "\(Fmt.clock.string(from: Date()))  \(s)"
        DispatchQueue.main.async { self.log = Array(([line] + self.log).prefix(40)) }
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ v: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
