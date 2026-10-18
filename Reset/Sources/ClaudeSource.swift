import Foundation

/// Claude's 5-hour session window, rebuilt from Claude Code transcripts in ~/.claude/projects.
///
/// Two kinds of evidence:
/// - Exact: when a limit is hit, Claude Code logs an error row with `quotaLimits.resetsAt` (epoch seconds)
///   and `rateLimitType` (five_hour or seven_day). That is the real reset time.
/// - Estimate: otherwise a window opens at the first successful API response after the previous window
///   ended, floored to 10 minutes (every exact reset logged on this Mac sits on a 10-minute mark), and runs 5h.
///
/// Usage on claude.ai or the desktop chat is invisible here, so `extraStarts` lets the user add it.
struct ClaudeSource: WindowSource {
    let id = "claude"
    static let window: TimeInterval = 5 * 3600
    static let scanner = TranscriptScanner()

    var extraStarts: [Date] = []

    func read(now: Date) -> WindowStatus {
        readAll(now: now, account: nil)[0]
    }

    /// One status per Claude account seen in the transcripts: "claude" for the account the Claude Code CLI is
    /// signed in to (live usage, auto-start and budgets go through the CLI), and "claude-<org>" for any other
    /// account used in the last week, each with its own window from its own sessions. With one account there's
    /// just "Claude", as before. `desktop` is the other accounts Reset reads live through the Claude desktop app,
    /// with their plans: they're listed even without Claude Code sessions this week, and named by their plan.
    func readAll(now: Date, account: ClaudeCLI.Account?, desktop: [String: String?] = [:]) -> [WindowStatus] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: root.path) else {
            var s = WindowStatus(id: id, name: "Claude", state: .unavailable("No ~/.claude/projects folder"), usedPercent: nil,
                                 isEstimate: true, source: "Estimated from Claude Code activity", secondary: nil, canAutoStart: true)
            s.lastActivity = nil
            return [s]
        }

        // A week of events from every account, to find the accounts and give the others their windows.
        let week = Self.scanner.events(under: root, since: now.addingTimeInterval(-Self.otherLookback))
        let main = Self.mainOrg(cliOrg: account?.orgId, events: week)

        // Widen the lookback until the oldest activity follows a gap of at least one window, so the chain of
        // windows is anchored at a real start rather than wherever the scan happened to begin.
        var lookback = 2 * Self.window
        let maxLookback: TimeInterval = 7 * 86400
        var events: [TranscriptScanner.Event] = []
        while true {
            let horizon = now.addingTimeInterval(-lookback)
            // Only the main account's sessions (and untagged ones, such as "I used Claude on the web").
            events = Self.scanner.events(under: root, since: horizon).filter { $0.org == nil || $0.org == main }
            events += extraStarts.filter { $0 > horizon && $0 <= now }.map { .init(time: $0, kind: .activity) }
            events.sort { $0.time < $1.time }
            let firstActivity = events.first { $0.kind == .activity }?.time
            guard let first = firstActivity, first < horizon.addingTimeInterval(Self.window),
                  lookback < maxLookback else { break }
            lookback = min(lookback * 2, maxLookback)
        }

        let others = Self.others(used: Self.otherOrgs(events: week, main: main), desktop: Array(desktop.keys), main: main)
        var mainStatus = Self.status(id: id, name: "Claude", events: events, org: main ?? Self.currentOrg(under: root), now: now,
                                     canAutoStart: true)
        let ids = ["claude"] + others.map { "claude-" + $0.prefix(8) }
        let labels = Self.accountLabels(ids: ids, defaults: [Self.planLabel(account?.plan) ?? "Claude Code"]
                                            + others.map { Self.planLabel(desktop[$0] ?? nil) ?? Self.otherLabel(org: $0) },
                                        custom: Self.customNames)
        if !others.isEmpty { mainStatus.name = "Claude · " + labels[0] }
        func lastTagged(_ org: String?) -> Date? {
            guard let org else { return nil }
            return week.filter { $0.org == org && $0.kind == .activity && $0.time <= now }.map(\.time).max()
        }
        mainStatus.lastTaggedActivity = lastTagged(mainStatus.account)
        var out = [mainStatus]
        for (i, org) in others.enumerated() {
            let mine = week.filter { $0.org == org }.sorted { $0.time < $1.time }
            // Auto-start runs through the CLI, which is signed in to the main account, so it can't start these.
            var s = Self.status(id: ids[i + 1], name: "Claude · " + labels[i + 1], events: mine,
                                org: org, now: now, canAutoStart: false)
            // Say whose sessions it's estimated from, keeping anything appended (such as a used-up weekly limit).
            if s.isEstimate, s.source.hasPrefix("Estimated from Claude Code activity") {
                s.source = "Estimated from this account's Claude Code sessions" + s.source.dropFirst("Estimated from Claude Code activity".count)
            }
            s.lastTaggedActivity = lastTagged(org)
            out.append(s)
        }
        return out
    }

    /// The account you're using now, which the menu's top card and the menu bar follow. Usually the terminal's,
    /// but switching accounts in the Claude desktop app leaves the terminal signed in to the old one.
    ///
    /// - A switch, in the desktop app or with `claude auth login`, rewrites ~/.claude.json (`configChangedAt`): once
    ///   Reset lists that account, it wins, even while the other one is still busy. Until then the switch waits.
    /// - Otherwise the account with the newest session activity takes over, but only once the current one has been
    ///   quiet for `quiet`. Both can be busy at once (background worktrees on one, a chat on the other), and the top
    ///   card swapping every minute would be worse than either.
    static func activeOrg(current: String?, chosenAt: Date?, configOrg: String?, configChangedAt: Date?,
                          listed: Set<String>, lastUse: [String: Date], now: Date, quiet: TimeInterval = 10 * 60) -> String? {
        let current = current.flatMap { listed.contains($0) ? $0 : nil }
        if let c = configOrg, listed.contains(c), c != current,
           (configChangedAt ?? .distantPast) > (chosenAt ?? .distantPast) || current == nil { return c }
        let used = lastUse.filter { listed.contains($0.key) }
        guard let newest = used.max(by: { $0.value < $1.value }) else { return current }
        guard let current else { return newest.key }
        // An account with no sessions (one listed only through the desktop app) has been quiet since it was chosen.
        let mine = used[current] ?? chosenAt ?? .distantPast
        if newest.key != current, now.timeIntervalSince(mine) >= quiet { return newest.key }
        return current
    }

    /// Other accounts count if they were used in the last week; older ones have no window to show.
    static let otherLookback: TimeInterval = 7 * 86400

    /// The CLI's account when known, otherwise the account of the most recent activity.
    static func mainOrg(cliOrg: String?, events: [TranscriptScanner.Event]) -> String? {
        if let cliOrg { return cliOrg }
        return events.filter { $0.kind == .activity && $0.org != nil }.max { $0.time < $1.time }?.org
    }

    /// Accounts other than the main one with real activity in the events, most recently used first.
    static func otherOrgs(events: [TranscriptScanner.Event], main: String?) -> [String] {
        var last: [String: Date] = [:]
        for e in events where e.kind == .activity {
            guard let o = e.org, o != main else { continue }
            last[o] = max(last[o] ?? .distantPast, e.time)
        }
        return last.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Every account besides the main one: those used this week, most recent first, then any others signed in to
    /// the Claude desktop app, in a fixed order so their entries don't swap places between scans.
    static func others(used: [String], desktop: [String], main: String?) -> [String] {
        used + desktop.filter { $0 != main && !used.contains($0) }.sorted()
    }

    /// Names given to accounts in Settings, by status id ("claude", "claude-<org>").
    static var customNames: [String: String] {
        UserDefaults.standard.dictionary(forKey: "accountNames") as? [String: String] ?? [:]
    }

    /// One label per account: the name given in Settings, else the plan. Repeats get a number ("Pro", "Pro 2"),
    /// since two accounts on the same plan both came out as "Claude · Pro" and couldn't be told apart.
    static func accountLabels(ids: [String], defaults: [String], custom: [String: String]) -> [String] {
        var seen: [String: Int] = [:]
        return zip(ids, defaults).map { id, fallback in
            let given = custom[id]?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = given.isEmpty ? fallback : given
            let n = (seen[label.lowercased()] ?? 0) + 1
            seen[label.lowercased()] = n
            return n == 1 ? label : "\(label) \(n)"
        }
    }

    /// "team" → "Team" and so on, for naming the main entry when there's more than one account.
    static func planLabel(_ plan: String?) -> String? {
        guard let p = plan?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return p.prefix(1).uppercased() + p.dropFirst()
    }

    /// The other account's plan isn't written anywhere Reset reads, but only Pro and Max plans have a weekly
    /// limit, which the Claude desktop app logs for them; Team and Enterprise ones don't.
    static func otherLabel(org: String, url: URL = PlanUsageLog.url) -> String {
        PlanUsageLog.latest(org: org, url: url)?.sevenDay != nil ? "Pro" : "other account"
    }

    /// The window, limit hits and desktop-app reading for one account's events.
    static func status(id: String, name: String, events: [TranscriptScanner.Event], org: String?, now: Date,
                       canAutoStart: Bool, planLog: URL = PlanUsageLog.url) -> WindowStatus {
        var status = WindowStatus(id: id, name: name, state: .ready, usedPercent: nil, isEstimate: true,
                                  source: "Estimated from Claude Code activity", secondary: nil, canAutoStart: canAutoStart)
        status.account = org
        let activity = events.filter { $0.kind == .activity }.map(\.time)
        status.lastActivity = activity.last { $0 <= now }
        let result = compute(events: events, activity: activity, now: now)
        if let w = result.window {
            status.state = .active(resetsAt: w.end)
            status.isEstimate = !w.exact
            if w.exact { status.source = "Exact, from Claude Code's limit message" }
        }
        if let weekly = result.weeklyBlockUntil {
            status.secondary = .init(label: "Weekly limit hit", resetsAt: weekly, usedPercent: 100)
            status.blockedUntil = weekly
        }

        // Real usage % from the Claude desktop app's own log, for this account.
        // A reading only counts if it was taken inside the current window; older ones describe a past window.
        if let org, let sample = PlanUsageLog.latest(org: org, url: planLog) {
            let windowStart = status.resetsAt?.addingTimeInterval(-window)
            // The desktop app only logs at moments like a window starting or the limit being hit, so a reading
            // is only trusted while fresh. A limit hit stays true for the rest of its window.
            if let ws = windowStart, sample.time >= ws,
               now.timeIntervalSince(sample.time) < 15 * 60 || sample.fiveHour >= 100 {
                status.usedPercent = sample.fiveHour
                status.usageAsOf = sample.time
            }
            // A used-up weekly limit, when no limit message gave its reset time. Saying only "used up as of Tue" left
            // the entry reading "ready" for a week whether or not the limit had lifted, so it blocks until the
            // latest it can lift; Claude Code replies on this account since the reading prove it already has.
            if status.blockedUntil == nil, let hit = PlanUsageLog.weeklyHit(org: org, now: now, url: planLog),
               (status.lastActivity ?? .distantPast) <= hit.stillAt {
                status.secondary = .init(label: "Weekly limit hit", resetsAt: hit.liftsBy, usedPercent: 100)
                status.blockedUntil = hit.liftsBy
                status.blockedEstimate = true
                status.source += " · weekly limit hit \(Fmt.when(hit.at, now: now)), lifts by about \(Fmt.when(hit.liftsBy, now: now))"
            }
        }
        return status
    }

    /// The organization of the most recently written transcript, from Claude Code's `credential_org` rows.
    static func currentOrg(under root: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for case let url as URL in e where url.pathExtension == "jsonl" {
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > cutoff {
                files.append((url, m))
            }
        }
        let key = Data("\"organizationUuid\":\"".utf8)
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let r = data.range(of: key, options: .backwards) else { continue }
            let rest = data[r.upperBound...]
            if let end = rest.firstIndex(of: UInt8(ascii: "\"")) { return String(data: rest[..<end], encoding: .utf8) }
        }
        return nil
    }

    struct Computed {
        var window: (end: Date, exact: Bool)?
        var weeklyBlockUntil: Date?
    }

    /// A limit row is trusted only if nothing succeeded after it before its reset; success in that span
    /// means another account or a lifted limit, so the row says nothing about the current window.
    static func isValid(_ t: Date, resetsAt: Date, activity: [Date]) -> Bool {
        !activity.contains { $0 > t.addingTimeInterval(120) && $0 < resetsAt }
    }

    static func compute(events: [TranscriptScanner.Event], activity: [Date], now: Date) -> Computed {
        var out = Computed()
        var start: Date?
        var end: Date?
        var exact = false
        for e in events where e.time <= now {
            switch e.kind {
            case .activity:
                if let en = end, e.time < en { continue }
                start = floorTo10(e.time)
                end = start!.addingTimeInterval(window)
                exact = false
            case .fiveHourLimit(let r):
                guard isValid(e.time, resetsAt: r, activity: activity) else { continue }
                start = r.addingTimeInterval(-window)
                end = r
                exact = true
            case .weeklyLimit(let r):
                if r > now, isValid(e.time, resetsAt: r, activity: activity) { out.weeklyBlockUntil = r }
            }
        }
        if let en = end, now < en { out.window = (en, exact) }
        return out
    }

    static func floorTo10(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 600).rounded(.down) * 600)
    }
}

/// ~/Library/Application Support/Claude/plan-usage-history.json, written by the Claude desktop app:
/// samples of the 5-hour (`fh`) and 7-day (`sd`) usage percentage per organization.
enum PlanUsageLog {
    struct Sample { var time: Date; var fiveHour: Double; var sevenDay: Double? }

    /// Every account's readings, oldest first, keyed by organization (lower-cased).
    static func history(url: URL = PlanUsageLog.url) -> [String: [Sample]] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["samples"] as? [[String: Any]] else { return [:] }
        var out: [String: [Sample]] = [:]
        for s in rows {
            guard let org = (s["org"] as? String)?.lowercased(), let t = s["t"] as? Double, let u = s["u"] as? [String: Any],
                  let fh = u["fh"] as? Double else { continue }
            out[org, default: []].append(Sample(time: Date(timeIntervalSince1970: t / 1000), fiveHour: fh, sevenDay: u["sd"] as? Double))
        }
        return out.mapValues { $0.sorted { $0.time < $1.time } }
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    /// `url` is only ever not the desktop app's file in the format-drift fixtures and tests.
    static func latest(org: String, url: URL = PlanUsageLog.url) -> Sample? {
        samples(org: org, url: url).last
    }

    /// One organization's readings, oldest first.
    static func samples(org: String, url: URL = PlanUsageLog.url) -> [Sample] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["samples"] as? [[String: Any]] else { return [] }
        return rows.compactMap { s in
            guard (s["org"] as? String) == org, let t = s["t"] as? Double, let u = s["u"] as? [String: Any],
                  let fh = u["fh"] as? Double else { return nil }
            return Sample(time: Date(timeIntervalSince1970: t / 1000), fiveHour: fh, sevenDay: u["sd"] as? Double)
        }
    }

    /// The weekly limit's state when the latest reading says it's used up: when it was first seen used up, the
    /// latest reading that still said so, and the latest it can lift. The weekly limit resets once every 7 days, and the first reading after a drop shows a reset had
    /// happened by then, so the next one is due by 7 days after that reading. Without a drop on record, 7 days after
    /// the used-up reading bounds it. Nil once that's passed, or when the limit isn't used up.
    static func weeklyHit(org: String, now: Date, url: URL = PlanUsageLog.url) -> (at: Date, stillAt: Date, liftsBy: Date)? {
        let all = samples(org: org, url: url).filter { $0.sevenDay != nil }
        guard let last = all.last, let sd = last.sevenDay, sd >= 100 else { return nil }
        let week: TimeInterval = 7 * 86400
        var lastReset: Date?
        for (a, b) in zip(all, all.dropFirst()) where b.sevenDay! < a.sevenDay! { lastReset = b.time }
        // A drop whose next reset would already have come before the used-up reading is from an older cycle
        // (or the schedule moved); fall back to the reading itself.
        var liftsBy = last.time.addingTimeInterval(week)
        if let r = lastReset, r.addingTimeInterval(week) > last.time { liftsBy = r.addingTimeInterval(week) }
        let first = all.reversed().prefix { $0.sevenDay! >= 100 }.last ?? last
        return liftsBy > now ? (first.time, last.time, liftsBy) : nil
    }
}

/// Parses transcript rows into activity and limit events, caching each file by (mtime, size) so the
/// 60-second rescan only re-reads files that changed.
final class TranscriptScanner {
    struct Event: Equatable {
        enum Kind: Equatable {
            case activity
            case fiveHourLimit(Date)
            case weeklyLimit(Date)
        }
        var time: Date
        var kind: Kind
        /// The Claude organization (account) of the session the event came from, when its transcript says.
        var org: String? = nil
    }

    private struct Entry { var mtime: Date; var size: Int; var events: [Event]; var offset: Int; var org: String? }
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    func events(under root: URL, since: Date) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [Event] = []
        var seen: Set<String> = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mod = rv?.contentModificationDate, mod >= since else { continue }
            let size = rv?.fileSize ?? 0
            seen.insert(url.path)
            let entry: Entry
            if let c = cache[url.path], c.mtime == mod, c.size == size {
                entry = c
            } else if let c = cache[url.path], size > c.offset, c.offset > 0 {
                // Transcripts only grow: read just the new lines.
                let (events, offset) = Self.parse(url, from: c.offset, size: size)
                entry = Entry(mtime: mod, size: size, events: c.events + events, offset: offset,
                              org: Self.lastOrg(url, from: c.offset, size: size) ?? c.org)
                cache[url.path] = entry
            } else {
                let (events, offset) = Self.parse(url, from: 0, size: size)
                entry = Entry(mtime: mod, size: size, events: events, offset: offset, org: Self.lastOrg(url, from: 0, size: size))
                cache[url.path] = entry
            }
            // A session runs under one account; its transcript's org applies to all its events.
            out += entry.events.filter { $0.time >= since }.map { var e = $0; e.org = entry.org; return e }
        }
        // Drop cache entries for files that aged out of every possible lookback, not every file this call skipped:
        // a scan asks for a week and then for 10 hours, and keeping only the 10 hours' files made every 60-second
        // scan parse the whole week of transcripts again.
        if cache.count > seen.count + 200 {
            let oldest = Date().addingTimeInterval(-Self.keep)
            cache = cache.filter { seen.contains($0.key) || $0.value.mtime >= oldest }
        }
        return out
    }

    /// A day longer than the longest lookback asked for (ClaudeSource's week).
    static let keep: TimeInterval = 8 * 86400

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The last `organizationUuid` Claude Code wrote in this part of a transcript (its credential rows).
    static func lastOrg(_ url: URL, from start: Int, size: Int) -> String? {
        guard let all = try? Data(contentsOf: url, options: .mappedIfSafe), all.count > start else { return nil }
        let data = all[start..<min(all.count, max(size, start))]
        let key = Data("\"organizationUuid\":\"".utf8)
        guard let r = data.range(of: key, options: .backwards) else { return nil }
        let rest = data[r.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: rest[..<end], encoding: .utf8)
    }

    static func parse(_ url: URL, from start: Int, size: Int) -> ([Event], Int) {
        guard let all = try? Data(contentsOf: url, options: .mappedIfSafe), all.count > start else { return ([], start) }
        let end = min(all.count, max(size, start))
        // Straight from the bytes: Data.split and Data.range(of:) spent most of their time on per-byte bookkeeping,
        // and each launch reads a week of transcripts, gigabytes for someone who uses Claude Code all day.
        return all.withUnsafeBytes { all -> ([Event], Int) in
            guard end > start, let lastNewline = all.lastIndex(of: UInt8(ascii: "\n"), in: start..<end) else { return ([], start) }
            var out: [Event] = []
            var prompts: [Date] = [], answered: [Date] = []
            all.forEachLine(in: start..<lastNewline + 1) { line in
                // A typed prompt: the window starts when it's sent, not when Claude's reply begins, which can be a
                // minute later and on the other side of a 10-minute mark. Tool results and meta rows aren't prompts.
                if line.find(Marker.user) != nil, line.find(Marker.toolResult) == nil, line.find(Marker.isMeta) == nil,
                   line.find(Marker.localCommand) == nil, let ts = timestamp(line) {
                    prompts.append(ts)
                    return
                }
                guard line.find(Marker.assistant) != nil, let ts = timestamp(line) else { return }
                if line.find(Marker.quota) != nil {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let q = obj["quotaLimits"] as? [String: Any], let r = q["resetsAt"] as? Double,
                       (q["status"] as? String) == "rejected" {
                        let at = Date(timeIntervalSince1970: r)
                        switch q["rateLimitType"] as? String {
                        case "five_hour": out.append(.init(time: ts, kind: .fiveHourLimit(at)))
                        case "seven_day", "seven_day_opus", "seven_day_sonnet": out.append(.init(time: ts, kind: .weeklyLimit(at)))
                        default: break
                        }
                    }
                    return
                }
                // Only real API responses count as usage: error rows, slash-command echoes and synthetic
                // rows have no requestId or are flagged as API errors.
                guard line.find(Marker.isError) == nil, line.find(Marker.requestId) != nil else { return }
                out.append(.init(time: ts, kind: .activity))
                answered.append(ts)
            }
            // Only prompts Claude answered within 10 minutes: one that failed (offline, signed out) opened nothing.
            for p in prompts where answered.contains(where: { $0 >= p && $0.timeIntervalSince(p) <= 600 }) {
                out.append(.init(time: p, kind: .activity))
            }
            out.sort { $0.time < $1.time }
            return (out, lastNewline + 1)
        }
    }

    private enum Marker {
        static let assistant = Array("\"type\":\"assistant\"".utf8)
        static let user = Array("\"type\":\"user\"".utf8)
        static let toolResult = Array("\"tool_result\"".utf8)
        static let isMeta = Array("\"isMeta\":true".utf8)
        static let localCommand = Array("<local-command".utf8)
        static let quota = Array("\"quotaLimits\"".utf8)
        static let isError = Array("\"isApiErrorMessage\":true".utf8)
        static let requestId = Array("\"requestId\"".utf8)
        static let timestamp = Array("\"timestamp\":\"".utf8)
    }

    private static func timestamp(_ line: UnsafeRawBufferPointer) -> Date? {
        guard let r = line.find(Marker.timestamp) else { return nil }
        let start = r + Marker.timestamp.count
        guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return date(UnsafeRawBufferPointer(rebasing: line[start..<end]))
    }

    /// Reads "2026-03-02T09:14:05.120Z", the shape Claude Code writes, without ISO8601DateFormatter, which took
    /// about 40 µs a row, a third of the time spent parsing at launch. Anything else still goes to the formatter.
    static func date(_ b: UnsafeRawBufferPointer) -> Date? {
        func number(_ at: Int, _ digits: Int) -> Int? {
            var v = 0
            for i in at..<at + digits {
                guard (48...57).contains(b[i]) else { return nil }
                v = v * 10 + Int(b[i] - 48)
            }
            return v
        }
        if b.count == 24, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"), b[10] == UInt8(ascii: "T"),
           b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"), b[19] == UInt8(ascii: "."), b[23] == UInt8(ascii: "Z"),
           let y = number(0, 4), let mo = number(5, 2), let d = number(8, 2), let h = number(11, 2), let mi = number(14, 2),
           let s = number(17, 2), let ms = number(20, 3),
           // Only dates the formatter reads the same way: no earlier calendars, leap seconds or rolled-over days.
           y >= 2000, (1...12).contains(mo), (1...daysIn(month: mo, year: y)).contains(d), h < 24, mi < 60, s < 60 {
            let seconds = ((daysSince1970(year: y, month: mo, day: d) * 24 + h) * 60 + mi) * 60 + s
            return Date(timeIntervalSince1970: Double(seconds * 1000 + ms) / 1000)
        }
        guard let s = String(bytes: b, encoding: .utf8) else { return nil }
        return iso.date(from: s)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    /// Days from 1970-01-01 in the Gregorian calendar (Howard Hinnant's days_from_civil, for years from 2000).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400, yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }
}

fileprivate extension UnsafeRawBufferPointer {
    /// Each non-empty line in `range`, as `split(separator: "\n")` gives them.
    func forEachLine(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> Void) {
        guard let base = baseAddress else { return }
        var lo = range.lowerBound
        while lo < range.upperBound {
            let hi = memchr(base + lo, Int32(UInt8(ascii: "\n")), range.upperBound - lo).map { base.distance(to: $0) } ?? range.upperBound
            if hi > lo { body(UnsafeRawBufferPointer(start: base + lo, count: hi - lo)) }
            lo = hi + 1
        }
    }

    /// Where `marker` first appears in these bytes.
    func find(_ marker: [UInt8]) -> Int? {
        guard let base = baseAddress, !marker.isEmpty else { return nil }
        return marker.withUnsafeBytes { m in memmem(base, count, m.baseAddress, m.count).map { base.distance(to: $0) } }
    }

    func lastIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
        var i = range.upperBound - 1
        while i >= range.lowerBound {
            if self[i] == byte { return i }
            i -= 1
        }
        return nil
    }
}

/// Which account a transcript with no account recorded belongs to. Claude Code only started writing the
/// organization into transcripts in early October 2026; older sessions all landed on the signed-in account, which
/// put months of Pro use on a Team account opened in October. The Claude desktop app logs each account's 5-hour
/// usage over time, so a response is a vote for whichever single account's usage rose within 3 hours after it.
enum AccountGuess {
    /// The account most votes point to, when there's enough evidence (at least 3 votes and 3 in 4 agreeing);
    /// nil otherwise, and the file stays with the signed-in account as before.
    static func org(times: [Date], history: [String: [PlanUsageLog.Sample]]) -> String? {
        guard !history.isEmpty, !times.isEmpty else { return nil }
        var votes: [String: Int] = [:]
        for t in times {
            let rising = history.filter { rose($0.value, after: t) }.map(\.key)
            if rising.count == 1 { votes[rising[0], default: 0] += 1 }
        }
        let total = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 3, Double(best.value) >= 0.75 * Double(total) else { return nil }
        return best.key
    }

    /// The account a desktop-app session belonged to, when only one account had appeared in the desktop app by the
    /// session's last response. `desktopFirst`: when each account first shows up there.
    static func desktopAccount(times: [Date], desktopFirst: [String: Date]) -> String? {
        guard let last = times.max() else { return nil }
        let there = desktopFirst.filter { $0.value <= last }.map(\.key)
        return there.count == 1 ? there[0] : nil
    }

    /// Whether a reading within 3 hours after `t` shows the 5-hour usage higher than the reading before it.
    static func rose(_ samples: [PlanUsageLog.Sample], after t: Date) -> Bool {
        guard let i = samples.firstIndex(where: { $0.time > t }), i > 0 else { return false }
        var j = i
        while j < samples.count, samples[j].time.timeIntervalSince(t) <= 3 * 3600 {
            if samples[j].fiveHour > samples[j - 1].fiveHour { return true }
            j += 1
        }
        return false
    }
}
