import AppKit
import SwiftUI
import Foundation
import Observation

enum UsageRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All"
    var id: String { rawValue }
    func start(now: Date) -> Date {
        switch self {
        case .today: return Calendar.current.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86400)
        case .month: return now.addingTimeInterval(-30 * 86400)
        // Everything on disk. It was the last 35 days, which read as "all time" and wasn't.
        case .all: return .distantPast
        }
    }
    /// For the value multiple: how many days of plan price this range covers. All time runs from the first
    /// response on record (`first`), since there's no fixed start.
    func days(now: Date, first: Date? = nil) -> Double {
        let from = self == .all ? (first ?? now) : start(now: now)
        return max(1 / 24, now.timeIntervalSince(from) / 86400)
    }
}

struct SessionSummary: Identifiable {
    var id: String
    /// The session's own title, when it has one; otherwise it goes by its project's name, which can be renamed.
    var sessionTitle: String?
    var title: String { sessionTitle ?? projectName }
    var project: String
    /// The Claude organization (account) the session ran under, when its transcript says.
    var org: String?
    var projectName: String { ProjectNames.shared.name(for: project) }
    var start: Date
    var end: Date
    var cost: Double
    var input = 0, cacheWrite = 0, cacheRead = 0, output = 0
    var tools = 0, mcpCalls = 0, webSearches = 0
    var apiMillis: Int?
    var modelCost: [String: Double] = [:]
    /// Where the cost went: main thread, subagents, and each MCP server's calls.
    var mainCost = 0.0, subagentCost = 0.0
    var mcpCost: [String: Double] = [:]
    var subagentCalls = 0

    var topModel: String { modelCost.max { $0.value < $1.value }?.key ?? "" }
    var cacheHit: Double {
        let denom = Double(input + cacheWrite + cacheRead)
        return denom > 0 ? Double(cacheRead) / denom : 0
    }
}

struct UsageWindow: Identifiable {
    /// Two accounts' windows can start in the same 10 minutes, so the account is part of the id.
    var id: String { "\(start.timeIntervalSince1970)-\(account)" }
    var start: Date
    var end: Date
    var autoStart: Bool
    var hitLimit: Bool
    /// The account whose window it is ("" when its sessions never said).
    var account = ""
}

@Observable
final class UsageStore {
    /// The "When you build" heatmap covers this many days, so a habit from months ago doesn't outweigh this month's.
    static let heatmapDays: Double = 35

    private(set) var calls: [Call] = []
    private(set) var titles: [String: String] = [:]
    private(set) var limitHits: [Date] = []
    /// Exact 5-hour resets from "limit reached" rows, with their account.
    private(set) var limitResets: [ClaudeUsageScanner.LimitReset] = []
    private(set) var apiMillis: [String: Int] = [:]
    /// Whether Claude Code's recent logs still read cleanly; Settings warns when they don't.
    private(set) var format = ClaudeUsageScanner.FormatReport()

    /// Test hook: `-simulateLogFormat problems` or `-simulateLogFormat no_rows` shows the log-format warning
    /// with made-up numbers, so it can be seen without breaking a real transcript.
    static var simulatedFormat: ClaudeUsageScanner.FormatReport? {
        simulatedFormat(UserDefaults.standard.string(forKey: "simulateLogFormat"))
    }

    static func simulatedFormat(_ kind: String?) -> ClaudeUsageScanner.FormatReport? {
        switch kind {
        case "problems":
            return .init(verdict: .problems, lines: 5200, checked: 1310, problems: ["no_timestamp": 1290, "usage_shape": 20], version: "3.0.0")
        case "no_rows":
            return .init(verdict: .noRows, lines: 4800, checked: 0, problems: [:], version: "3.0.0")
        default:
            return nil
        }
    }
    private(set) var loading = false
    /// Files parsed so far in the current scan, for the first-launch progress message.
    private(set) var filesRead = 0
    private(set) var lastScan: Date?
    var range: UsageRange = UsageRange(rawValue: UserDefaults.standard.string(forKey: "usageRange") ?? "") ?? .month {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "usageRange"); inputs += 1 }
    }
    var selectedSession: String?
    /// Set from the menu's Share button; the dashboard opens the share sheet when it sees it.
    var shareRequested = false
    /// What the main account's plan costs per month (the only price before accounts were told apart, so a price
    /// set back then stays with it).
    var planMonthlyUSD: Double { didSet { UserDefaults.standard.set(planMonthlyUSD, forKey: "planMonthlyUSD") } }
    /// Other accounts' monthly prices, by status id ("claude-<org>").
    var otherPlansUSD: [String: Double] = UserDefaults.standard.dictionary(forKey: "planMonthlyByAccount") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(otherPlansUSD, forKey: "planMonthlyByAccount") }
    }

    private let scanner = ClaudeUsageScanner()
    private let queue = DispatchQueue(label: "reset.usage", qos: .utility)
    private var timer: Timer?

    init() {
        planMonthlyUSD = UserDefaults.standard.double(forKey: "planMonthlyUSD")
    }

    /// Saves the transcript cache on quit. It waits at most `timeout`, so a scan still running (the first one after
    /// launch can take half a minute) never holds up quitting; that scan's work is then simply redone next time.
    func flushCache(timeout: TimeInterval = 5) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [scanner] in scanner.saveIfNeeded(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        if Demo.isOn {
            let d = Demo.calls()
            load(calls: d.calls, titles: d.titles, limitHits: d.limitHits, apiMillis: d.api)
            lastScan = Date()
            if let path = UserDefaults.standard.string(forKey: "renderShareCard") {
                DispatchQueue.main.async {
                    if let img = ShareSheet.render(ShareSheet.model(self, mascot: true)), let t = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            // Test hook: `-renderDashboard /path.png` writes the whole dashboard once (`-renderWidth 1120` for the narrowest window).
            if let path = UserDefaults.standard.string(forKey: "renderDashboard") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let width = UserDefaults.standard.double(forKey: "renderWidth")
                    let v = DashboardView(store: Store.shared, usage: self, flat: true).frame(width: width > 0 ? width : 1240)
                    let r = ImageRenderer(content: v); r.scale = 2
                    if let img = r.nsImage, let t = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            return
        }
        guard !loading else { return }
        loading = true
        filesRead = 0
        scanner.progress = { [weak self] n in DispatchQueue.main.async { self?.filesRead = n } }
        // Every transcript on disk, so "All" is all time. Files the cache already holds aren't re-read.
        let since = Date.distantPast
        queue.async { [weak self] in
            guard let self else { return }
            let r = self.scanner.scan(since: since)
            DispatchQueue.main.async {
                self.load(calls: r.calls, titles: r.titles, limitHits: r.limitHits, apiMillis: r.apiMillis, resets: r.resets)
                self.format = Self.simulatedFormat ?? r.format
                self.loading = false
                self.lastScan = Date()
                // Test hook: `--args -renderShareCard /path/card.png` writes the current card once.
                if let path = UserDefaults.standard.string(forKey: "renderShareCard"),
                   let img = ShareSheet.render(ShareSheet.model(self, mascot: true)),
                   let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Takes a scan's results (or demo mode's, or a test's).
    func load(calls: [Call], titles: [String: String] = [:], limitHits: [Date] = [], apiMillis: [String: Int] = [:],
              resets: [ClaudeUsageScanner.LimitReset] = []) {
        self.calls = calls
        self.titles = titles
        self.limitHits = limitHits
        self.limitResets = resets
        self.apiMillis = apiMillis
        inputs += 1
    }

    // MARK: Aggregates for the selected range

    /// Bumped whenever anything the aggregates below are worked out from changes.
    private var inputs = 0
    /// Aggregates already worked out, by name, for `inputs` and the minute they were worked out in (ranges end
    /// now). The dashboard redraws every second for its countdowns, and worked each of them out again over every
    /// call in the range, some twice, which kept the main thread busy for most of every second.
    @ObservationIgnored private var memo: (inputs: Int, minute: Int, values: [String: Any]) = (-1, 0, [:])

    private func memoized<T>(_ name: String, _ make: () -> T) -> T {
        // Reading `inputs` here is what makes a view showing a remembered value redraw when it changes.
        let minute = Int(Date().timeIntervalSinceReferenceDate / 60)
        if memo.inputs != inputs || memo.minute != minute { memo = (inputs, minute, [:]) }
        if let v = memo.values[name] as? T { return v }
        let v = make()
        memo.values[name] = v
        return v
    }

    // MARK: Account filter (dashboard and share card only; widgets and the menu always see every account)

    /// Claude accounts to choose from: the status id ("claude", "claude-<org>"), its name, and its org.
    /// Set by the store after each scan; one entry means there's nothing to choose.
    var accounts: [(id: String, name: String, org: String?)] = [] {
        // Set after every 60-second rescan, usually to the same accounts.
        didSet { if !oldValue.elementsEqual(accounts, by: { $0 == $1 }) { inputs += 1 } }
    }

    /// The account the Claude Code CLI is signed in to, when `claude auth status` said; nil when it couldn't be asked.
    var signedInOrg: String?

    /// Which account a session ran under, by name, for anyone with more than one. `otherThanCLI` is whether that's
    /// not the account Claude Code is signed in to: its resume command would then carry on under the wrong account,
    /// so the menu says so. Nil when there's nothing worth saying: one account, or a transcript that doesn't name its
    /// org (a guessed label would be worse than none). `otherThanCLI` is nil when the CLI's account isn't known,
    /// since the main entry is then only the most recently used account, not a sign-in.
    static func sessionAccount(org: String?, accounts: [(id: String, name: String, org: String?)],
                               signedIn: String?) -> (name: String, otherThanCLI: Bool?, cliName: String?)? {
        guard accounts.count > 1, let org, let entry = accounts.first(where: { $0.org == org }) else { return nil }
        let cliName = signedIn.flatMap { s in accounts.first { $0.org == s } }.map { shortName($0.name) }
        return (shortName(entry.name), signedIn.map { $0 != org }, cliName)
    }

    /// "Claude · Work" → "Work".
    static func shortName(_ name: String) -> String {
        name.hasPrefix("Claude · ") ? String(name.dropFirst("Claude · ".count)) : name
    }

    func sessionAccount(_ s: SessionSummary) -> (name: String, otherThanCLI: Bool?, cliName: String?)? {
        Self.sessionAccount(org: s.org, accounts: accounts, signedIn: signedInOrg)
    }

    /// The chosen account's status id, or nil for all of them.
    var account: String? = UserDefaults.standard.string(forKey: "usageAccount") {
        didSet { UserDefaults.standard.set(account, forKey: "usageAccount"); inputs += 1 }
    }

    /// Calls for the chosen account. The main account ("claude") also gets calls with no org or an org that
    /// isn't one of the others (older transcripts), so nothing goes missing from "All" minus the others.
    var scoped: [Call] { memoized("scoped") { Self.scope(calls, accounts: accounts, account: account) } }

    static func scope(_ calls: [Call], accounts: [(id: String, name: String, org: String?)], account: String?) -> [Call] {
        guard let id = account, accounts.count > 1, let entry = accounts.first(where: { $0.id == id }) else { return calls }
        let others = Set(accounts.filter { $0.id != "claude" }.compactMap(\.org))
        if id == "claude" { return calls.filter { $0.org.map { !others.contains($0) } ?? true } }
        return calls.filter { $0.org == entry.org }
    }

    var inRange: [Call] {
        memoized("inRange") {
            let s = range.start(now: Date())
            return scoped.filter { $0.time >= s }
        }
    }

    var totalCost: Double { memoized("totalCost") { inRange.reduce(0) { $0 + $1.cost } } }

    /// Every account's spend today and over the last 7 days, for the menu and Claude Code's status line.
    var todayCost: Double {
        memoized("todayCost") { calls.filter { Calendar.current.isDateInToday($0.time) }.reduce(0) { $0 + $1.cost } }
    }
    var weekCost: Double {
        memoized("weekCost") { calls.filter { $0.time >= Date().addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.cost } }
    }

    func planMonthly(for id: String) -> Double { id == "claude" ? planMonthlyUSD : otherPlansUSD[id] ?? 0 }

    func setPlanMonthly(_ price: Double, for id: String) {
        if id == "claude" { planMonthlyUSD = price } else { otherPlansUSD[id] = price }
    }

    /// Every account's plans together, for the widgets and menu, which always count every account.
    var totalPlanMonthly: Double {
        Self.monthlyPlan(main: planMonthlyUSD, others: otherPlansUSD, accounts: accounts.map(\.id), account: nil)
    }

    /// The monthly price that matches the calls being counted: the chosen account's plan, or all of them added up.
    /// One price for every account compared Team's usage with a Pro price, and both accounts' usage with one plan.
    static func monthlyPlan(main: Double, others: [String: Double], accounts: [String], account: String?) -> Double {
        guard accounts.count > 1 else { return main }
        func price(_ id: String) -> Double { id == "claude" ? main : others[id] ?? 0 }
        // Like `scope`, an account that's no longer listed means all of them.
        if let a = account, accounts.contains(a) { return price(a) }
        return accounts.reduce(0) { $0 + price($1) }
    }

    /// The plan price used for value maths; demo mode uses its own so screenshots never show the real one.
    var effectivePlan: Double {
        Demo.isOn ? 100 : Self.monthlyPlan(main: planMonthlyUSD, others: otherPlansUSD, accounts: accounts.map(\.id), account: account)
    }
    var planCostForRange: Double {
        guard !Demo.isOn else { return effectivePlan * rangeDays / 30 }
        let start = range == .all ? Date.distantPast : range.start(now: Date())
        return memoized("planCost") { planCost(since: start, account: account) }
    }

    /// What the plans cost from `since` to now: each account's plan from `since` or that account's first response,
    /// whichever is later, so an account opened last week isn't charged a whole month (or all of history).
    /// `account` nil means every account, as the menu and widgets count.
    func planCost(since: Date, account: String?, now: Date = Date()) -> Double {
        if accounts.count <= 1 {
            return Self.planCost(prices: [("claude", planMonthlyUSD)], first: firstCall.map { ["claude": $0] } ?? [:], since: since, now: now)
        }
        let ids = account.flatMap { a in accounts.contains { $0.id == a } ? [a] : nil } ?? accounts.map(\.id)
        let prices = ids.map { ($0, Self.monthlyPlan(main: planMonthlyUSD, others: otherPlansUSD, accounts: accounts.map(\.id), account: $0)) }
        var first: [String: Date] = [:]
        for id in ids { if let t = Self.scope(calls, accounts: accounts, account: id).first?.time { first[id] = t } }
        return Self.planCost(prices: prices, first: first, since: since, now: now)
    }

    static func planCost(prices: [(id: String, price: Double)], first: [String: Date], since: Date, now: Date) -> Double {
        prices.reduce(0) { sum, p in
            guard let f = first[p.id] else { return sum }
            return sum + p.price * max(1 / 24, now.timeIntervalSince(max(since, f)) / 86400) / 30
        }
    }

    /// All time with several accounts: each plan from its own account's first response. Spreading every plan back
    /// to the very first response charged an account added last week as if it had been paid for since July.
    static func allTimePlanCost(prices: [(id: String, price: Double)], first: [String: Date], now: Date) -> Double {
        planCost(prices: prices, first: first, since: .distantPast, now: now)
    }

    /// Days the chosen range covers, all time counted from the first response on record.
    var rangeDays: Double { range.days(now: Date(), first: firstCall) }

    /// When the oldest response on record was, for "All" ("since Jul 14").
    var firstCall: Date? { memoized("firstCall") { calls.lazy.map(\.time).min() } }

    var valueMultiple: Double? {
        let plan = planCostForRange
        return plan > 0 ? totalCost / plan : nil
    }

    /// What reading the same tokens as fresh input would have cost, minus what the cache reads cost.
    var cacheSaved: Double {
        memoized("cacheSaved") {
            inRange.reduce(0) { acc, c in
                guard let p = Pricing.claude(c.model) else { return acc }
                return acc + Double(c.cacheRead) * (p.input - p.cacheRead) / 1_000_000
            }
        }
    }

    /// `input` includes the advisor's tokens (its reads, writes and output, which transcripts only give as one
    /// total per turn); `advisor` says how many of them that is, so the legend can say so.
    struct Mix { var cacheRead = 0, cacheWrite = 0, output = 0, input = 0, advisor = 0
        var total: Int { cacheRead + cacheWrite + output + input } }

    var tokenMix: Mix {
        memoized("tokenMix") {
            inRange.reduce(into: Mix()) { m, c in
                m.cacheRead += c.cacheRead; m.cacheWrite += c.cw5 + c.cw1h; m.output += c.output; m.input += c.input + c.advisorTokens
                m.advisor += c.advisorTokens
            }
        }
    }

    /// Output tokens by weekday (Mon = 0) and hour, over the full history, every account.
    var heatmap: [[Double]] { memoized("heatmap") { Self.heatmap(Self.recent(calls)) } }
    /// The same for the dashboard's chosen account.
    var scopedHeatmap: [[Double]] { memoized("scopedHeatmap") { Self.heatmap(Self.recent(scoped)) } }

    /// The calls from `since` on, found by binary search: `calls` is in time order (see ClaudeUsageScanner.combine).
    static func calls(_ calls: [Call], since: Date) -> ArraySlice<Call> {
        var lo = 0, hi = calls.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if calls[mid].time < since { lo = mid + 1 } else { hi = mid }
        }
        return calls[lo...]
    }

    /// The heatmap's window: the last `heatmapDays`.
    static func recent(_ calls: [Call], now: Date = Date()) -> [Call] {
        let since = now.addingTimeInterval(-heatmapDays * 86400)
        return calls.filter { $0.time >= since }
    }

    static func heatmap(_ calls: [Call]) -> [[Double]] {
        var g = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        let cal = Calendar.current
        for c in calls {
            let wd = (cal.component(.weekday, from: c.time) + 5) % 7
            g[wd][cal.component(.hour, from: c.time)] += Double(c.output)
        }
        return g
    }

    var busiestHour: Int? {
        var byHour = Array(repeating: 0.0, count: 24)
        for row in scopedHeatmap { for h in 0..<24 { byHour[h] += row[h] } }
        guard let m = byHour.max(), m > 0 else { return nil }
        return byHour.firstIndex(of: m)
    }

    var sessions: [SessionSummary] { memoized("sessions") { summarizeSessions() } }

    private func summarizeSessions() -> [SessionSummary] {
        var map: [String: SessionSummary] = [:]
        for c in inRange {
            var s = map[c.session] ?? SessionSummary(id: c.session, sessionTitle: titles[c.session],
                                                       project: c.project, start: c.time, end: c.time, cost: 0)
            if s.org == nil { s.org = c.org }
            s.start = min(s.start, c.time); s.end = max(s.end, c.time)
            s.cost += c.cost
            s.input += c.input; s.cacheWrite += c.cw5 + c.cw1h; s.cacheRead += c.cacheRead; s.output += c.output
            s.tools += c.tools; s.mcpCalls += c.mcpCalls; s.webSearches += c.webSearches
            s.modelCost[c.model, default: 0] += c.cost
            if let server = c.mcpAttribution { s.mcpCost[server, default: 0] += c.cost }
            else if c.sidechain { s.subagentCost += c.cost; s.subagentCalls += 1 }
            else { s.mainCost += c.cost }
            map[c.session] = s
        }
        for k in map.keys { map[k]?.apiMillis = apiMillis[k] }
        return map.values.sorted { $0.cost > $1.cost }
    }

    struct ProjectSummary: Identifiable {
        var id: String { root }
        var root: String
        var cost: Double
        var sessions: Int
        var last: Date
    }

    /// Projects in the selected range, folded to their root folder, most expensive first.
    var projects: [ProjectSummary] { memoized("projects") { summarizeProjects() } }

    private func summarizeProjects() -> [ProjectSummary] {
        var map: [String: (Double, Set<String>, Date)] = [:]
        // One root per folder rather than per call: the dashboard works this out again every minute.
        var roots: [String: String] = [:]
        for c in inRange {
            if roots[c.project] == nil { roots[c.project] = ProjectNames.root(of: c.project) }
            let r = roots[c.project]!
            var e = map[r] ?? (0, [], c.time)
            e.0 += c.cost; e.1.insert(c.session); e.2 = max(e.2, c.time)
            map[r] = e
        }
        return map.map { ProjectSummary(root: $0.key, cost: $0.value.0, sessions: $0.value.1.count, last: $0.value.2) }
            .sorted { $0.cost > $1.cost }
    }

    /// 5-hour windows over the last `days`, rebuilt from activity the same way the reset estimate is.
    /// `scoped` uses the dashboard's chosen account; each account's windows are its own.
    func windows(days: Int = 7, scoped: Bool = false) -> [UsageWindow] {
        memoized("windows \(days) \(scoped)") { findWindows(days: days, scoped: scoped) }
    }

    private func findWindows(days: Int, scoped: Bool) -> [UsageWindow] {
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86400))
        let list = scoped ? self.scoped : calls
        // A scoped view only takes its own account's resets; Team's limit isn't Pro's.
        let orgs = Set(list.compactMap(\.org))
        let resets = scoped && account != nil ? limitResets.filter { $0.org.map(orgs.contains) ?? orgs.isEmpty } : limitResets
        return Self.windows(list, resets: resets, since: since)
    }

    /// Each account's own chain of 5-hour windows, merged in time order. One chain for every call made a Pro
    /// session that started inside a Team window vanish into it, though each account has its own limit. Calls
    /// without an account (subagent transcripts) go with their session's; sessions that never say form one chain.
    ///
    /// The chain runs over all of history, not from the start of the period shown: starting it there moved past
    /// windows as the days rolled on. A "limit reached" row names its window's exact reset, so a window it covers
    /// is placed from that (the estimate alone was an hour out when the window had been opened outside Claude
    /// Code), and only that account's window is marked as having hit the limit.
    static func windows(_ calls: [Call], resets: [ClaudeUsageScanner.LimitReset] = [], since: Date) -> [UsageWindow] {
        var sessionOrg: [String: String] = [:]
        for c in calls { if let o = c.org, sessionOrg[c.session] == nil { sessionOrg[c.session] = o } }
        var exact: [String: [Date]] = [:]
        for r in resets { exact[r.org ?? "", default: []].append(r.resetsAt) }
        for k in exact.keys { exact[k] = Array(Set(exact[k]!)).sorted() }
        var chains: [String: [UsageWindow]] = [:]
        for c in calls {
            let key = c.org ?? sessionOrg[c.session] ?? ""
            if let last = chains[key]?.last, c.time < last.end { continue }
            let known = exact[key]?.first { $0.addingTimeInterval(-5 * 3600) <= c.time && c.time < $0 }
            let start = known.map { $0.addingTimeInterval(-5 * 3600) } ?? ClaudeSource.floorTo10(c.time)
            chains[key, default: []].append(UsageWindow(start: start, end: start.addingTimeInterval(5 * 3600), autoStart: c.autoStart,
                                                         hitLimit: known != nil, account: key))
        }
        return chains.values.flatMap { $0 }.filter { $0.end > since }.sorted { $0.start < $1.start }
    }
}
