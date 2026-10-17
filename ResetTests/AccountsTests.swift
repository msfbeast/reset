import XCTest
@testable import Reset

/// Two Claude accounts (say a Team org and a personal Pro plan) get separate windows.
final class AccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)
    private func act(_ minutesAgo: Double, _ org: String?) -> TranscriptScanner.Event {
        .init(time: now.addingTimeInterval(-minutesAgo * 60), kind: .activity, org: org)
    }

    func testMainAccountIsTheCLIsOtherwiseTheMostRecent() {
        let events = [act(300, "team"), act(10, "pro")]
        XCTAssertEqual(ClaudeSource.mainOrg(cliOrg: "team", events: events), "team")
        XCTAssertEqual(ClaudeSource.mainOrg(cliOrg: nil, events: events), "pro", "without the CLI, the latest activity decides")
    }

    func testOtherAccountsAreThoseWithActivity() {
        let events = [act(20, "team"), act(500, "pro"), act(30, nil),
                      .init(time: now, kind: .fiveHourLimit(now.addingTimeInterval(3600)), org: "other")]
        XCTAssertEqual(ClaudeSource.otherOrgs(events: events, main: "team"), ["pro"], "a limit row alone isn't use")
        XCTAssertEqual(ClaudeSource.otherOrgs(events: [act(20, "team")], main: "team"), [], "one account: nothing extra")
    }

    func testEachAccountGetsItsOwnWindow() {
        // Team started a window 40 minutes ago; Pro started one 4 hours ago.
        let team = [act(40, "team")], pro = [act(240, "pro")]
        let t = ClaudeSource.status(id: "claude", name: "Claude · Team", events: team, org: nil, now: now, canAutoStart: true)
        let p = ClaudeSource.status(id: "claude-pro", name: "Claude · Pro", events: pro, org: nil, now: now, canAutoStart: false)
        XCTAssertNotEqual(t.resetsAt, p.resetsAt)
        XCTAssertGreaterThan(t.resetsAt!, p.resetsAt!, "Pro's window resets first")
        XCTAssertFalse(p.canAutoStart, "auto-start goes through the CLI's account")
    }

    /// A plan-usage log with one reading per (hours ago, 7-day %) for org "pro".
    private func planLog(_ rows: [(Double, Double)]) throws -> URL {
        let samples = rows.map { ["org": "pro", "t": now.addingTimeInterval(-$0.0 * 3600).timeIntervalSince1970 * 1000,
                                  "u": ["fh": 0, "sd": $0.1]] as [String: Any] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "samples": samples]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUsedUpWeeklyLimitBlocksUntilTheLatestItCanLift() throws {
        // Reset seen 5 days ago (73 → 0), used up 2 days ago: due back by 2 days from now, 7 days after that reset.
        let log = try planLog([(130, 73), (120, 0), (60, 90), (48, 100), (40, 100)])
        let hit = try XCTUnwrap(PlanUsageLog.weeklyHit(org: "pro", now: now, url: log))
        XCTAssertEqual(hit.at, now.addingTimeInterval(-48 * 3600), "first seen used up")
        XCTAssertEqual(hit.liftsBy, now.addingTimeInterval(48 * 3600))
        let p = ClaudeSource.status(id: "claude-pro", name: "Claude · Pro", events: [], org: "pro", now: now,
                                    canAutoStart: false, planLog: log)
        XCTAssertEqual(p.blockedUntil, hit.liftsBy, "not \"ready\" while the limit may still be on")
        XCTAssertTrue(p.source.contains("lifts by about"), p.source)
    }

    func testWeeklyLimitIsOverOnceItsDueOrClaudeCodeRepliedSince() throws {
        // Reset seen 8 days ago, used up 3 days ago: it was due by a day ago (the user's real case: Fri → Fri).
        let past = try planLog([(200, 78), (192, 0), (72, 100)])
        XCTAssertNil(PlanUsageLog.weeklyHit(org: "pro", now: now, url: past))
        let p = ClaudeSource.status(id: "claude-pro", name: "Claude · Pro", events: [], org: "pro", now: now,
                                    canAutoStart: false, planLog: past)
        XCTAssertNil(p.blockedUntil); XCTAssertEqual(p.state, .ready); XCTAssertFalse(p.source.contains("weekly"))

        // No reset on record: 7 days after the used-up reading. A reply on this account after it proves it lifted.
        let log = try planLog([(30, 100)])
        XCTAssertEqual(PlanUsageLog.weeklyHit(org: "pro", now: now, url: log)?.liftsBy, now.addingTimeInterval((168 - 30) * 3600))
        let replied = ClaudeSource.status(id: "claude-pro", name: "Claude · Pro", events: [act(60, "pro")], org: "pro", now: now,
                                          canAutoStart: false, planLog: log)
        XCTAssertNil(replied.blockedUntil)

        // Not used up: nothing to say.
        XCTAssertNil(PlanUsageLog.weeklyHit(org: "pro", now: now, url: try planLog([(10, 0), (5, 64)])))
    }

    func testPlanPriceFollowsTheChosenAccount() {
        let ids = ["claude", "claude-6ac79bdb"], others = ["claude-6ac79bdb": 20.0]
        XCTAssertEqual(UsageStore.monthlyPlan(main: 30, others: others, accounts: ids, account: "claude"), 30, "Team's own seat")
        XCTAssertEqual(UsageStore.monthlyPlan(main: 30, others: others, accounts: ids, account: "claude-6ac79bdb"), 20, "Pro's own plan")
        XCTAssertEqual(UsageStore.monthlyPlan(main: 30, others: others, accounts: ids, account: nil), 50, "All pays for both")
        XCTAssertEqual(UsageStore.monthlyPlan(main: 30, others: others, accounts: ids, account: "claude-gone"), 50, "a vanished account means All")
        XCTAssertEqual(UsageStore.monthlyPlan(main: 30, others: [:], accounts: ids, account: "claude-6ac79bdb"), 0, "not set yet: no multiple")
        XCTAssertEqual(UsageStore.monthlyPlan(main: 20, others: others, accounts: ["claude"], account: "claude-6ac79bdb"), 20,
                       "one account: the one price, as before")
    }

    func testTwoAccountsOnTheSamePlanCanBeToldApart() {
        let ids = ["claude", "claude-aaaa1111", "claude-bbbb2222"]
        XCTAssertEqual(ClaudeSource.accountLabels(ids: ids, defaults: ["Pro", "Pro", "Pro"], custom: [:]), ["Pro", "Pro 2", "Pro 3"])
        XCTAssertEqual(ClaudeSource.accountLabels(ids: ids, defaults: ["Team", "Pro", "other account"], custom: [:]),
                       ["Team", "Pro", "other account"], "different plans keep their names")
        XCTAssertEqual(ClaudeSource.accountLabels(ids: ids, defaults: ["Pro", "Pro", "Pro"],
                                                  custom: ["claude": "Work", "claude-aaaa1111": "Personal", "claude-bbbb2222": " "]),
                       ["Work", "Personal", "Pro"], "names given in Settings win; a blank one falls back to the plan")
    }

    func testNames() {
        XCTAssertEqual(ClaudeSource.planLabel("team"), "Team")
        XCTAssertEqual(ClaudeSource.planLabel("max"), "Max")
        XCTAssertNil(ClaudeSource.planLabel(nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plan.json")
        try! #"{"samples":[{"t":1772442000000,"org":"pro-org","u":{"fh":10,"sd":100}},{"t":1772442000000,"org":"team-org","u":{"fh":5}}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSource.otherLabel(org: "pro-org", url: url), "Pro", "a weekly limit means Pro or Max")
        XCTAssertEqual(ClaudeSource.otherLabel(org: "team-org", url: url), "other account")
    }

    func testTranscriptEventsCarryTheirSessionsOrg() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("-Users-example-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [#"{"type":"attachment","attachment":{"type":"credential_org","organizationUuid":"org-pro-1234"}}"#,
                     #"{"type":"assistant","timestamp":"2026-03-02T09:14:05.120Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":5}}}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let events = TranscriptScanner().events(under: root, since: .distantPast)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.org, "org-pro-1234")
    }

    func testMenuBarNamesTheSecondAccountByPlan() {
        let pro = WindowStatus(id: "claude-pro12345", name: "Claude · Pro", state: .active(resetsAt: now.addingTimeInterval(3600)),
                               usedPercent: 30, isEstimate: true, source: "", secondary: nil, canAutoStart: false)
        XCTAssertEqual(MenuBarGlance.make(ready: nil, soonest: pro, blocked: nil, runsOutAt: nil, signedOut: false, now: now)?.text,
                       "Pro 1:00 · 70%")
    }
}

/// The dashboard's costs, windows and projects can be split by account.
final class AccountCostsTests: XCTestCase {
    private func call(_ id: String, org: String?, cost: Double) -> Call {
        Call(id: id, time: Date(), model: "claude-opus-5-5", session: "s", project: "/tmp/p", sidechain: false, input: 0, cw5: 0, cw1h: 0,
             cacheRead: 0, output: 0, advisorTokens: 0, tools: 0, mcpServers: [:], webSearches: 0, mcpAttribution: nil, cost: cost,
             autoStart: false, org: org)
    }
    private let accounts: [(id: String, name: String, org: String?)] = [("claude", "Claude · Team", "team"), ("claude-pro", "Claude · Pro", "pro")]

    func testEachAccountSeesOnlyItsOwnCalls() {
        let calls = [call("a", org: "team", cost: 3), call("b", org: "pro", cost: 5), call("c", org: nil, cost: 1), call("d", org: "old-org", cost: 2)]
        func total(_ id: String?) -> Double { UsageStore.scope(calls, accounts: accounts, account: id).reduce(0) { $0 + $1.cost } }
        XCTAssertEqual(total(nil), 11, "All")
        XCTAssertEqual(total("claude-pro"), 5)
        XCTAssertEqual(total("claude"), 6, "the main account also gets untagged calls and accounts that aren't listed")
        XCTAssertEqual(total("claude") + total("claude-pro"), total(nil), "nothing counted twice or lost")
    }

    func testOneAccountMeansNoFilter() {
        let calls = [call("a", org: "team", cost: 3), call("b", org: "pro", cost: 5)]
        XCTAssertEqual(UsageStore.scope(calls, accounts: [accounts[0]], account: "claude").count, 2)
    }

    /// With work and personal accounts, a copied resume command carries on under whichever account the terminal's
    /// Claude Code is signed in to, so the session says which account it ran under and flags a mismatch.
    func testASessionSaysWhichAccountItRanUnder() throws {
        let other = try XCTUnwrap(UsageStore.sessionAccount(org: "pro", accounts: accounts, signedIn: "team"))
        XCTAssertEqual(other.name, "Pro")
        XCTAssertEqual(other.otherThanCLI, true, "the CLI is signed in to Team, so resuming this would run on Team")
        XCTAssertEqual(other.cliName, "Team")
        let same = try XCTUnwrap(UsageStore.sessionAccount(org: "team", accounts: accounts, signedIn: "team"))
        XCTAssertEqual(same.name, "Team")
        XCTAssertEqual(same.otherThanCLI, false)
    }

    func testNoAccountLabelWhenThereIsNothingSureToSay() {
        XCTAssertNil(UsageStore.sessionAccount(org: "team", accounts: [accounts[0]], signedIn: "team"), "one account: nothing to tell apart")
        XCTAssertNil(UsageStore.sessionAccount(org: nil, accounts: accounts, signedIn: "team"), "an untagged transcript isn't guessed")
        XCTAssertNil(UsageStore.sessionAccount(org: "old-org", accounts: accounts, signedIn: "team"), "an account no longer listed has no name")
        // Without `claude auth status`, the main entry is only the most recently used account, not a sign-in.
        XCTAssertNil(UsageStore.sessionAccount(org: "pro", accounts: accounts, signedIn: nil)?.otherThanCLI)
    }

    func testCallsAreTaggedWithTheirTranscriptsAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("s.jsonl")
        let lines = [#"{"type":"attachment","attachment":{"type":"credential_org","organizationUuid":"org-pro-1234"}}"#,
                     #"{"type":"assistant","timestamp":"2026-03-02T09:14:05.120Z","sessionId":"s","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":5}}}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let r = ClaudeUsageScanner.parse(u, mtime: Date(), size: size, from: 0)
        XCTAssertEqual(r.org, "org-pro-1234")
        XCTAssertEqual(ClaudeUsageScanner.combine([r], since: .distantPast).calls.first?.org, "org-pro-1234")
    }
}

/// Switching accounts in the Claude desktop app rewrites ~/.claude.json but not the terminal's Keychain sign-in, so
/// `claude auth status` named the Pro org with the Team plan, and Reset put Team's live numbers on Pro's card.
final class SignedInAccountTests: XCTestCase {
    private func status(_ org: String?) -> WindowStatus {
        var s = WindowStatus(id: "claude", name: "Claude", state: .ready, usedPercent: nil, isEstimate: true, source: "",
                             secondary: nil, canAutoStart: true)
        s.account = org
        return s
    }

    func testTheSignInsOwnAccountBeatsAuthStatus() {
        let signIn = LiveClaude.TokenAccount(tokenHash: "ab", org: "team-org", plan: "team")
        let status = ClaudeCLI.Account(orgId: "pro-org", plan: "team")
        XCTAssertEqual(ClaudeCLI.resolve(signIn: signIn, status: status), .init(orgId: "team-org", plan: "team"),
                       "org and plan come from the same place, so the label matches the numbers")
        XCTAssertEqual(ClaudeCLI.resolve(signIn: nil, status: status), status, "without live usage, auth status is all there is")
    }

    func testLiveNumbersOnlyGoOnTheirOwnAccountsCard() {
        let snap = LiveClaude.Snapshot(fiveHour: .init(percent: 100, resetsAt: nil), sevenDay: nil, fetchedAt: Date(), org: "team-org")
        XCTAssertTrue(LiveClaude.belongs(snap, to: status("team-org")))
        XCTAssertFalse(LiveClaude.belongs(snap, to: status("pro-org")), "Team's used-up window never shows as Pro's")
        XCTAssertTrue(LiveClaude.belongs(snap, to: status(nil)), "an entry that doesn't know its account still gets them")
        var untagged = snap; untagged.org = nil
        XCTAssertTrue(LiveClaude.belongs(untagged, to: status("pro-org")), "readings from before accounts were asked, as before")
    }

    func testAReadingSavedBeforeAccountsStillLoads() throws {
        let old = #"{"fiveHour":{"percent":40},"fetchedAt":1792241542}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        XCTAssertNil(try dec.decode(LiveClaude.Snapshot.self, from: Data(old.utf8)).org)
        XCTAssertNil(try dec.decode(LiveClaude.Schedule.self, from: Data(#"{"lastAttempt":0,"backoffUntil":0}"#.utf8)).account)
    }

    func testProfileAndConfigPlansAreSpelledLikeAuthStatus() {
        let profile: [String: Any] = ["organization": ["uuid": "team-org", "organization_type": "claude_team"]]
        XCTAssertEqual(LiveClaude.profileAccount(profile)?.org, "team-org")
        XCTAssertEqual(LiveClaude.profileAccount(profile)?.plan, "team")
        XCTAssertNil(LiveClaude.profileAccount(["account": ["uuid": "x"]]))
        let config: [String: Any] = ["oauthAccount": ["organizationUuid": "pro-org", "organizationType": "claude_pro"]]
        XCTAssertEqual(ClaudeCLI.configPlan(org: "pro-org", config: config), "pro")
        XCTAssertNil(ClaudeCLI.configPlan(org: "team-org", config: config), "only for the org the file describes")
    }

    func testTheResumeWarningUsesTheTerminalsAccount() {
        let accounts: [(id: String, name: String, org: String?)] = [("claude", "Claude · Team", "team-org"), ("claude-pro", "Claude · Pro", "pro-org")]
        let signedIn = ClaudeCLI.resolve(signIn: .init(tokenHash: "ab", org: "team-org", plan: "team"),
                                         status: .init(orgId: "pro-org", plan: "team"))?.orgId
        let a = UsageStore.sessionAccount(org: "pro-org", accounts: accounts, signedIn: signedIn)
        XCTAssertEqual(a?.otherThanCLI, true)
        XCTAssertEqual(a?.cliName, "Team")
    }
}

/// The menu's top card follows the account you're using, which after a switch in the desktop app isn't the
/// terminal's, without swapping back and forth while both accounts are busy.
final class ActiveAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_240_000)
    private let both: Set<String> = ["team", "pro"]
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func active(current: String?, chosen: Double? = 60, config: String? = nil, changed: Double? = nil,
                        listed: Set<String>? = nil, use: [String: Double]) -> String? {
        ClaudeSource.activeOrg(current: current, chosenAt: chosen.map(ago), configOrg: config, configChangedAt: changed.map(ago),
                               listed: listed ?? both, lastUse: use.mapValues(ago), now: now)
    }

    func testSwitchingInTheDesktopAppMovesTheTopCardRightAway() {
        XCTAssertEqual(active(current: "team", config: "pro", changed: 1, use: ["team": 0, "pro": 0.5]), "pro",
                       "even with background work still running on Team")
    }

    func testASwitchToAnAccountWithNoSessionYetWaitsForIt() {
        XCTAssertEqual(active(current: "team", config: "pro", changed: 1, listed: ["team"], use: ["team": 0]), "team")
        XCTAssertEqual(active(current: "team", config: "pro", changed: 1, use: ["team": 0, "pro": 0]), "pro",
                       "once Pro's first session is listed, the switch still counts")
    }

    func testBothBusyDoesNotFlap() {
        XCTAssertEqual(active(current: "pro", config: "pro", changed: 30, use: ["team": 0, "pro": 2]), "pro")
    }

    func testTheOtherAccountTakesOverOnceThisOneIsQuiet() {
        // Using the terminal on Team again, without switching anything.
        XCTAssertEqual(active(current: "pro", config: "pro", changed: 90, use: ["team": 0, "pro": 25]), "team")
    }

    func testAnOldConfigChangeDoesNotPullTheCardBack() {
        XCTAssertEqual(active(current: "team", chosen: 5, config: "pro", changed: 90, use: ["team": 0, "pro": 60]), "team")
    }

    func testAnAccountWithNoSessionsHandsTheCardBack() {
        // Pro is listed only through the desktop app; the terminal keeps working on Team.
        XCTAssertEqual(active(current: "pro", chosen: 30, config: "pro", changed: 31, use: ["team": 0]), "team")
        XCTAssertEqual(active(current: "pro", chosen: 2, config: "pro", changed: 3, use: ["team": 0]), "pro", "not straight after the switch")
    }

    func testFirstLaunchStartsWithTheConfigsAccount() {
        XCTAssertEqual(active(current: nil, chosen: nil, config: "pro", use: ["team": 0, "pro": 30]), "pro")
        XCTAssertEqual(active(current: nil, chosen: nil, config: nil, use: ["team": 0, "pro": 30]), "team")
    }

    func testTheMenuBarFollowsTheActiveAccount() {
        let team = WindowStatus(id: "claude", name: "Claude · Team", state: .active(resetsAt: now.addingTimeInterval(4000)),
                                usedPercent: 100, isEstimate: false, source: "", secondary: nil, canAutoStart: true)
        let pro = WindowStatus(id: "claude-pro", name: "Claude · Pro", state: .active(resetsAt: now.addingTimeInterval(16000)),
                               usedPercent: nil, isEstimate: true, source: "", secondary: nil, canAutoStart: false)
        XCTAssertEqual(MenuBarGlance.pick([team, pro], main: "claude-pro", now: now).soonest?.id, "claude-pro")
        XCTAssertEqual(MenuBarGlance.pick([team, pro], now: now).soonest?.id, "claude", "the terminal's by default")
    }
}

/// The desktop Claude mascot naps and wakes with the account you're using, not the terminal's.
final class MascotAccountTests: XCTestCase {
    func testClaudesMascotShowsTheActiveAccount() {
        let now = Date()
        var team = WindowStatus(id: "claude", name: "Claude · Team", state: .active(resetsAt: now.addingTimeInterval(4000)),
                                usedPercent: 100, isEstimate: false, source: "", secondary: nil, canAutoStart: true)
        team.account = "team"
        var pro = WindowStatus(id: "claude-pro", name: "Claude · Pro", state: .ready, usedPercent: nil, isEstimate: true,
                               source: "", secondary: nil, canAutoStart: false)
        pro.account = "pro"
        let codex = WindowStatus(id: "codex", name: "Codex", state: .ready, usedPercent: nil, isEstimate: true, source: "",
                                 secondary: nil, canAutoStart: false)
        let shown = MascotController.shown([team, pro, codex], activeClaude: "claude-pro")
        XCTAssertEqual(shown.map(\.id), ["claude", "codex"], "one Claude mascot, keeping its place and hide setting")
        XCTAssertEqual(shown.first?.name, "Claude · Pro")
        XCTAssertEqual(shown.first?.state, .ready)
        XCTAssertEqual(MascotController.shown([team, pro, codex], activeClaude: "claude").first?.name, "Claude · Team")
    }
}
