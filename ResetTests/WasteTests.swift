import XCTest
@testable import Reset

/// Where the window went: one case per rule, the things that must not count, and that nothing said is stored.
final class WasteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)
    private let since = Date(timeIntervalSince1970: 0)

    private func call(_ minutesAgo: Double, model: String = "claude-opus-5-5", thread: String = "a.jsonl", session: String = "s",
                      read: Int = 0, w5: Int = 0, w1h: Int = 0, out: Int = 100, tools: [Call.ToolUse] = [], side: Bool = false) -> Call {
        let p = Pricing.claude(model)!
        return Call(id: UUID().uuidString, time: now.addingTimeInterval(-minutesAgo * 60), model: model, session: session, project: "/tmp/p",
                    sidechain: side, input: 10, cw5: w5, cw1h: w1h, cacheRead: read, output: out, advisorTokens: 0, tools: tools.count,
                    mcpServers: [:], webSearches: 0, mcpAttribution: nil,
                    cost: Pricing.cost(p, input: 10, cw5: w5, cw1h: w1h, cacheRead: read, output: out), autoStart: false, org: nil,
                    thread: thread, toolUses: tools.isEmpty ? nil : tools)
    }

    private func report(_ calls: [Call], failed: Set<String> = [], compactions: [String: [Date]] = [:]) -> Waste.Report {
        Waste.analyze(calls, since: since, failed: failed, compactions: compactions)
    }

    func testComingBackAfterTheCacheExpiredIsABreak() {
        // 400k cached with a 1-hour lifetime, then back after 90 minutes: all of it written again.
        let r = report([call(200, w1h: 400_000), call(110, read: 0, w1h: 400_000)])
        let b = r.bucket(.breaks)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.usd, 400_000 * (8 - 0.2) / 1_000_000, accuracy: 0.001, "the 1-hour write over a read, at Opus 5.5 prices")
        XCTAssertEqual(report([call(200, w1h: 400_000), call(150, read: 400_000, w1h: 2_000)]).bucket(.breaks).count, 0,
                       "back within the hour: read from cache")
    }

    func testAFiveMinuteCacheExpiresSooner() {
        XCTAssertEqual(report([call(30, w5: 50_000), call(20, w5: 50_000)]).bucket(.breaks).count, 1)
    }

    func testABigWriteThatReusesTheCacheIsNotABust() {
        // Reading a big file: 80k reused, 30k new written. Normal, not a bust.
        XCTAssertEqual(report([call(3, read: 70_000, w1h: 10_000), call(2, read: 80_000, w1h: 30_000)]).bucket(.busts).count, 0)
    }

    func testLosingMostOfTheCacheMidSessionIsABustAndAModelSwitchIsNoted() {
        let r = report([call(3, read: 90_000, w1h: 10_000), call(2, model: "claude-sonnet-5-5", read: 5_000, w1h: 95_000)])
        XCTAssertEqual(r.bucket(.busts).count, 1)
        XCTAssertEqual(r.bucket(.busts).modelSwitches, 1)
    }

    func testARebuiltContextRightAfterACompactionIsNotABust() {
        let calls = [call(3, read: 90_000, w1h: 10_000), call(2, read: 5_000, w1h: 30_000)]
        XCTAssertEqual(report(calls, compactions: ["a.jsonl": [now.addingTimeInterval(-150)]]).bucket(.busts).count, 0)
    }

    func testTheSameToolFailingThreeTimesInARowIsALoop() {
        let fails = (0..<4).map { Call.ToolUse(id: "t\($0)", name: "Bash") }
        let calls = fails.enumerated().map { i, u in call(Double(10 - i), tools: [u]) }
        let r = report(calls, failed: Set(fails.map(\.id)))
        XCTAssertEqual(r.bucket(.loops).count, 2, "from the third failure on")
        let broken = [fails[0], .init(id: "ok", name: "Bash"), fails[1], fails[2]].enumerated().map { i, u in call(Double(10 - i), tools: [u]) }
        XCTAssertEqual(report(broken, failed: Set(fails.map(\.id))).bucket(.loops).count, 0, "a success in between breaks the run")
    }

    func testOpusOnATinySessionIsAnEstimateKeptOutOfTheTotal() {
        let r = report([call(5, out: 300)])
        XCTAssertGreaterThan(r.bucket(.overkill).usd, 0)
        XCTAssertEqual(r.total, 0, "a judgement call isn't counted as lost")
    }

    func testNoWasteInAnOrdinarySession() {
        let r = report([call(10, w1h: 20_000, out: 3_000, tools: [.init(id: "1", name: "Read"), .init(id: "2", name: "Edit"),
                                                                  .init(id: "3", name: "Bash"), .init(id: "4", name: "Read")]),
                        call(9, read: 20_000, w1h: 2_000), call(8, read: 22_000, w1h: 1_500)])
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.bucket(.overkill).usd, 0)
    }

    func testOnlyIdsAndTimesAreStoredNeverWhatWasSaid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "SECRET-PROMPT-TEXT"
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-12T10:00:00.000Z","sessionId":"s","cwd":"/tmp/p","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"\#(secret)"}}],"usage":{"input_tokens":1,"output_tokens":5}}}"#,
            #"{"type":"user","timestamp":"2026-10-12T10:00:05.000Z","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"\#(secret) failed"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-12T10:00:09.000Z","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu2","is_error":true,"content":"The user doesn't want to proceed with this tool use."}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-12T10:05:00.000Z","sessionId":"s"}"#,
        ]
        let u = dir.appendingPathComponent("a.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(u.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let r = ClaudeUsageScanner.parse(u, mtime: Date(), size: size, from: 0)
        XCTAssertEqual(r.calls.first?.toolUses, [.init(id: "tu1", name: "Bash")])
        XCTAssertEqual(r.failedTools, ["tu1"], "declining a tool isn't it failing")
        XCTAssertEqual(r.compactions?.count, 1)
        XCTAssertEqual(r.calls.first?.thread, "a.jsonl")
        let stored = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(stored.contains(secret), "tool inputs and results are never kept")
    }
}

/// Break Guard: which sessions count as big and warm, and the two prices it compares.
final class BreakGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func call(_ minutesAgo: Double, session: String = "s", read: Int, w1h: Int = 1_000, side: Bool = false, auto: Bool = false) -> Call {
        Call(id: UUID().uuidString, time: now.addingTimeInterval(-minutesAgo * 60), model: "claude-opus-5-5", session: session, project: "/tmp/p",
             sidechain: side, input: 10, cw5: 0, cw1h: w1h, cacheRead: read, output: 100, advisorTokens: 0, tools: 0, mcpServers: [:],
             webSearches: 0, mcpAttribution: nil, cost: 0, autoStart: auto, org: nil)
    }

    func testABigSessionIsWarmForAnHourFromItsLastTurn() {
        let w = BreakGuard.warm([call(90, read: 300_000), call(40, read: 399_000)], now: now)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].expiresAt, now.addingTimeInterval(20 * 60), "an hour after the last turn")
        XCTAssertEqual(w[0].comeBackUSD, 400_010 * 8 / 1_000_000, accuracy: 0.01, "re-written at the 1-hour price")
        XCTAssertLessThan(w[0].compactUSD, w[0].comeBackUSD / 5, "compacting while warm is a fraction of coming back")
    }

    func testSmallExpiredSubagentAndAutoStartSessionsDontCount() {
        XCTAssertTrue(BreakGuard.warm([call(10, read: 20_000)], now: now).isEmpty, "too small to matter")
        XCTAssertTrue(BreakGuard.warm([call(70, read: 300_000)], now: now).isEmpty, "already expired")
        XCTAssertTrue(BreakGuard.warm([call(10, read: 300_000, side: true)], now: now).isEmpty, "a subagent's context isn't the session's")
        XCTAssertTrue(BreakGuard.warm([call(10, read: 300_000, auto: true)], now: now).isEmpty, "auto-start's one-word run")
    }
}

extension BreakGuardTests {
    @MainActor func testTheMenuBarPillCountsDownWithAnHourglass() throws {
        var g = MenuBarGlance(tone: .normal, text: "2:46 · 42%")
        let plain = try XCTUnwrap(MenuBarPill.image(g))
        g.cacheMinutes = 14
        let counting = try XCTUnwrap(MenuBarPill.image(g))
        XCTAssertGreaterThan(counting.size.width, plain.size.width, "the countdown adds to the pill")
        XCTAssertLessThanOrEqual(counting.size.height, 22)
    }
}
