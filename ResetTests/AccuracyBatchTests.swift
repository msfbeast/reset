import XCTest
@testable import Reset

/// The numbers an independent count of the transcripts found wrong: desktop-app sessions skipped, old sessions
/// with no account put on the signed-in one, plans charged for days an account didn't exist, a cache-write gap and
/// reset times shown a minute early.
final class AccuracyBatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    func testDesktopSessionsGetTheAccountFromTheirFolder() {
        let path = "/Users/x/Library/Application Support/Claude/local-agent-mode-sessions/2d9c94d6-bfb5-400e-937c-81d56f1ccc87/"
            + "6AC79BDB-beee-4e0e-91af-d8977a22ec44/local_7a59/.claude/projects/p/s.jsonl"
        XCTAssertEqual(ClaudeUsageScanner.desktopOrg(path), "6ac79bdb-beee-4e0e-91af-d8977a22ec44", "lower-cased, as accounts are")
        XCTAssertNil(ClaudeUsageScanner.desktopOrg("/Users/x/.claude/projects/p/s.jsonl"), "Claude Code's own transcripts")
        XCTAssertNil(ClaudeUsageScanner.desktopOrg("/a/local-agent-mode-sessions/install/not-an-org/x.jsonl"))
    }

    private func samples(_ rows: [(minutesFromNow: Double, fiveHour: Double)]) -> [PlanUsageLog.Sample] {
        rows.map { .init(time: now.addingTimeInterval($0.minutesFromNow * 60), fiveHour: $0.fiveHour, sevenDay: nil) }
    }

    func testAnUntaggedSessionGoesToTheAccountWhoseUsageRoseAfterIt() {
        // Pro's 5-hour usage climbs through the session; Team's stays flat.
        let history = ["pro": samples([(-60, 10), (30, 20), (90, 35)]), "team": samples([(-60, 5), (30, 5), (90, 5)])]
        let times = (0..<5).map { now.addingTimeInterval(Double($0) * 300) }
        XCTAssertEqual(AccountGuess.org(times: times, history: history), "pro")
        XCTAssertNil(AccountGuess.org(times: Array(times.prefix(2)), history: history), "two votes aren't enough")
        let both = ["pro": history["pro"]!, "team": samples([(-60, 5), (30, 9), (90, 12)])]
        XCTAssertNil(AccountGuess.org(times: times, history: both), "both rising says nothing")
        XCTAssertNil(AccountGuess.org(times: times, history: [:]), "no desktop history: stays with the signed-in account")
    }

    func testAnOldDesktopSessionBelongsToTheOnlyAccountTheDesktopAppHadThen() {
        // Pro in the desktop app since July; Team only from October 7.
        let first = ["pro": now.addingTimeInterval(-90 * 86400), "team": now.addingTimeInterval(-12 * 86400)]
        XCTAssertEqual(AccountGuess.desktopAccount(times: [now.addingTimeInterval(-30 * 86400)], desktopFirst: first), "pro")
        XCTAssertNil(AccountGuess.desktopAccount(times: [now.addingTimeInterval(-5 * 86400)], desktopFirst: first),
                     "with both there, it could be either")
        XCTAssertNil(AccountGuess.desktopAccount(times: [now.addingTimeInterval(-100 * 86400)], desktopFirst: first),
                     "before any account shows up, nothing to go on")
    }

    func testEachAccountsPlanCountsFromItsFirstResponse() {
        // Team ($25) started 10 days ago, Pro ($20) 90 days ago; over the last 30 days Pro pays 30 days, Team 10.
        let first = ["team": now.addingTimeInterval(-10 * 86400), "pro": now.addingTimeInterval(-90 * 86400)]
        let month = UsageStore.planCost(prices: [("team", 25), ("pro", 20)], first: first, since: now.addingTimeInterval(-30 * 86400), now: now)
        XCTAssertEqual(month, 25 * 10 / 30 + 20, accuracy: 0.01)
        let all = UsageStore.planCost(prices: [("team", 25), ("pro", 20)], first: first, since: .distantPast, now: now)
        XCTAssertEqual(all, 25 * 10 / 30 + 20 * 90 / 30, accuracy: 0.01)
    }

    func testResetTimesRoundToTheMinute() {
        let justBefore = Date(timeIntervalSinceReferenceDate: 600 * 1000 - 0.32)
        XCTAssertEqual(LiveClaude.roundedToMinute(justBefore), Date(timeIntervalSinceReferenceDate: 600 * 1000), "19:09:59.68 is 19:10")
        let justAfter = Date(timeIntervalSinceReferenceDate: 600 * 1000 + 0.06)
        XCTAssertEqual(LiveClaude.roundedToMinute(justAfter), Date(timeIntervalSinceReferenceDate: 600 * 1000))
    }

    func testCacheWritesBeyondTheFirstIterationAreCounted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The total says 6,389 written; the 5m/1h split only covers the first iteration's 3,388.
        let row = #"{"type":"assistant","timestamp":"2026-10-12T10:00:00.000Z","sessionId":"s","cwd":"/tmp/p","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":3,"output_tokens":40,"cache_read_input_tokens":0,"cache_creation_input_tokens":6389,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":3388}}}}"#
        let u = dir.appendingPathComponent("a.jsonl")
        try (row + "\n").write(to: u, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(u.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let c = try XCTUnwrap(ClaudeUsageScanner.parse(u, mtime: Date(), size: size, from: 0).calls.first)
        XCTAssertEqual(c.cw5 + c.cw1h, 6389)
        XCTAssertEqual(c.cw1h, 3388, "the known 1-hour part keeps its rate")
    }
}

/// Windows on the dashboard and the weekly limit's wording: placed from exact resets, per account, and a guessed
/// lift time never shown as exact.
final class WindowAccuracyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func call(_ minutesAgo: Double, org: String?) -> Call {
        Call(id: UUID().uuidString, time: now.addingTimeInterval(-minutesAgo * 60), model: "claude-opus-5-5", session: "s-\(org ?? "")",
             project: "/tmp/p", sidechain: false, input: 0, cw5: 0, cw1h: 0, cacheRead: 0, output: 1, advisorTokens: 0, tools: 0,
             mcpServers: [:], webSearches: 0, mcpAttribution: nil, cost: 0, autoStart: false, org: org)
    }

    func testAnExactResetPlacesItsWindowAndOnlyMarksThatAccount() {
        // Team's first call at -240 min would floor to its own start, but a limit row says Team resets at +120 min:
        // the window opened (outside Claude Code) at -180 min.
        let reset = ClaudeUsageScanner.LimitReset(seen: now, resetsAt: now.addingTimeInterval(120 * 60), org: "team")
        let w = UsageStore.windows([call(170, org: "team"), call(170, org: "pro")], resets: [reset], since: now.addingTimeInterval(-86400))
        let team = w.first { $0.account == "team" }, pro = w.first { $0.account == "pro" }
        XCTAssertEqual(team?.end, reset.resetsAt)
        XCTAssertEqual(team?.hitLimit, true)
        XCTAssertEqual(pro?.hitLimit, false, "Team's limit isn't Pro's")
    }

    func testPastWindowsDontMoveWhenThePeriodShown() {
        let calls = [call(26 * 60, org: "t"), call(23 * 60 + 30, org: "t"), call(60, org: "t")]
        let wide = UsageStore.windows(calls, since: now.addingTimeInterval(-3 * 86400))
        let narrow = UsageStore.windows(calls, since: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(Set(narrow.map(\.start)).isSubset(of: Set(wide.map(\.start))), true,
                       "starting the chain at the period's edge used to shift a window that straddled it")
    }

    func testAGuessedWeeklyLiftReadsAsAbout() {
        var s = WindowStatus(id: "claude-pro", name: "Claude · Pro", state: .ready, usedPercent: nil, isEstimate: true, source: "",
                             secondary: nil, canAutoStart: false)
        s.blockedUntil = now.addingTimeInterval(86400)
        s.blockedEstimate = true
        let g = MenuBarGlance.make(ready: nil, soonest: nil, blocked: s, runsOutAt: nil, signedOut: false, now: now)
        XCTAssertTrue(g?.text.contains("~") == true)
        XCTAssertTrue(g?.spoken.contains("until about") == true)
        s.blockedEstimate = false
        XCTAssertFalse(MenuBarGlance.make(ready: nil, soonest: nil, blocked: s, runsOutAt: nil, signedOut: false, now: now)?.text.contains("~") == true,
                       "an exact reset from Anthropic stays exact")
    }
}
