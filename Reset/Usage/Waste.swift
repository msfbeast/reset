import Foundation

/// Where the window went: usage that re-did work it didn't have to. Worked out only from token counts, times, tool
/// ids and compaction times, never from what was said. Pure, so every rule is tested.
///
/// Measured on real transcripts before it was built: about a fifth of spend went on re-reading context, almost all of
/// it from coming back to a long session after its cache had expired. The rules below are the ones that held up:
/// a cache bust is a turn that reused much less than the last one had cached (a large write alone is usually just a
/// big file being read), and a loop is the same tool failing several times in a row (an identical input repeated
/// almost never happens; Claude changes the command a little each time).
enum Waste {
    // MARK: Heuristics, named for tuning

    /// A cache write smaller than this isn't worth flagging.
    static let minRewrite = 10_000
    /// A bust needs the previous turn to have had at least this much context to lose.
    static let minContextForBust = 20_000
    /// A bust: this turn reused less than this share of what the previous one had cached.
    static let bustShare = 0.5
    /// A loop: the same tool failing this many times in a row.
    static let loopRun = 3
    /// "Could have been Sonnet" (an estimate, kept out of the total): Opus in a session this small…
    static let overkillTools = 3, overkillOutput = 2_000
    /// …or an Opus subagent turn writing less than this.
    static let overkillSubagentOutput = 1_000
    /// A compaction this close to a turn explains its rebuilt context.
    static let compactionSlack: TimeInterval = 5

    enum Kind: String, CaseIterable, Codable {
        case breaks, busts, loops, overkill

        var title: String {
            switch self {
            case .breaks: return "Coming back after a break"
            case .busts: return "Context changed mid-session"
            case .loops: return "Tools failing in a row"
            case .overkill: return "Opus where Sonnet would do"
            }
        }

        var tip: String {
            switch self {
            case .breaks: return "After a long break, start fresh, don't resume. Leaving for a while? /compact first, while the cache is warm."
            case .busts: return "Avoid editing CLAUDE.md, switching models or changing MCP servers in the middle of a session."
            case .loops: return "Tell Claude to stop and ask after two failed attempts."
            case .overkill: return "For small tasks and subagents, Sonnet is usually enough."
            }
        }
    }

    struct Top: Codable, Equatable { var session: String; var usd: Double }

    struct Bucket: Codable {
        var kind: Kind
        var usd = 0.0
        var tokens = 0
        var count = 0
        var top: [Top] = []
        /// Busts where the model changed from the previous turn.
        var modelSwitches = 0
    }

    struct Report: Codable {
        var spend: Double
        var buckets: [Bucket]

        func bucket(_ k: Kind) -> Bucket { buckets.first { $0.kind == k } ?? Bucket(kind: k) }
        /// Breaks, busts and loops. "Could have been Sonnet" is a judgement call, so it stays out.
        var total: Double { [Kind.breaks, .busts, .loops].reduce(0) { $0 + bucket($1).usd } }
        var share: Double { spend > 0 ? total / spend : 0 }
    }

    static func analyze(_ calls: [Call], since: Date, failed: Set<String>, compactions: [String: [Date]]) -> Report {
        var usd: [Kind: Double] = [:], tokens: [Kind: Int] = [:], count: [Kind: Int] = [:]
        var bySession: [Kind: [String: Double]] = [:]
        var switches = 0
        func add(_ k: Kind, _ c: Call, _ dollars: Double, tokens t: Int = 0) {
            usd[k, default: 0] += dollars; tokens[k, default: 0] += t; count[k, default: 0] += 1
            bySession[k, default: [:]][c.session, default: 0] += dollars
        }

        // Each transcript file is its own chain: a session's main thread and each of its subagents.
        var chains: [String: [Call]] = [:]
        for c in calls { chains["\(c.session)|\(c.thread ?? "")", default: []].append(c) }
        for (_, unsorted) in chains {
            let chain = unsorted.sorted { $0.time < $1.time }
            let compacted = compactions[chain.first?.thread ?? ""] ?? []
            for i in chain.indices.dropFirst() where chain[i].time >= since {
                let c = chain[i], prev = chain[i - 1]
                guard let p = Pricing.claude(c.model) else { continue }
                let written = c.cw5 + c.cw1h
                guard written >= minRewrite else { continue }
                // What a token written to cache costs over reading it back.
                let rate = (Double(c.cw5) * p.cacheWrite5m + Double(c.cw1h) * p.cacheWrite1h) / Double(written) - p.cacheRead
                let gap = c.time.timeIntervalSince(prev.time)
                let lifetime: TimeInterval = prev.cw1h > 0 ? 3600 : 300
                let prevContext = prev.cacheRead + prev.cw5 + prev.cw1h
                if gap > lifetime {
                    add(.breaks, c, Double(written) * rate / 1_000_000, tokens: written)
                } else if prevContext >= minContextForBust, Double(c.cacheRead) < bustShare * Double(prevContext),
                          !compacted.contains(where: { $0 >= prev.time.addingTimeInterval(-compactionSlack) && $0 <= c.time.addingTimeInterval(compactionSlack) }) {
                    let lost = min(written, prevContext - c.cacheRead)
                    add(.busts, c, Double(lost) * rate / 1_000_000, tokens: lost)
                    if c.model != prev.model { switches += 1 }
                }
            }
            // The same tool failing again and again: the turns from the loopRun-th failure until it stops.
            var tool: String?, run = 0
            for c in chain {
                var counted = false
                for u in c.toolUses ?? [] {
                    if failed.contains(u.id) { run = (u.name == tool) ? run + 1 : 1; tool = u.name } else { tool = nil; run = 0 }
                    if run >= loopRun, !counted, c.time >= since { add(.loops, c, c.cost); counted = true }
                }
            }
        }

        // Opus where Sonnet would likely have done, judged per session (main thread and subagents together).
        if let sonnet = Pricing.claude("claude-sonnet-5-5") {
            var sessions: [String: [Call]] = [:]
            for c in calls where c.time >= since { sessions[c.session, default: []].append(c) }
            for (_, cs) in sessions {
                let small = cs.reduce(0) { $0 + $1.tools } <= overkillTools && cs.reduce(0) { $0 + $1.output } < overkillOutput
                for c in cs where c.model.contains("opus") && (small || (c.sidechain && c.output < overkillSubagentOutput)) {
                    let extra = c.cost - Pricing.cost(sonnet, input: c.input, cw5: c.cw5, cw1h: c.cw1h, cacheRead: c.cacheRead, output: c.output)
                    if extra > 0 { add(.overkill, c, extra) }
                }
            }
        }

        let buckets = Kind.allCases.map { k in
            Bucket(kind: k, usd: usd[k] ?? 0, tokens: tokens[k] ?? 0, count: count[k] ?? 0,
                   top: (bySession[k] ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { Top(session: $0.key, usd: $0.value) },
                   modelSwitches: k == .busts ? switches : 0)
        }
        return Report(spend: calls.filter { $0.time >= since }.reduce(0) { $0 + $1.cost }, buckets: buckets)
    }
}

/// Big sessions whose cache is still warm, so Reset can say so before it expires. Coming back to a long session after
/// its cache has gone re-reads all of it at full price, and by then even /compact pays for that; compacting (or
/// having Claude write a handoff note) while it's still warm costs a small fraction. Worked out from token counts
/// and times only.
enum BreakGuard {
    /// A session's context must be at least this big to be worth a warning.
    static let minContext = 100_000
    /// Quiet while you're working: only once a session has been idle this long.
    static let quietFor: TimeInterval = 10 * 60
    /// The menu bar shows the countdown for this long before the cache expires.
    static let menuBarFor: TimeInterval = 15 * 60
    /// The heads-up goes out this long before.
    static let warnBefore: TimeInterval = 10 * 60
    /// Output tokens a /compact summary takes, for its rough price.
    static let compactOutput = 3_000

    struct Warm: Equatable {
        var session: String
        var project: String
        var context: Int
        var lastActivity: Date
        var expiresAt: Date
        /// Re-reading the context after the cache expires, at the cache-write price.
        var comeBackUSD: Double
        /// Compacting now: reading it from cache plus a summary.
        var compactUSD: Double
    }

    /// Sessions with a big context and a cache that hasn't expired at `now`, soonest to expire first. A session's
    /// cache lasts an hour from its last turn if it writes 1-hour cache (Claude Code's usual), else 5 minutes.
    static func warm(_ calls: [Call], now: Date) -> [Warm] {
        var last: [String: Call] = [:], longCache: Set<String> = []
        for c in calls where !c.sidechain && !c.autoStart {
            if c.cw1h > 0 { longCache.insert(c.session) }
            if let l = last[c.session], l.time >= c.time { continue }
            last[c.session] = c
        }
        return last.values.compactMap { c -> Warm? in
            let context = c.cacheRead + c.cw5 + c.cw1h + c.input
            guard context >= minContext, let p = Pricing.claude(c.model) else { return nil }
            let lifetime: TimeInterval = longCache.contains(c.session) ? 3600 : 300
            let expires = c.time.addingTimeInterval(lifetime)
            guard expires > now else { return nil }
            let write = longCache.contains(c.session) ? p.cacheWrite1h : p.cacheWrite5m
            return Warm(session: c.session, project: c.project, context: context, lastActivity: c.time, expiresAt: expires,
                        comeBackUSD: Double(context) * write / 1_000_000,
                        compactUSD: (Double(context) * p.cacheRead + Double(compactOutput) * p.output) / 1_000_000)
        }
        .sorted { $0.expiresAt < $1.expiresAt }
    }
}
