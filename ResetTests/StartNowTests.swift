import XCTest
@testable import Reset

/// The widgets' "Start now": when the app agrees to start, and that the request gets from widget to app.
final class StartNowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func claude(_ state: WindowStatus.State, blockedFor: TimeInterval? = nil) -> WindowStatus {
        var s = WindowStatus(id: "claude", name: "Claude", state: state, usedPercent: nil, isEstimate: false, source: "",
                             secondary: nil, canAutoStart: true)
        s.blockedUntil = blockedFor.map { now.addingTimeInterval($0) }
        return s
    }

    func testStartsOnlyWhenAFreshWindowIsWaiting() {
        let cmd = #"claude -p "hi""#
        XCTAssertTrue(Store.shouldStartFromWidget(claude(.ready), command: cmd, kicking: false, demo: false, now: now))
        XCTAssertFalse(Store.shouldStartFromWidget(claude(.active(resetsAt: now.addingTimeInterval(3600))), command: cmd, kicking: false, demo: false, now: now),
                       "a window is already running")
        XCTAssertFalse(Store.shouldStartFromWidget(claude(.ready), command: cmd, kicking: true, demo: false, now: now), "already starting")
        XCTAssertFalse(Store.shouldStartFromWidget(claude(.ready, blockedFor: 3600), command: cmd, kicking: false, demo: false, now: now),
                       "weekly limit: a new window wouldn't help")
        XCTAssertTrue(Store.shouldStartFromWidget(claude(.ready, blockedFor: -60), command: cmd, kicking: false, demo: false, now: now),
                      "a weekly limit that has ended doesn't block")
        XCTAssertFalse(Store.shouldStartFromWidget(claude(.ready), command: "", kicking: false, demo: false, now: now), "no command")
        XCTAssertFalse(Store.shouldStartFromWidget(claude(.ready), command: cmd, kicking: false, demo: true, now: now), "demo mode")
        XCTAssertFalse(Store.shouldStartFromWidget(nil, command: cmd, kicking: false, demo: false, now: now))
    }

    func testRefusalsSayWhy() {
        let cmd = #"claude -p "hi""#
        XCTAssertEqual(Store.widgetStartBlocker(claude(.ready), command: "", kicking: false, demo: false, now: now),
                       "no start command is set (Settings → Advanced)", "not \"already starting\"")
        XCTAssertTrue(Store.widgetStartBlocker(claude(.ready, blockedFor: 3600), command: cmd, kicking: false, demo: false, now: now)?
                        .hasPrefix("the weekly limit is used up") == true)
        XCTAssertEqual(Store.widgetStartBlocker(claude(.active(resetsAt: now.addingTimeInterval(60))), command: cmd, kicking: false, demo: false, now: now),
                       "a window is already running")
    }

    func testAutoStartRunsWithoutHooks() {
        XCTAssertTrue(Kicker.defaultCommands()["claude"]?.contains(#"--settings '{"disableAllHooks":true}'"#) == true)
        let old = ["claude": #""/x/claude" -p "hi" --model haiku --tools "" --strict-mcp-config"#, "codex": "codex exec hi"]
        XCTAssertTrue(Kicker.upgraded(old)["claude"]?.hasSuffix(Kicker.noHooks) == true, "a saved default gets it")
        XCTAssertEqual(Kicker.upgraded(Kicker.upgraded(old)), Kicker.upgraded(old), "only once")
        XCTAssertEqual(Kicker.upgraded(["claude": "my own script"])["claude"], "my own script", "a custom command is left alone")
        XCTAssertEqual(Kicker.upgraded(old)["codex"], "codex exec hi")
    }

    func testRequestPostedByTheWidgetReachesTheListener() {
        // A made-up provider name, so the app's real listener (for "claude") never hears it.
        let provider = "test-\(UUID().uuidString)"
        let heard = expectation(description: "listener called")
        let listener = StartRequest.Listener(name: StartRequest.name(provider)) { heard.fulfill() }
        StartRequest.post(provider)
        wait(for: [heard], timeout: 5)
        withExtendedLifetime(listener) {}
    }

    func testAReleasedListenerStopsListening() {
        let provider = "test-\(UUID().uuidString)"
        let heard = expectation(description: "not called")
        heard.isInverted = true
        var listener: StartRequest.Listener? = StartRequest.Listener(name: StartRequest.name(provider)) { heard.fulfill() }
        listener = nil
        StartRequest.post(provider)
        wait(for: [heard], timeout: 1)
        XCTAssertNil(listener)
    }
}
