import Foundation

/// Made-up usage for screenshots and screen recordings: `open -a Reset --args -demo YES`.
/// Nothing is read from disk and no alerts or auto-starts fire while it is on.
enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    /// Shown instead of the real budget.json, so screenshots never carry a real task name.
    static let budget = Budget(task: "API rate limiter", maxPercent: 70, downshiftModel: "haiku",
                               setAt: Date(timeIntervalSince1970: 1_772_442_000))

    static let projects: [(String, String, Double)] = [
        ("/Users/demo/Developer/landing-page", "Landing page redesign", 1.0),
        ("/Users/demo/Developer/ios-onboarding", "iOS onboarding flow", 0.8),
        ("/Users/demo/Developer/api-server", "API rate limiter", 0.65),
        ("/Users/demo/Videos/launch-video", "Launch video edit", 0.5),
        ("/Users/demo/Developer/design-system", "Design system tokens", 0.4),
        ("/Users/demo/Writing/newsletter", "Weekly newsletter", 0.25),
        ("/Users/demo/Developer/cli-tool", "CLI release script", 0.2),
    ]

    /// Sessions behave like real ones, so "where your window went" looks right in screenshots: context grows turn by
    /// turn, a few long breaks a session make it re-read, now and then a model switch rebuilds it mid-session, and
    /// once in a while a command fails a few times in a row. Subagents run in their own threads with small contexts.
    static func calls(now: Date = Date()) -> (calls: [Call], titles: [String: String], limitHits: [Date], api: [String: Int], failed: Set<String>) {
        var rng = SeededRandom(seed: 42)
        var calls: [Call] = [], titles: [String: String] = [:], hits: [Date] = [], api: [String: Int] = [:]
        var failed: Set<String> = []
        let cal = Calendar.current
        for dayBack in stride(from: 29, through: 0, by: -1) {
            let day = cal.startOfDay(for: now.addingTimeInterval(-Double(dayBack) * 86400))
            if rng.next() < 0.18 && dayBack > 0 { continue }   // a few days off
            let sessions = 1 + Int(rng.next() * 3)
            for s in 0..<sessions {
                let p = projects[Int(rng.next() * Double(projects.count)) % projects.count]
                let id = "demo-\(dayBack)-\(s)"
                titles[id] = p.1
                let startHour = [10.0, 13.5, 16.0, 21.5, 23.0][Int(rng.next() * 5) % 5] + rng.next()
                var t = day.addingTimeInterval(startHour * 3600)
                let n = 120 + Int(rng.next() * 900 * p.2)
                let breaks = Set((0..<(1 + Int(rng.next() * 3))).map { _ in 30 + Int(rng.next() * Double(max(1, n - 40))) })
                let bustAt = rng.next() < 0.3 ? 20 + Int(rng.next() * Double(max(1, n - 30))) : -1
                let loopAt = rng.next() < 0.2 ? 10 + Int(rng.next() * Double(max(1, n - 20))) : -1
                var context = 25_000 + Int(rng.next() * 20_000), subagent = 0
                var model = "claude-opus-5-5"
                for k in 0..<n {
                    let gap = breaks.contains(k) ? 3600 * (1.2 + rng.next() * 1.5) : 20 + rng.next() * 70
                    t = t.addingTimeInterval(gap)
                    if t > now { break }
                    let side = rng.next() < 0.18
                    var cr: Int, cw: Int, m = model
                    if side {
                        m = rng.next() < 0.5 ? "claude-sonnet-5-5" : "claude-opus-5-5"
                        cr = subagent; cw = Int(1_000 + rng.next() * 6_000); subagent = min(cr + cw, 60_000)
                    } else {
                        if k == bustAt { model = "claude-sonnet-5-5"; m = model }
                        if gap > 3600 { cr = 0; cw = context }                                  // back after the cache expired
                        else if k == bustAt { cr = context / 6; cw = context - cr }               // a switch rebuilds it
                        else { cr = context; cw = rng.next() < 0.06 ? Int(12_000 + rng.next() * 30_000) : Int(150 + rng.next() * 1_200) }
                        context = min(cr + cw, 420_000)
                    }
                    let out = Int(200 + rng.next() * 2400)
                    let cost = Pricing.claude(m).map { Pricing.cost($0, input: 3, cw5: 0, cw1h: cw, cacheRead: cr, output: out) } ?? 0
                    let mcp: [String: Int] = rng.next() < 0.08 ? [["github", "figma", "linear"][Int(rng.next() * 3) % 3]: 1] : [:]
                    let callId = "\(id)-\(k)"
                    var uses: [Call.ToolUse]? = rng.next() < 0.6 ? [.init(id: "\(callId)-t", name: ["Read", "Edit", "Bash", "Grep"][Int(rng.next() * 4) % 4])] : nil
                    if loopAt >= 0, !side, (loopAt..<loopAt + 4).contains(k) {
                        uses = [.init(id: "\(callId)-t", name: "Bash")]; failed.insert("\(callId)-t")
                    }
                    calls.append(Call(id: callId, time: t, model: m, session: id, project: p.0, sidechain: side,
                                      input: 3, cw5: 0, cw1h: cw, cacheRead: cr, output: out, advisorTokens: 0,
                                      tools: uses?.count ?? 0, mcpServers: mcp, webSearches: rng.next() < 0.02 ? 1 : 0,
                                      mcpAttribution: mcp.keys.first, cost: cost, autoStart: k == 0 && rng.next() < 0.15,
                                      thread: side ? "\(id)-agent.jsonl" : "\(id).jsonl", toolUses: uses))
                }
                api[id] = Int(Double(n) * 9_000)
            }
            if rng.next() < 0.25 && dayBack > 0 { hits.append(day.addingTimeInterval(17 * 3600)) }
        }
        return (calls.sorted { $0.time < $1.time }, titles, hits, api, failed)
    }

    static func claude(now: Date = Date()) -> WindowStatus {
        WindowStatus(id: "claude", name: "Claude", state: .active(resetsAt: now.addingTimeInterval(2 * 3600 + 41 * 60)),
                     usedPercent: 38, isEstimate: false, source: "Live from your Claude account", secondary: nil, canAutoStart: true)
    }
}

/// Small deterministic generator so demo data is the same every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
