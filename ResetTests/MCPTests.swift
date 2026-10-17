import XCTest
@testable import Reset

/// The pacing budget: what an agent may set, and where usage stands against it.
final class BudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func make(_ args: [String: Any]) -> (Budget?, String?) {
        // Through JSONSerialization, so numbers and booleans arrive as they would from a real client.
        let json = try! JSONSerialization.data(withJSONObject: args)
        let a = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        let r = Budget.from(arguments: a, now: now)
        return (r.budget, r.error)
    }

    func testValidArguments() {
        let (b, err) = make(["task": "  Refactor auth  ", "max_window_percent": 60, "downshift_model": "haiku"])
        XCTAssertNil(err)
        XCTAssertEqual(b, Budget(task: "Refactor auth", maxPercent: 60, downshiftModel: "haiku", setAt: now))
        XCTAssertEqual(make(["task": "t", "max_window_percent": 50.0]).0?.maxPercent, 50, "a whole float is fine")
        XCTAssertNil(make(["task": "t", "max_window_percent": 1]).1)
        XCTAssertNil(make(["task": "t", "max_window_percent": 100]).1)
        XCTAssertNil(make(["task": "t", "max_window_percent": 70, "downshift_model": NSNull()]).0?.downshiftModel)
    }

    func testInvalidArgumentsAreRejected() {
        for cap: Any in [0, 101, -5, 50.5, true, false, "50"] {
            XCTAssertNotNil(make(["task": "t", "max_window_percent": cap]).1, "cap \(cap) should be rejected")
        }
        XCTAssertNotNil(make(["max_window_percent": 50]).1, "task is required")
        XCTAssertNotNil(make(["task": "   ", "max_window_percent": 50]).1, "blank task")
        XCTAssertNotNil(make(["task": "t"]).1, "cap is required")
        XCTAssertNotNil(make(["task": "t", "max_window_percent": 50, "downshift_model": 3]).1)
        XCTAssertNotNil(make(["task": "t", "max_window_percent": 50, "downshift_model": " "]).1)
    }

    func testStatusBands() {
        let b = Budget(task: "t", maxPercent: 100, downshiftModel: nil, setAt: now)
        XCTAssertEqual(b.status(used: 79), .normal)
        XCTAssertEqual(b.status(used: 80), .wrapUp)
        XCTAssertEqual(b.status(used: 99), .wrapUp)
        XCTAssertEqual(b.status(used: 100), .over)
        XCTAssertEqual(b.status(used: nil), .unknown)
        let tight = Budget(task: "t", maxPercent: 60, downshiftModel: nil, setAt: now)
        XCTAssertEqual(tight.status(used: 47.9), .normal)
        XCTAssertEqual(tight.status(used: 48), .wrapUp)
        XCTAssertEqual(tight.status(used: 60), .over)
        XCTAssertEqual(tight.status(used: 97), .over)
    }

    func testOverAdviceNamesTheDownshiftModelOrSaysStop() {
        let with = Budget(task: "Docs", maxPercent: 50, downshiftModel: "haiku", setAt: now)
        let over = with.advice(used: 55)
        XCTAssertTrue(over.contains("haiku subagents with a complete brief") && over.contains("/model haiku"),
                      "Claude can't change its own model, so both ways to switch are spelled out")
        let without = Budget(task: "Docs", maxPercent: 50, downshiftModel: nil, setAt: now)
        XCTAssertTrue(without.advice(used: 55).contains("check in with the user"))
        XCTAssertTrue(without.advice(used: 41).contains("Wrap up"))
        XCTAssertTrue(without.advice(used: nil).contains("can't be checked"))
    }

    func testStatusLineTag() {
        let b = Budget(task: "A long task name that stays off the status line", maxPercent: 60, downshiftModel: "haiku", setAt: now)
        XCTAssertEqual(b.tag(used: 30), "budget 60%")
        XCTAssertEqual(b.tag(used: 50), "budget 60% wrap up")
        XCTAssertEqual(b.tag(used: 61), "budget 60% over, use haiku")
        XCTAssertEqual(b.tag(used: nil), "budget 60% (usage unknown)")
        XCTAssertEqual(Budget(task: "t", maxPercent: 40, downshiftModel: nil, setAt: now).tag(used: 45), "budget 40% over, stop")
    }

    func testSaveLoadClearRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("budget.json")
        XCTAssertNil(Budget.load(from: url))
        let b = Budget(task: "t", maxPercent: 70, downshiftModel: "sonnet", setAt: now)
        try b.save(to: url)
        XCTAssertEqual(Budget.load(from: url), b)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["budget.json"], "no temp files left behind")
        Budget.clear(at: url)
        XCTAssertNil(Budget.load(from: url))
    }

    func testStoreReloadsAndClearsTheBudgetFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-budget.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = Store()
        store.budgetURL = url
        store.reloadBudget()
        XCTAssertNil(store.budget)
        let b = Budget(task: "t", maxPercent: 40, downshiftModel: nil, setAt: now)
        try b.save(to: url)
        store.reloadBudget()
        XCTAssertEqual(store.budget, b)
        store.clearBudget()
        XCTAssertNil(store.budget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

/// JSON-RPC round-trips through the same handler reset-mcp runs, without spawning the process.
final class MCPServerTests: XCTestCase {
    private var dir: URL!
    private var budgetURL: URL { dir.appendingPathComponent("budget.json") }
    private let now = Date(timeIntervalSince1970: 1_772_442_000)
    private var snapshot: WidgetSnapshot?

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        snapshot = snap(used: 30)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func snap(used: Double?, ready: Bool = false, blockedUntil: Date? = nil) -> WidgetSnapshot {
        let claude = WidgetSnapshot.Provider(id: "claude", name: "Claude", resetsAt: ready ? nil : now.addingTimeInterval(7200),
                                             ready: ready, available: true, used: used, blockedUntil: blockedUntil)
        return WidgetSnapshot(updated: now, providers: [claude], windows: [], weekCost: 12.345, cacheHit: 0.9)
    }

    /// The calling agent's account, as the desktop app would pass it; nil like a plain terminal Claude Code.
    private var org: String?

    private var env: MCPServer.Environment {
        MCPServer.Environment(now: { [now] in now }, snapshot: { [weak self] in self?.snapshot }, budgetURL: budgetURL, running: { true },
                              org: { [weak self] in self?.org })
    }

    /// Sends one NDJSON line and parses the reply line back, as a client would.
    private func send(_ msg: [String: Any]) -> [String: Any]? {
        let line = String(data: try! JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!
        guard let out = MCPServer.handle(line: line, env: env) else { return nil }
        XCTAssertFalse(out.contains("\n"), "one reply per line")
        return try! JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    }

    private var nextId = 0
    /// Calls a tool and returns (the report decoded from the text content, isError).
    private func call(_ name: String, _ args: [String: Any] = [:]) -> ([String: Any], Bool) {
        nextId += 1
        let r = send(["jsonrpc": "2.0", "id": nextId, "method": "tools/call", "params": ["name": name, "arguments": args]])
        XCTAssertEqual(r?["id"] as? Int, nextId)
        let result = r?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "{}"
        let report = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (report, result?["isError"] as? Bool ?? false)
    }

    func testInitializeEchoesProtocolVersion() {
        let r = send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let result = r?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "reset")
    }

    func testToolsListHasTheThreeTools() {
        let r = send(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        XCTAssertEqual(r?["id"] as? String, "a", "string ids come back unchanged")
        let names = ((r?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["get_claude_usage", "set_budget", "clear_budget"])
    }

    func testUsageWithoutSnapshotIsAnError() {
        snapshot = nil
        let (report, isError) = call("get_claude_usage")
        XCTAssertTrue(isError)
        XCTAssertNotNil(report["error"])
    }

    /// The terminal on Team with its window used up, the desktop app switched to Pro with a fresh one.
    private func twoAccounts() -> WidgetSnapshot {
        var team = WidgetSnapshot.Provider(id: "claude", name: "Claude · Team", resetsAt: now.addingTimeInterval(4680), ready: false,
                                           available: true, used: 100, blockedUntil: nil)
        team.org = "team-org"
        var pro = WidgetSnapshot.Provider(id: "claude-pro-org", name: "Claude · Pro", resetsAt: now.addingTimeInterval(17000), ready: false,
                                          available: true, used: 4, blockedUntil: nil)
        pro.org = "pro-org"
        var s = WidgetSnapshot(updated: now, providers: [team], windows: [], weekCost: 1, cacheHit: 0)
        s.claudeAccounts = [team, pro]
        s.claudeRunsOutAt = now.addingTimeInterval(600)
        return s
    }

    /// An agent in the desktop app on Pro was told "Window nearly exhausted" from the terminal's Team account.
    func testAnAgentGetsItsOwnAccountsWindow() {
        snapshot = twoAccounts()
        org = "pro-org"
        let (report, _) = call("get_claude_usage")
        let claude = report["claude"] as? [String: Any]
        XCTAssertEqual(claude?["account"] as? String, "Claude · Pro")
        XCTAssertEqual(claude?["percent_left"] as? Int, 96)
        XCTAssertNil(claude?["projected_run_out_local"], "the run-out forecast is the terminal account's")
        XCTAssertEqual(report["advice"] as? String, "Plenty of window left.")
    }

    func testWithoutAnAccountTheTerminalsIsReported() {
        snapshot = twoAccounts()
        let (report, _) = call("get_claude_usage")
        let claude = report["claude"] as? [String: Any]
        XCTAssertEqual(claude?["account"] as? String, "Claude · Team")
        XCTAssertEqual(claude?["percent_left"] as? Int, 0)
    }

    func testAnUnlistedAccountIsUnknownNotAnotherAccounts() {
        snapshot = twoAccounts()
        org = "new-org"
        let (report, _) = call("get_claude_usage")
        XCTAssertEqual((report["claude"] as? [String: Any])?["window"] as? String, "unknown")
        XCTAssertNil((report["claude"] as? [String: Any])?["percent_left"])
        XCTAssertTrue((report["advice"] as? String)?.contains("unknown") == true)
    }

    func testOneAccountReportsAsBefore() {
        org = "any-org"
        let (report, _) = call("get_claude_usage")
        XCTAssertNil((report["claude"] as? [String: Any])?["account"], "nothing to tell apart")
        XCTAssertEqual((report["claude"] as? [String: Any])?["percent_left"] as? Int, 70, "a snapshot from before accounts were written")
    }

    func testABudgetIsJudgedOnTheCallersAccount() {
        snapshot = twoAccounts()
        org = "pro-org"
        let (set, _) = call("set_budget", ["task": "t", "max_window_percent": 50])
        XCTAssertEqual((set["budget"] as? [String: Any])?["status"] as? String, "normal", "4% of Pro, not 100% of Team")
        XCTAssertEqual(Budget.load(from: budgetURL)?.org, "pro-org", "so the menu shows it on Pro's card too")
    }

    func testUsageWithoutBudget() {
        let (report, isError) = call("get_claude_usage")
        XCTAssertFalse(isError)
        XCTAssertNil(report["budget"])
        XCTAssertEqual((report["claude"] as? [String: Any])?["percent_left"] as? Int, 70)
        XCTAssertEqual(report["advice"] as? String, "Plenty of window left.")
        XCTAssertEqual((report["cost"] as? [String: Any])?["last_7_days_usd"] as? Double, 12.35, "two-decimal money survives the round-trip")
    }

    func testSetGetClearBudgetRoundTrip() {
        let (set, setErr) = call("set_budget", ["task": "Refactor auth", "max_window_percent": 60, "downshift_model": "haiku"])
        XCTAssertFalse(setErr)
        XCTAssertEqual((set["budget"] as? [String: Any])?["status"] as? String, "normal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: budgetURL.path))

        // 30% used of a 60% cap: normal, and the window advice still applies.
        var (report, _) = call("get_claude_usage")
        var budget = report["budget"] as? [String: Any]
        XCTAssertEqual(budget?["task"] as? String, "Refactor auth")
        XCTAssertEqual(budget?["max_window_percent"] as? Int, 60)
        XCTAssertEqual(budget?["downshift_model"] as? String, "haiku")
        XCTAssertEqual(budget?["status"] as? String, "normal")
        XCTAssertEqual(report["advice"] as? String, "Plenty of window left.")

        // 50%: past 80% of the cap, so wrap up.
        snapshot = snap(used: 50)
        (report, _) = call("get_claude_usage")
        budget = report["budget"] as? [String: Any]
        XCTAssertEqual(budget?["status"] as? String, "wrap_up")
        XCTAssertTrue((report["advice"] as? String)?.contains("Wrap up") == true)

        // 64%: over the cap; the top-level advice names the downshift model.
        snapshot = snap(used: 64)
        (report, _) = call("get_claude_usage")
        XCTAssertEqual((report["budget"] as? [String: Any])?["status"] as? String, "over")
        XCTAssertTrue((report["advice"] as? String)?.contains("/model haiku") == true)

        let (cleared, clearErr) = call("clear_budget")
        XCTAssertFalse(clearErr)
        XCTAssertEqual(cleared["cleared"] as? Bool, true)
        XCTAssertEqual(cleared["task"] as? String, "Refactor auth")
        XCTAssertFalse(FileManager.default.fileExists(atPath: budgetURL.path))
        XCTAssertEqual(call("clear_budget").0["cleared"] as? Bool, false, "clearing twice is harmless")
        XCTAssertNil(call("get_claude_usage").0["budget"])
    }

    func testWeeklyLimitOutranksBudgetAdvice() {
        _ = call("set_budget", ["task": "t", "max_window_percent": 20])
        snapshot = snap(used: 64, blockedUntil: now.addingTimeInterval(86400))
        let (report, _) = call("get_claude_usage")
        XCTAssertTrue((report["advice"] as? String)?.hasPrefix("The weekly limit is exhausted") == true)
        XCTAssertEqual((report["budget"] as? [String: Any])?["status"] as? String, "over", "the budget still reports its own status")
    }

    func testFreshWindowCountsAsZeroUsed() {
        _ = call("set_budget", ["task": "t", "max_window_percent": 10])
        snapshot = snap(used: 95, ready: true)
        XCTAssertEqual((call("get_claude_usage").0["budget"] as? [String: Any])?["status"] as? String, "normal")
    }

    func testUnknownUsageIsReportedNotNormal() {
        _ = call("set_budget", ["task": "t", "max_window_percent": 50])
        snapshot = snap(used: nil)
        XCTAssertEqual((call("get_claude_usage").0["budget"] as? [String: Any])?["status"] as? String, "unknown")
    }

    func testUnknownUsageIsNotPlentyLeft() {
        snapshot = snap(used: nil)
        XCTAssertTrue((call("get_claude_usage").0["advice"] as? String)?.contains("unknown") == true)
    }

    func testOnlyARunOutStillAheadAndBeforeTheResetWarns() {
        var s = snap(used: 30)
        s.claudeRunsOutAt = now.addingTimeInterval(-600)
        snapshot = s
        XCTAssertEqual(call("get_claude_usage").0["advice"] as? String, "Plenty of window left.", "a run-out already past says nothing")
        s.claudeRunsOutAt = now.addingTimeInterval(3600)
        snapshot = s
        let (report, _) = call("get_claude_usage")
        XCTAssertTrue((report["advice"] as? String)?.hasPrefix("On pace to run out before the reset. At this pace") == true,
                      "70% left isn't \"nearly exhausted\"")
        XCTAssertEqual((report["claude"] as? [String: Any])?["minutes_until_run_out"] as? Int, 60)
    }

    func testWeeklyLimitIsReportedAndWarnedBeforeItsUsedUp() {
        var s = snap(used: 20)
        s.providers[0].weeklyUsed = 92; s.providers[0].weeklyResetsAt = now.addingTimeInterval(2 * 86400)
        snapshot = s
        let (report, _) = call("get_claude_usage")
        XCTAssertEqual((report["claude"] as? [String: Any])?["weekly_percent_used"] as? Int, 92)
        XCTAssertTrue((report["advice"] as? String)?.hasPrefix("The weekly limit is 92% used") == true)
        s.providers[0].weeklyUsed = 50
        snapshot = s
        XCTAssertEqual(call("get_claude_usage").0["advice"] as? String, "Plenty of window left.", "half a week used is normal")
    }

    func testTheReadingsAgeAndALiveCheckFailureReachTheAgent() {
        var s = snap(used: 30)
        s.providers[0].usageAsOf = now.addingTimeInterval(-90)
        snapshot = s
        var (report, _) = call("get_claude_usage")
        var claude = report["claude"] as? [String: Any]
        XCTAssertEqual(claude?["usage_age_minutes"] as? Int, 1)
        XCTAssertNil(claude?["usage_may_be_stale"], "a fresh reading is just a reading")
        XCTAssertEqual(report["advice"] as? String, "Plenty of window left.")

        _ = call("set_budget", ["task": "t", "max_window_percent": 50])
        s.providers[0].usageAsOf = now.addingTimeInterval(-12 * 60)
        s.providers[0].liveFailingSince = now.addingTimeInterval(-11 * 60)
        s.providers[0].liveProblem = "Couldn't reach Anthropic"
        snapshot = s
        (report, _) = call("get_claude_usage")
        claude = report["claude"] as? [String: Any]
        XCTAssertEqual(claude?["usage_may_be_stale"] as? Bool, true)
        XCTAssertEqual(claude?["live_check_problem"] as? String, "Couldn't reach Anthropic")
        XCTAssertTrue((report["advice"] as? String)?.hasPrefix("Usage was last read at") == true)
        XCTAssertNotNil((report["budget"] as? [String: Any])?["warning"], "the budget is judged on the same old reading")
    }

    func testNumbersFromAResetThatQuitAreMarkedStale() {
        let report = MCPServer.usageReport(snapshot: snap(used: 30), budget: nil, now: now, running: false)
        XCTAssertEqual(report["stale"] as? Bool, true)
        XCTAssertTrue((report["advice"] as? String)?.hasPrefix("Reset isn't running") == true)
        XCTAssertNil(MCPServer.usageReport(snapshot: snap(used: 30), budget: nil, now: now)["stale"])
    }

    func testInvalidSetBudgetIsAToolErrorAndWritesNothing() {
        let (report, isError) = call("set_budget", ["task": "t", "max_window_percent": 150])
        XCTAssertTrue(isError)
        XCTAssertTrue((report["error"] as? String)?.contains("1 to 100") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: budgetURL.path))
    }

    func testProtocolErrors() {
        let unknownTool = send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "nope"]])
        XCTAssertEqual((unknownTool?["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = send(["jsonrpc": "2.0", "id": 8, "method": "resources/list"])
        XCTAssertEqual((unknownMethod?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((send(["jsonrpc": "2.0", "id": 9, "method": "ping"])?["result"] as? [String: Any])?.count, 0)
    }

    func testNotificationsAndGarbageGetNoReply() {
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "clear_budget"]]), "no id, no reply")
        XCTAssertNil(MCPServer.handle(line: "not json", env: env))
        XCTAssertNil(MCPServer.handle(line: "", env: env))
    }
}
