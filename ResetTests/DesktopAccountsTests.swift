import XCTest
@testable import Reset

/// Live usage for the account Claude Code's sign-in really belongs to, and for the other accounts signed in to
/// the Claude desktop app.
final class DesktopAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)
    private let team = "11111111-1111-4111-8111-111111111111", pro = "22222222-2222-4222-8222-222222222222"
    private let theirs = "66666666-6666-4666-8666-666666666666"
    private let me = "44444444-4444-4444-8444-444444444444", someoneElse = "55555555-5555-4555-8555-555555555555"
    private let otherClient = "33333333-3333-4333-8333-333333333333"
    private let full = "user:profile user:inference"

    /// A desktop-app cache key: "<client>:<organization>:<api host>:<scopes>".
    private func key(_ org: String, _ scopes: String, client: String = ClaudeDesktopSignIn.productionClient) -> String {
        "\(client):\(org):https://api.anthropic.com:\(scopes)"
    }

    private func entry(_ token: String, hours: Double, plan: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["token": token, "expiresAt": (now.timeIntervalSince1970 + hours * 3600) * 1000]
        if let plan { e["subscriptionType"] = plan }
        return e
    }

    func testDecryptsTheDesktopAppsFormat() throws {
        // Made with openssl: PBKDF2-SHA1("peanuts", "saltysalt", 1003 rounds) → AES-128-CBC with a 16-space IV, "v10" in front.
        let key = try XCTUnwrap(ClaudeDesktopSignIn.deriveKey(password: "peanuts"))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "d9a09d499b4e1b7461f28e67972c6dbd")
        let cache = ClaudeDesktopSignIn.decodeCache("djEwfFFY1u5JwbB1GFNwp6WR5DdzzioyeehLmj/pX2J9mu8=", key: key)
        XCTAssertEqual(cache?["hello"] as? String, "world")
        XCTAssertNil(ClaudeDesktopSignIn.decodeCache("bm90IGVuY3J5cHRlZA==", key: key), "no v10 in front: not the desktop app's")
        XCTAssertEqual(ClaudeDesktopSignIn.decodeCache(nil, key: key)?.isEmpty, true, "a missing cache is an empty one")
        let sealed = try XCTUnwrap(ClaudeDesktopSignIn.encrypt(Data(#"{"a":1}"#.utf8), key: key))
        XCTAssertEqual(ClaudeDesktopSignIn.decrypt(sealed, key: key), Data(#"{"a":1}"#.utf8))
    }

    func testOneTokenPerOrganizationUnexpiredFirst() {
        let gone = "77777777-7777-4777-8777-777777777777"
        let v2: [String: Any] = [
            key(team, full): entry("team-best", hours: 2, plan: "team"),
            key(team, "user:profile", client: otherClient): entry("team-partial", hours: 6),
            key(pro, full): entry("pro-expired", hours: -1, plan: "pro"),
            key(pro, "user:inference"): entry("pro-cant-read-usage", hours: 3),
            key(gone, full): entry("long-gone", hours: -8 * 24),
            "not a cache key": entry("junk", hours: 3),
        ]
        let found = ClaudeDesktopSignIn.signIns(v2: v2, v1: [:], account: me, now: now)
        XCTAssertEqual(found[team]?.token, "team-best", "the desktop app's own login beats a longer-lived partial token")
        XCTAssertEqual(found[team]?.plan, "team")
        XCTAssertTrue(ClaudeDesktopSignIn.usable(found[team]!, now: now))
        XCTAssertEqual(found[pro]?.token, "pro-expired", "still listed, so the account doesn't vanish while the desktop app is closed")
        XCTAssertFalse(ClaudeDesktopSignIn.usable(found[pro]!, now: now), "but never sent")
        XCTAssertNil(found[gone], "expired over a week ago")
        XCTAssertEqual(found.count, 2, "nothing without the scope the usage endpoint needs")
        let mixed = ClaudeDesktopSignIn.signIns(v2: [key(pro, full): entry("expired", hours: -1),
                                                     key(pro, "user:profile user:inference", client: otherClient): entry("fresh", hours: 1)],
                                                v1: [:], account: nil, now: now)
        XCTAssertEqual(mixed[pro]?.token, "fresh", "a usable token beats an expired one with better scopes")
    }

    func testAScanNeverAsksTheKeychain() throws {
        // Reading there can show macOS's prompt; scans only use the key that "Allow…" (or switching on) read.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        ClaudeDesktopSignIn.forget()
        try Data(#"{"oauth:tokenCacheV2":"djEwfFFY1u5JwbB1GFNwp6WR5DdzzioyeehLmj/pX2J9mu8="}"#.utf8).write(to: url)
        XCTAssertEqual(ClaudeDesktopSignIn.read(now: now, config: url).state, .needsPermission)
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(ClaudeDesktopSignIn.read(now: now, config: url).state, .notFound, "no desktop sign-in")
    }

    func testOnlyTheSignedInUsersTokensAndDeletionsCount() {
        let v1: [String: Any] = [key(team, full): entry("old-team", hours: 2), key(pro, full): entry("old-pro", hours: 2)]
        let v2: [String: Any] = [
            "acct:\(me)|\(key(team, full))": entry("new-team", hours: 3),
            "acct:\(me)|\(key(pro, full))": NSNull(),
            "acct:\(someoneElse)|\(key(theirs, full))": entry("not-mine", hours: 3),
        ]
        let found = ClaudeDesktopSignIn.signIns(v2: v2, v1: v1, account: me.uppercased(), now: now)
        XCTAssertEqual(found[team]?.token, "new-team", "the signed-in user's own key replaces the older one")
        XCTAssertNil(found[pro], "a deletion marker removes the older key too")
        XCTAssertNil(found[theirs], "another user's tokens aren't used")
        XCTAssertEqual(ClaudeDesktopSignIn.signIns(v2: v2, v1: v1, account: nil, now: now)[team]?.token, "old-team",
                       "without a known user only the unscoped keys count")
    }

    func testTheProfileSaysWhoseSignInItIs() {
        let team = LiveClaude.profileAccount(["account": ["uuid": "a"], "organization": ["uuid": "ABC-1", "organization_type": "claude_team"]])
        XCTAssertEqual(team?.org, "abc-1", "lower case, as the desktop app's cache and the transcripts spell it")
        XCTAssertEqual(team?.plan, "team")
        XCTAssertEqual(LiveClaude.profileAccount(["organization": ["uuid": "x", "organization_type": "claude_enterprise"]])?.plan, "enterprise")
        XCTAssertNil(LiveClaude.profileAccount(["organization": ["uuid": "x"]])?.plan, "no plan given")
        XCTAssertNil(LiveClaude.profileAccount(["account": ["uuid": "a"]]), "no organization")
    }

    func testDesktopAccountsAreListedAfterTheOnesInUse() {
        XCTAssertEqual(ClaudeSource.others(used: ["b", "a"], desktop: ["d", "a", "main", "c"], main: "main"), ["b", "a", "c", "d"],
                       "used ones first, then the desktop app's in a fixed order; the main account never twice")
        XCTAssertEqual(ClaudeSource.others(used: [], desktop: [], main: nil), [])
    }

    func testReadingsSavedBeforeAccountsWereVerifiedStillLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let t = now.addingTimeInterval(-60).timeIntervalSince1970
        let old = #"{"lastAttempt":\#(t),"backoffUntil":0,"lastGood":{"fiveHour":{"percent":35},"fetchedAt":\#(t)}}"#
        try Data(old.utf8).write(to: url)
        let live = LiveClaude(scheduleURL: url, now: now)
        XCTAssertEqual(live.snapshot?.fiveHour?.percent, 35)
        XCTAssertNil(live.snapshot?.org)
        XCTAssertNil(live.tokenAccount)

        let snap = LiveClaude.Snapshot(fiveHour: .init(percent: 10, resetsAt: nil), sevenDay: nil, fetchedAt: now, org: team)
        LiveClaude.saveSchedule(.init(lastGood: snap, account: .init(tokenHash: "ab", org: team, plan: "team")), to: url)
        XCTAssertEqual(LiveClaude(scheduleURL: url, now: now).snapshot?.org, team)
        let later = LiveClaude(scheduleURL: url, now: now.addingTimeInterval(86400))
        XCTAssertNil(later.snapshot, "a day-old reading says nothing about the window")
        XCTAssertEqual(later.tokenAccount?.org, team, "but still says whose sign-in it is, from the first scan after launch")
        XCTAssertEqual(later.tokenAccount?.plan, "team")
    }

    func testEachDesktopAccountKeepsItsOwnSchedule() {
        XCTAssertEqual(LiveClaude.scheduleURL(org: team).lastPathComponent, "live-schedule-11111111.json")
        XCTAssertNotEqual(LiveClaude.scheduleURL(org: team), LiveClaude.scheduleURL)
    }
}
