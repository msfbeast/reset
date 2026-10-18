import Foundation

/// What the desktop widgets show, written by the app to ~/Library/Application Support/Reset/widget.json.
/// The widget extension is sandboxed and only allowed to read that one folder.
struct WidgetSnapshot: Codable {
    struct Provider: Codable, Identifiable {
        var id: String
        var name: String
        var resetsAt: Date?
        var ready: Bool
        var available: Bool
        var used: Double?
        var blockedUntil: Date?
        /// Why these numbers are a guess (see UsageAccuracy), or nil when they're solid. Optional for old snapshots.
        var estimate: String? = nil
        /// The weekly limit, when known (live usage on a Pro or Max plan): % used and when it resets.
        var weeklyUsed: Double? = nil
        var weeklyResetsAt: Date? = nil
        /// When the usage % was read (from Anthropic, or the Claude desktop app). `updated` only says when the
        /// snapshot last changed, which can't tell an agent how old the reading behind it is.
        var usageAsOf: Date? = nil
        /// The live check has been failing since then, and why; the % above is the last good one.
        var liveFailingSince: Date? = nil
        var liveProblem: String? = nil
        /// For Claude entries, the organization (account) they're for. Optional for old snapshots.
        var org: String? = nil
        /// `blockedUntil` is a guess (the latest the weekly limit can lift), so it's shown as "about".
        var blockedEstimate: Bool? = nil
    }
    struct Window: Codable {
        var start: Date
        var end: Date
        var autoStart: Bool
        var hitLimit: Bool
    }

    var updated: Date
    var look: Look?
    var providers: [Provider]
    var windows: [Window]
    var weekCost: Double
    var weekMultiple: Double?
    var cacheHit: Double
    // Month view, for the Value and Month widgets. Optional so older snapshots still decode.
    var monthCost: Double?
    var monthMultiple: Double?
    var monthCacheSaved: Double?
    var monthTokens: Int?
    /// Cache read, cache write, output, input.
    var monthMix: [Int]?
    /// Output by weekday (Mon first) and hour, 0...1.
    var heatmap: [[Double]]?
    /// Output per hour today, 0...1.
    var today: [Double]?
    /// API value per day for the last 14 days, oldest first.
    var dailyCost: [Double]?
    /// Cumulative API value by hour, today and yesterday.
    var todayCumulative: [Double]?
    var yesterdayCumulative: [Double]?
    /// Top projects this month by API value.
    var projects: [Project]?
    /// This calendar month: API value per day (index 0 = 1st) and days the 5-hour limit was hit.
    var monthDays: [Double]?
    var limitDays: [Int]?
    /// Projected time the Claude window runs out before its reset, when the pace says so.
    var claudeRunsOutAt: Date?
    /// When a widget's "Start now" was pressed and the app began starting Claude's window; cleared when done.
    var startingAt: Date?
    /// Every Claude account, the main one first, whether or not it's shown in the menu: reset-mcp answers for the
    /// account the asking agent runs on (see `claude(org:)`), which can be another one than the terminal's.
    var claudeAccounts: [Provider]?

    struct Project: Codable { var name: String; var cost: Double }

    static let folder = "Library/Application Support/Reset"
    static let fileName = "widget.json"

    /// The real home folder, also from inside the widget's sandbox container.
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(folder).appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: Self.url, options: .atomic)
    }

    var claude: Provider? { providers.first { $0.id == "claude" } }

    /// The Claude entry for an account. No org (an agent that didn't say) means the main one, the terminal's.
    /// An org Reset hasn't listed gets nil rather than another account's numbers, except with a snapshot from
    /// before accounts were written, where the main entry is all there is.
    func claude(org: String?) -> Provider? {
        guard let org else { return claude }
        guard let accounts = claudeAccounts else { return claude }
        return accounts.first { $0.org == org }
    }

    /// Whether more than one Claude account is in use, so a report should say which one it's about.
    var hasClaudeAccounts: Bool { (claudeAccounts?.count ?? 0) > 1 }

    /// Whether Reset is running, as of `now`, from its heartbeat (see Heartbeat).
    static func appRunning(now: Date = Date(), heartbeat: URL = Heartbeat.url) -> Bool {
        Heartbeat.lastBeat(at: heartbeat).map { now.timeIntervalSince($0) < Heartbeat.staleAfter } ?? false
    }

    /// Today's and yesterday's running totals as seen on `date`. The stored series describe the day the snapshot
    /// was written, and a widget keeps the same snapshot for up to an hour, so just after midnight "today" showed
    /// all of yesterday. A snapshot from yesterday is yesterday's curve and nothing yet today.
    func dayCurves(on date: Date, calendar: Calendar = .current) -> (today: [Double], yesterday: [Double]) {
        let zero = Array(repeating: 0.0, count: 24)
        let t = todayCumulative ?? zero, y = yesterdayCumulative ?? zero
        if calendar.isDate(updated, inSameDayAs: date) { return (t, y) }
        if let next = calendar.date(byAdding: .day, value: 1, to: updated), calendar.isDate(next, inSameDayAs: date) { return (zero, t) }
        return (zero, zero)
    }

    /// This month's days and limit days as seen on `date`: none yet once the snapshot is from an earlier month.
    func month(on date: Date, calendar: Calendar = .current) -> (days: [Double], limitDays: [Int]) {
        guard calendar.isDate(updated, equalTo: date, toGranularity: .month) else { return ([], []) }
        return (monthDays ?? [], limitDays ?? [])
    }
}

/// Reset touches this file every 30 seconds while it runs and removes it when it quits. The status line and the
/// MCP server read files Reset leaves behind, so without it a quit Reset's last countdown and usage looked live
/// for days.
enum Heartbeat {
    static var url: URL { WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("running") }
    /// Three missed beats: past this, Reset has quit, crashed, or the Mac slept through it.
    static let staleAfter: TimeInterval = 180

    static func beat(at url: URL = url) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func stop(at url: URL = url) { try? FileManager.default.removeItem(at: url) }

    static func lastBeat(at url: URL = url) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
