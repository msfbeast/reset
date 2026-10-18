import Foundation

/// One billed Claude API response, after de-duplication.
struct Call: Codable {
    var id: String
    var time: Date
    var model: String
    var session: String
    var project: String
    var sidechain: Bool
    var input: Int
    var cw5: Int
    var cw1h: Int
    var cacheRead: Int
    var output: Int
    var advisorTokens: Int
    var tools: Int
    var mcpServers: [String: Int]
    var webSearches: Int
    var mcpAttribution: String?
    var cost: Double
    var autoStart: Bool
    /// The Claude organization (account) the session ran under, when its transcript says. Optional for old caches.
    var org: String? = nil

    var totalTokens: Int { input + cw5 + cw1h + cacheRead + output + advisorTokens }
    var mcpCalls: Int { mcpServers.values.reduce(0, +) }
}

/// Reads token usage from Claude Code transcripts. Streaming writes one row per content block with the
/// same message id; earlier rows carry placeholder output counts, so the row with the largest output wins.
/// Resumed and forked sessions copy rows between files, so de-duplication is global.
final class ClaudeUsageScanner {
    struct FileResult: Codable {
        var mtime: Date
        var size: Int
        var calls: [Call]
        var titles: [String: String]
        var limitHits: [Date]
        var apiMillis: [String: Int]
        /// Bytes parsed so far, always at a line boundary. Transcripts only grow, so the next scan starts here.
        var offset: Int = 0
        /// What couldn't be read. Optional so caches written before it existed still decode.
        var health: FormatHealth?
        /// The account the transcript's session ran under (its credential rows), for per-account costs.
        var org: String?
        /// Whether all of the file has been searched for `org`. Subagent transcripts have none, and were searched
        /// again, end to end, on every scan. Optional so caches written before it existed still decode.
        var orgSearched: Bool?
        /// Where the session ran ("cli", "claude-desktop" for the desktop app's Code tab). For sessions with no
        /// account recorded, the desktop app's own records then say which account it was.
        var entrypoint: String?
        /// Claude Code's "limit reached" rows: when each was seen and the exact reset it named. Optional so older
        /// caches decode.
        var resets: [LimitReset]?
    }

    /// An exact 5-hour reset from a "limit reached" row, and the account it was for (stamped when combining).
    struct LimitReset: Codable, Equatable {
        var seen: Date
        var resetsAt: Date
        var org: String? = nil
    }

    /// Rows in one transcript that looked like usage but couldn't be read. Claude Code changing how it writes
    /// its logs is the one way Reset can silently go wrong, so this is counted rather than skipped quietly.
    struct FormatHealth: Codable, Equatable {
        /// Complete lines read.
        var lines = 0
        /// Assistant rows judged, readable or not.
        var checked = 0
        /// FormatProblem raw value to count.
        var problems: [String: Int] = [:]
        /// Claude Code version on the last assistant row read, for "since version X" in the warning.
        var version: String?

        mutating func add(_ o: FormatHealth) {
            lines += o.lines
            checked += o.checked
            problems.merge(o.problems, uniquingKeysWith: +)
            if o.version != nil { version = o.version }
        }
    }

    enum FormatProblem: String, CaseIterable {
        case unreadableRow = "unreadable_row"
        case noTimestamp = "no_timestamp"
        case noMessage = "no_message"
        case missingFields = "missing_fields"
        case usageShape = "usage_shape"
        case unknownLimit = "unknown_limit"

        var phrase: String {
            switch self {
            case .unreadableRow: return "rows that aren't valid JSON"
            case .noTimestamp: return "rows without a readable timestamp"
            case .noMessage: return "responses without a message"
            case .missingFields: return "responses missing their id, model or token counts"
            case .usageShape: return "token counts in an unexpected shape"
            case .unknownLimit: return "limit messages of a kind Reset doesn't know"
            }
        }
    }

    /// The limit kinds Reset understands in `quotaLimits.rateLimitType`.
    static let knownLimitTypes: Set<String> = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    private var cache: [String: FileResult] = [:]
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reset", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // v3: cache writes on multi-iteration responses are counted in full; cached numbers from v2 would keep the gap.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("claude-usage-cache-v2.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("claude-usage-cache-v3.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("claude-usage-cache-v4.json"))
        // v5: also each "limit reached" row's exact reset, and only refused requests count as limit hits.
        return dir.appendingPathComponent("claude-usage-cache-v5.json")
    }()
    private var loadedDisk = false
    /// Saving rewrites the whole cache (about 50 MB of JSON for a month of heavy use), and some transcript grows
    /// between almost every two scans. After a restart, what was appended since the last save is read again from
    /// the saved offsets, so saving at most hourly loses nothing.
    private var savedAt = Date.distantPast
    private var unsaved = false
    static let saveEvery: TimeInterval = 3600

    struct Result {
        var calls: [Call]
        var titles: [String: String]
        var limitHits: [Date]
        var apiMillis: [String: Int]
        var format = FormatReport()
        var resets: [LimitReset] = []
    }

    /// Called with the number of files parsed so far during a scan that has real work to do.
    var progress: ((Int) -> Void)?

    func scan(since: Date) -> Result {
        var done = 0
        if !loadedDisk {
            loadedDisk = true
            // The v1 cache had no read offsets; v2 replaces it.
            try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent().appendingPathComponent("claude-usage-cache-v1.json"))
            if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode([String: FileResult].self, from: d) { cache = c }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent(".claude/projects"),
                     home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")]
        var seen: Set<String> = []
        var changed = false
        var results: [FileResult] = []
        // For files with no account recorded; read once per scan.
        let history = PlanUsageLog.history()
        var paths: [String] = []
        func attributed(_ r: FileResult, _ path: String) -> FileResult {
            paths.append(path)
            guard r.org == nil, let org = Self.desktopOrg(path) else { return r }
            var r = r; r.org = org
            return r
        }
        for root in roots {
            // The Claude desktop app keeps each session's transcripts under a hidden ".claude" folder, so skipping
            // hidden files there skipped every one of them.
            let desktop = root.path.contains("local-agent-mode-sessions")
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                         options: desktop ? [] : [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent != "audit.jsonl" {
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mod = rv?.contentModificationDate, mod >= since else { continue }
                let size = rv?.fileSize ?? 0
                seen.insert(url.path)
                // Fresh within 2 s: mtime round-trips through JSON and filesystems differ in precision,
                // so exact Date equality could miss on an unchanged file and force a needless re-parse.
                // A recent file cached before format checks existed is read once more, so the check covers it.
                let needsHealth = cache[url.path]?.health == nil && mod > Date().addingTimeInterval(-Self.recentWindow)
                if var c = cache[url.path], abs(c.mtime.timeIntervalSince(mod)) < 2, c.size == size, !needsHealth {
                    // Cached before accounts were tracked: a quick text search finds the org, once, no re-parse needed.
                    if c.org == nil, c.orgSearched != true {
                        c.org = TranscriptScanner.lastOrg(url, from: 0, size: size)
                        c.orgSearched = true
                        cache[url.path] = c; changed = true
                    }
                    results.append(attributed(c, url.path)); continue
                }
                var r: FileResult
                // Appending to a result without health would leave the check counting only the new rows.
                if let c = cache[url.path], size > c.offset, c.offset > 0, c.health != nil {
                    // Appended to since last time: parse only the new bytes and merge.
                    r = Self.merge(c, Self.parse(url, mtime: mod, size: size, from: c.offset))
                } else {
                    r = Self.parse(url, mtime: mod, size: size, from: 0)
                }
                done += 1
                if done % 10 == 0 { progress?(done) }
                cache[url.path] = r
                results.append(attributed(r, url.path))
                changed = true
            }
        }
        if changed {
            cache = cache.filter { seen.contains($0.key) }
            unsaved = true
        }
        // A failed save (a full disk, say) is tried again next scan.
        if Date().timeIntervalSince(savedAt) >= Self.saveEvery { saveIfNeeded() }
        // When each account first shows up in the desktop app: its Cowork sessions (account in the folder) and its
        // own usage readings. A desktop-app session with no account recorded, from before a second account appeared
        // there, can only be the one that was.
        var desktopFirst: [String: Date] = [:]
        for (r, p) in zip(results, paths) where p.contains("local-agent-mode-sessions") {
            if let o = r.org, let t = r.calls.map(\.time).min() { desktopFirst[o] = min(desktopFirst[o] ?? t, t) }
        }
        for (o, samples) in history { if let t = samples.first?.time { desktopFirst[o] = min(desktopFirst[o] ?? t, t) } }
        results = results.map { r in
            guard r.org == nil else { return r }
            var r = r
            let times = r.calls.map(\.time)
            r.org = (r.entrypoint == "claude-desktop" ? AccountGuess.desktopAccount(times: times, desktopFirst: desktopFirst) : nil)
                ?? AccountGuess.org(times: times, history: history)
            return r
        }
        var r = Self.combine(results, since: since)
        r.format = Self.formatReport(results, recentSince: Date().addingTimeInterval(-Self.recentWindow))
        return r
    }

    /// The account a Claude desktop app session belongs to, from its folder:
    /// local-agent-mode-sessions/<install>/<organization>/local_<session>/… Those transcripts record no account.
    static func desktopOrg(_ path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        guard let i = parts.firstIndex(of: "local-agent-mode-sessions"), i + 2 < parts.count else { return nil }
        let org = parts[i + 2].lowercased()
        return org.count == 36 && org.filter({ $0 == "-" }).count == 4 ? org : nil
    }

    /// Writes the cache if anything changed since the last save. Run on the scan queue: hourly from `scan`, and
    /// when Reset quits, so a quit or an update doesn't make the next launch re-read up to an hour of appends.
    func saveIfNeeded() {
        guard unsaved, let d = try? JSONEncoder().encode(cache), (try? d.write(to: cacheURL, options: .atomic)) != nil else { return }
        savedAt = Date()
        unsaved = false
    }

    // MARK: Format check

    /// How far back the format check looks: long enough to have real activity, short enough that a new
    /// Claude Code version shows up instead of being averaged away by weeks of older, healthy logs.
    static let recentWindow: TimeInterval = 48 * 3600

    struct FormatReport: Equatable {
        enum Verdict: String { case ok, problems, noRows = "no_rows", tooQuiet = "too_quiet" }
        var verdict: Verdict = .tooQuiet
        var lines = 0
        var checked = 0
        var problems: [String: Int] = [:]
        var version: String?
        var problemCount: Int { problems.values.reduce(0, +) }

        /// One sentence for Settings and the self-test.
        var summary: String {
            let since = version.map { " (Claude Code \($0))" } ?? ""
            switch verdict {
            case .tooQuiet:
                return "Not enough recent Claude Code activity to check the log format."
            case .ok:
                return "Claude Code logs read normally: \(checked) responses in the last 2 days\(since)."
            case .noRows:
                return "Claude Code wrote \(lines) log lines in the last 2 days but Reset found no usage in them\(since). Its log format may have changed, so usage, cost and window estimates may be missing."
            case .problems:
                let worst = problems.max { $0.value < $1.value }
                let what = worst.flatMap { FormatProblem(rawValue: $0.key)?.phrase } ?? "rows"
                return "Reset couldn't read \(problemCount) of \(checked) recent Claude Code responses, mostly \(what)\(since). Its log format may have changed, so usage and cost may be undercounted."
            }
        }
    }

    /// Thresholds, from a baseline of zero problems in 36,500 real responses over 30 days: a few unreadable
    /// rows are already unusual, but one stray row shouldn't raise an alarm.
    static let minLines = 200, minProblems = 3, problemShare = 0.02, noRowsLines = 500

    /// Judges the files written to recently. Pure, so it's tested directly.
    static func formatReport(_ results: [FileResult], recentSince: Date) -> FormatReport {
        var total = FormatHealth()
        var newest: (Date, String)?
        for r in results where r.mtime >= recentSince {
            guard let h = r.health else { continue }
            total.add(h)
            if let v = h.version, newest.map({ r.mtime > $0.0 }) ?? true { newest = (r.mtime, v) }
        }
        var out = FormatReport(lines: total.lines, checked: total.checked, problems: total.problems, version: newest?.1)
        if total.lines < minLines {
            out.verdict = .tooQuiet
        } else if total.checked == 0 && total.lines >= noRowsLines {
            // Lots of logging and not one assistant row: the row marker itself changed, so nothing else could catch it.
            out.verdict = .noRows
        } else if out.problemCount >= minProblems, Double(out.problemCount) >= problemShare * Double(max(1, total.checked)) {
            out.verdict = .problems
        } else {
            out.verdict = .ok
        }
        return out
    }

    /// Global de-duplication by message id across files: keep the copy with the most output,
    /// attributed to the earliest time seen.
    static func combine(_ results: [FileResult], since: Date) -> Result {
        var best: [String: Call] = [:]
        var titles: [String: String] = [:]
        var hits: [Date] = []
        var resets: [LimitReset] = []
        var api: [String: Int] = [:]
        for r in results {
            for var c in r.calls {
                c.org = r.org
                if let b = best[c.id] {
                    if c.output > b.output { var n = c; n.time = min(c.time, b.time); best[c.id] = n }
                    else if c.time < b.time { var n = b; n.time = c.time; best[c.id] = n }
                } else { best[c.id] = c }
            }
            titles.merge(r.titles) { a, _ in a }
            hits += r.limitHits
            resets += (r.resets ?? []).map { var x = $0; x.org = r.org; return x }
            api.merge(r.apiMillis) { max($0, $1) }
        }
        return Result(calls: best.values.filter { $0.time >= since }.sorted { $0.time < $1.time },
                      titles: titles, limitHits: hits.sorted(), apiMillis: api, resets: resets.sorted { $0.seen < $1.seen })
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func merge(_ old: FileResult, _ new: FileResult) -> FileResult {
        var byId = Dictionary(old.calls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in new.calls {
            if let b = byId[c.id] {
                var n = c.output >= b.output ? c : b
                // The same call seen again (same output, same time) is not new content: keep its counts,
                // so merging a full re-parse into the cache can't inflate tools or MCP calls.
                // Genuinely appended rows of a streamed response still accumulate.
                if c.output == b.output && c.time == b.time {
                    n.tools = b.tools
                    n.mcpServers = b.mcpServers
                } else {
                    n.tools = b.tools + c.tools
                    n.mcpServers = b.mcpServers.merging(c.mcpServers, uniquingKeysWith: +)
                }
                n.time = min(b.time, c.time)
                byId[c.id] = n
            } else { byId[c.id] = c }
        }
        var out = new
        if var h = old.health, let n = new.health { h.add(n); out.health = h }
        out.org = new.org ?? old.org
        out.entrypoint = new.entrypoint ?? old.entrypoint
        // Only the new bytes were just searched; the rest counts only if it was searched before.
        if old.orgSearched != true { out.orgSearched = nil }
        out.calls = Array(byId.values)
        out.titles = old.titles.merging(new.titles) { _, b in b }
        out.limitHits = old.limitHits + new.limitHits
        out.resets = (old.resets ?? []) + (new.resets ?? [])
        out.apiMillis = old.apiMillis.merging(new.apiMillis) { max($0, $1) }
        return out
    }

    static func parse(_ url: URL, mtime: Date, size: Int, from start: Int) -> FileResult {
        // Searched up to `offset` for the org, as nothing past it is read.
        var out = FileResult(mtime: mtime, size: size, calls: [], titles: [:], limitHits: [], apiMillis: [:], offset: start,
                             health: FormatHealth(), orgSearched: true)
        guard let all = try? Data(contentsOf: url, options: .mappedIfSafe), all.count > start else { return out }
        // Read up to the size seen on disk, and stop at the last complete line in it;
        // a half-written last line is picked up next time.
        let end = min(all.count, max(size, start))
        guard end > start, let lastNewline = all[start..<end].lastIndex(of: UInt8(ascii: "\n")) else { return out }
        let data = all[start...lastNewline]
        out.offset = lastNewline + 1
        let isKickFile = url.path.contains("Application-Support-Reset-kick")
        let mAssistant = Data("\"type\":\"assistant\"".utf8)
        let mTitle = Data("-title\"".utf8)
        let mCost = Data("\"type\":\"cost-state\"".utf8)
        var bestById: [String: Call] = [:]
        var health = FormatHealth()
        func problem(_ p: FormatProblem) { health.problems[p.rawValue, default: 0] += 1 }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            health.lines += 1
            let isAssistant = line.range(of: mAssistant) != nil
            let isTitle = !isAssistant && line.range(of: mTitle) != nil
            let isCost = !isAssistant && line.range(of: mCost) != nil
            guard isAssistant || isTitle || isCost else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                if isAssistant { health.checked += 1; problem(.unreadableRow) }
                continue
            }
            // Only top-level assistant rows are judged; the marker can also sit inside other rows' JSON.
            let judged = isAssistant && (obj["type"] as? String) == "assistant"
            if judged {
                health.checked += 1
                if let v = obj["version"] as? String { health.version = v }
                if let e = obj["entrypoint"] as? String { out.entrypoint = e }
            }
            let session = obj["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent
            if isTitle {
                if let t = obj["customTitle"] as? String { out.titles[session] = t }
                else if let t = obj["aiTitle"] as? String, out.titles[session] == nil { out.titles[session] = t }
                continue
            }
            if isCost {
                if let ms = obj["totalAPIDuration"] as? Int { out.apiMillis[session] = max(out.apiMillis[session] ?? 0, ms) }
                continue
            }
            guard let ts = (obj["timestamp"] as? String).flatMap({ isoFrac.date(from: $0) }) else {
                if judged { problem(.noTimestamp) }
                continue
            }
            if let q = obj["quotaLimits"] as? [String: Any] {
                if judged, !Self.knownLimitTypes.contains(q["rateLimitType"] as? String ?? "") { problem(.unknownLimit) }
                if (q["rateLimitType"] as? String) == "five_hour" {
                    // Only a refused request is a limit hit; the same row also reports warnings and allowed states.
                    if (q["status"] as? String) == "rejected" {
                        out.limitHits.append(ts)
                        if let r = q["resetsAt"] as? Double {
                            out.resets = (out.resets ?? []) + [LimitReset(seen: ts, resetsAt: Date(timeIntervalSince1970: r))]
                        }
                    }
                    continue
                }
            }
            if (obj["isApiErrorMessage"] as? Bool) == true { continue }
            guard let msg = obj["message"] as? [String: Any] else {
                if judged { problem(.noMessage) }
                continue
            }
            // Synthetic rows (slash-command echoes) carry no real usage by design.
            if (msg["model"] as? String) == "<synthetic>" { continue }
            guard let id = msg["id"] as? String, let model = msg["model"] as? String,
                  let u = msg["usage"] as? [String: Any] else {
                if judged { problem(.missingFields) }
                continue
            }
            // Token counts that stopped being plain integers would otherwise read as zero, silently.
            if judged, !(u["input_tokens"] is Int) || !(u["output_tokens"] is Int) { problem(.usageShape) }
            func i(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? Int) ?? 0 }
            let cc = u["cache_creation"] as? [String: Any]
            var cw5 = i(cc, "ephemeral_5m_input_tokens"), cw1h = i(cc, "ephemeral_1h_input_tokens")
            if cc == nil { cw5 = i(u, "cache_creation_input_tokens") }
            // With several iterations (an advisor turn) the 5m/1h split covers only the first one, while the total
            // covers them all; the rest is counted at the 5-minute rate instead of being dropped.
            let written = i(u, "cache_creation_input_tokens")
            if written > cw5 + cw1h { cw5 += written - cw5 - cw1h }
            let input = i(u, "input_tokens"), cr = i(u, "cache_read_input_tokens"), output = i(u, "output_tokens")
            var cost = Pricing.claude(model).map { Pricing.cost($0, input: input, cw5: cw5, cw1h: cw1h, cacheRead: cr, output: output) } ?? 0
            // Advisor calls are billed separately and only appear in `iterations`.
            var advisorTokens = 0
            for it in u["iterations"] as? [[String: Any]] ?? [] where (it["type"] as? String) == "advisor_message" {
                let am = it["model"] as? String ?? model
                let ai = i(it, "input_tokens"), ao = i(it, "output_tokens"), acr = i(it, "cache_read_input_tokens")
                let acc = it["cache_creation"] as? [String: Any]
                let a5 = i(acc, "ephemeral_5m_input_tokens"), a1 = i(acc, "ephemeral_1h_input_tokens")
                advisorTokens += ai + ao + acr + a5 + a1
                if let p = Pricing.claude(am) { cost += Pricing.cost(p, input: ai, cw5: a5, cw1h: a1, cacheRead: acr, output: ao) }
            }
            var tools = 0, web = (u["server_tool_use"] as? [String: Any]).map { i($0, "web_search_requests") } ?? 0
            var servers: [String: Int] = [:]
            for block in msg["content"] as? [[String: Any]] ?? [] {
                guard let type = block["type"] as? String else { continue }
                if type == "tool_use", let name = block["name"] as? String {
                    tools += 1
                    if name.hasPrefix("mcp__") {
                        let server = name.dropFirst(5).components(separatedBy: "__").first ?? "mcp"
                        servers[server, default: 0] += 1
                    }
                    if name == "WebSearch" { web += 1 }
                }
            }
            let call = Call(id: id, time: ts, model: model, session: session, project: obj["cwd"] as? String ?? "",
                            sidechain: (obj["isSidechain"] as? Bool) ?? false, input: input, cw5: cw5, cw1h: cw1h,
                            cacheRead: cr, output: output, advisorTokens: advisorTokens, tools: tools, mcpServers: servers,
                            webSearches: web, mcpAttribution: obj["attributionMcpServer"] as? String, cost: cost,
                            autoStart: isKickFile)
            if let b = bestById[id] {
                // Same response streamed over several rows: tools accumulate, usage takes the final row.
                var n = call.output >= b.output ? call : b
                n.tools = b.tools + call.tools
                n.mcpServers = b.mcpServers.merging(call.mcpServers, uniquingKeysWith: +)
                n.webSearches = max(b.webSearches, call.webSearches)
                n.time = min(b.time, call.time)
                bestById[id] = n
            } else {
                bestById[id] = call
            }
        }
        out.calls = Array(bestById.values)
        out.health = health
        out.org = TranscriptScanner.lastOrg(url, from: start, size: size)
        return out
    }
}
