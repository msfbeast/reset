import Foundation

/// One provider's current rate-limit window, as best we can tell from local data.
struct WindowStatus: Identifiable, Equatable {
    enum State: Equatable {
        /// A window is running and resets at this time.
        case active(resetsAt: Date)
        /// No window is running; the next message starts a fresh one.
        case ready
        /// We could not read anything for this provider.
        case unavailable(String)
    }

    struct Secondary: Equatable {
        var label: String
        var resetsAt: Date
        var usedPercent: Double?

        /// From here a longer limit is worth a warning: the menu colours it, the status line shows it, and a
        /// notification says so once. Before, nothing said anything until it was used up.
        static let warnPercent = 80.0
        var isHigh: Bool { (usedPercent ?? 0) >= Self.warnPercent }
    }

    var id: String
    var name: String
    var state: State
    /// 0...100 when the provider reports it.
    var usedPercent: Double?
    /// True when the reset time is inferred from activity rather than reported by the provider.
    var isEstimate: Bool
    var source: String
    var secondary: Secondary?
    /// Whether the auto-start toggle makes sense for this provider.
    var canAutoStart: Bool
    /// A longer limit (weekly, monthly) is exhausted until this time, so a fresh session window would not help.
    var blockedUntil: Date? = nil
    /// When `usedPercent` was measured, if it is not live.
    var usageAsOf: Date? = nil
    /// The most recent real API response seen in this tool's logs, for pacing how often live usage is fetched.
    var lastActivity: Date? = nil
    /// For Claude entries, the organization (account) they're for.
    var account: String? = nil
    /// For Claude entries, the last activity from a session that names this account. `lastActivity` also counts
    /// untagged events (subagent transcripts and the like, folded into the main entry), so it can't tell which
    /// account you're using.
    var lastTaggedActivity: Date? = nil
    /// How long one window lasts, when the provider sets it (a custom tool's own length); otherwise see `Store.cardData`.
    var windowLength: TimeInterval? = nil

    var resetsAt: Date? {
        if case .active(let d) = state { return d }
        return nil
    }

    /// How long one window lasts: Gemini CLI's quota is daily, Cursor's a billing month, the rest 5 hours.
    static func length(of id: String) -> TimeInterval {
        switch id {
        case "gemini": return 86400
        case "cursor": return 30 * 86400
        default: return 5 * 3600
        }
    }
}

protocol WindowSource {
    var id: String { get }
    func read(now: Date) -> WindowStatus
}

enum Fmt {
    /// "2h 14m", "14m", "45s"
    static func countdown(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded()))
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Compact form for the menu bar: "2:14", "0:09"
    static func short(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d" }
        return "\(h):\(String(format: "%02d", m))"
    }

    /// Clock times follow the Mac's 12/24-hour setting ("9:29 PM" or "21:29"); a fixed "h:mm a" ignored it.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEjmm")
        return f
    }()

    /// Whether this Mac shows 24-hour times.
    static var uses24Hour: Bool { !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a") }

    /// An hour for chart axes: "6 AM", or "06" on a 24-hour Mac.
    static func hourLabel(_ h: Int) -> String {
        if uses24Hour { return String(format: "%02d", h) }
        return h == 0 ? "12 AM" : h < 12 ? "\(h) AM" : h == 12 ? "12 PM" : "\(h - 12) PM"
    }

    static func when(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? clock.string(from: date) : dayClock.string(from: date)
    }
}
