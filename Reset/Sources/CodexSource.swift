import Foundation

/// Reads Codex's own rate-limit report from ~/.codex/sessions. Codex writes the exact reset time and
/// used percentage for both its 5-hour and weekly windows into every session log, so this is not a guess.
struct CodexSource: WindowSource {
    let id = "codex"

    func read(now: Date) -> WindowStatus {
        read(now: now, root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
    }

    /// `root` is only ever not ~/.codex/sessions in the format-drift fixtures.
    func read(now: Date, root: URL) -> WindowStatus {
        var status = WindowStatus(id: id, name: "Codex", state: .ready, usedPercent: nil,
                                  isEstimate: false, source: "Codex session log", secondary: nil,
                                  canAutoStart: true)
        guard let latest = Self.latestRateLimits(under: root) else {
            status.state = .unavailable("No Codex sessions with rate limits yet")
            return status
        }
        // "primary" is not always the 5-hour window: some plans report a 7-day or 30-day primary and no
        // secondary. Sort the windows by length and treat the shortest one up to 5h as the session window.
        let windows: [(minutes: Double, resetsAt: Date, used: Double?)] = ["primary", "secondary"].compactMap { k in
            guard let w = latest[k] as? [String: Any], let at = Self.date(w["resets_at"]) else { return nil }
            // resets_at jitters by a second between events; round to the minute so alerts dedupe.
            let rounded = Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 60).rounded() * 60)
            return ((w["window_minutes"] as? Double) ?? 300, rounded, w["used_percent"] as? Double)
        }.sorted { $0.minutes < $1.minutes }

        var longer = windows
        if let session = windows.first, session.minutes <= 300 {
            longer.removeFirst()
            if session.resetsAt > now {
                status.state = .active(resetsAt: session.resetsAt)
                status.usedPercent = session.used
            } else {
                status.usedPercent = 0
            }
        } else {
            status.source = "Codex session log, no 5h window on this plan"
        }
        if let l = longer.first(where: { $0.resetsAt > now }) {
            status.secondary = .init(label: Self.label(minutes: l.minutes), resetsAt: l.resetsAt, usedPercent: l.used)
            if (l.used ?? 0) >= 100 { status.blockedUntil = l.resetsAt }
        }
        if (latest["rate_limit_reached_type"] as? String) != nil, status.blockedUntil == nil,
           let l = longer.first(where: { $0.resetsAt > now && ($0.used ?? 0) >= 99.5 }) {
            status.blockedUntil = l.resetsAt
        }
        return status
    }

    static func label(minutes: Double) -> String {
        switch minutes {
        case ..<1500: return "\(Int(minutes / 60))h"
        case 9000...11000: return "Weekly"
        case 40000...: return "Monthly"
        default: return "\(Int(minutes / 1440))-day"
        }
    }

    static func date(_ v: Any?) -> Date? {
        (v as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    /// The last `rate_limits` object written in the most recently modified session log that has one.
    static func latestRateLimits(under root: URL) -> [String: Any]? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append((url, mod ?? .distantPast))
        }
        files.sort { $0.1 > $1.1 }
        let marker = Data("\"rate_limits\":{".utf8)
        for (url, _) in files.prefix(20) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)),
                   let rl = find("rate_limits", in: obj) as? [String: Any],
                   rl["primary"] is [String: Any] {
                    return rl
                }
            }
        }
        return nil
    }

    static func find(_ key: String, in obj: Any) -> Any? {
        if let d = obj as? [String: Any] {
            if let v = d[key], !(v is NSNull) { return v }
            for v in d.values { if let f = find(key, in: v) { return f } }
        } else if let a = obj as? [Any] {
            for v in a { if let f = find(key, in: v) { return f } }
        }
        return nil
    }
}

/// Gemini CLI's free-tier quota is per day and resets at midnight Pacific time.
struct GeminiSource: WindowSource {
    let id = "gemini"

    func read(now: Date) -> WindowStatus {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let next = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86400)
        return WindowStatus(id: id, name: "Gemini CLI", state: .active(resetsAt: next), usedPercent: nil,
                            isEstimate: false, source: "Daily quota, midnight Pacific", secondary: nil,
                            canAutoStart: false)
    }
}

/// Any other tool: the user says when they started, and gives the window length.
struct CustomProvider: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var windowHours: Double
    var startedAt: Date?

    func status(now: Date) -> WindowStatus {
        var state = WindowStatus.State.ready
        if let s = startedAt {
            let end = s.addingTimeInterval(windowHours * 3600)
            if end > now { state = .active(resetsAt: end) }
        }
        let hours = windowHours == windowHours.rounded() ? "\(Int(windowHours))h" : "\(windowHours)h"
        return WindowStatus(id: "custom-" + id, name: name, state: state, usedPercent: nil, isEstimate: true,
                            source: "Manual, \(hours) window", secondary: nil, canAutoStart: false, windowLength: windowHours * 3600)
    }
}
