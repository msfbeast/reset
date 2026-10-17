import XCTest
@testable import Reset

/// What the menu bar says, and in which colour.
final class MenuBarGlanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func s(_ state: WindowStatus.State, id: String = "claude", name: String = "Claude", used: Double? = nil,
                   blockedFor: TimeInterval? = nil) -> WindowStatus {
        var w = WindowStatus(id: id, name: name, state: state, usedPercent: used, isEstimate: false, source: "", secondary: nil, canAutoStart: true)
        w.blockedUntil = blockedFor.map { now.addingTimeInterval($0) }
        return w
    }
    private func active(_ resetIn: TimeInterval, used: Double? = 58) -> WindowStatus {
        s(.active(resetsAt: now.addingTimeInterval(resetIn)), used: used)
    }
    private func glance(ready: WindowStatus? = nil, soonest: WindowStatus? = nil, blocked: WindowStatus? = nil,
                        out: TimeInterval? = nil, signedOut: Bool = false) -> MenuBarGlance? {
        MenuBarGlance.make(ready: ready, soonest: soonest, blocked: blocked, runsOutAt: out.map { now.addingTimeInterval($0) },
                           signedOut: signedOut, now: now)
    }

    func testNormalShowsCountdownAndWhatsLeftInOrange() {
        let g = glance(soonest: active(2 * 3600 + 46 * 60))
        XCTAssertEqual(g?.tone, .normal)
        XCTAssertEqual(g?.text, "2:46 · 42%")
    }

    func testLittleLeftTurnsRed() {
        XCTAssertEqual(glance(soonest: active(1800, used: 91))?.tone, .low)
        XCTAssertEqual(glance(soonest: active(1800, used: 91))?.text, "0:30 · 9%")
        XCTAssertEqual(glance(soonest: active(1800, used: 84))?.tone, .normal, "16% left is still orange")
    }

    func testPaceRunningOutBeforeTheResetTurnsRedWithTheTime() {
        let g = glance(soonest: active(2 * 3600, used: 14), out: 52 * 60)
        XCTAssertEqual(g?.tone, .runningOut)
        XCTAssertTrue(g?.text.hasPrefix("86% · out ") == true, "what's left and when it runs out, not the reset countdown")
        XCTAssertFalse(g?.text.contains("2:00") == true)
        XCTAssertTrue(glance(soonest: active(2 * 3600, used: nil), out: 52 * 60)?.text.hasPrefix("2:00 · out ") == true,
                      "without a usage reading it falls back to the countdown")
        XCTAssertEqual(glance(soonest: active(3600), out: 7200)?.tone, .normal, "running out after the reset doesn't matter")
    }

    func testFreshWindowIsGreenReady() {
        let g = glance(ready: s(.ready))
        XCTAssertEqual(g?.tone, .ready)
        XCTAssertEqual(g?.text, "ready")
    }

    func testWeeklyLimitOutranksEverything() {
        let g = glance(ready: s(.ready), soonest: active(3600), blocked: s(.ready, blockedFor: 86400))
        XCTAssertEqual(g?.tone, .blocked)
    }

    func testUnknownUsageShowsOnlyTheCountdown() {
        XCTAssertEqual(glance(soonest: active(3600, used: nil))?.text, "1:00", "no % that would really be the clock")
    }

    func testOtherToolsGetTheirLetterAndSignedOutGetsAWarning() {
        let codex = s(.active(resetsAt: now.addingTimeInterval(3600)), id: "codex", name: "Codex", used: 20)
        XCTAssertEqual(glance(soonest: codex)?.text, "C 1:00 · 80%")
        XCTAssertEqual(glance(soonest: codex, signedOut: true)?.warning, false, "the sign-in warning is Claude's")
        XCTAssertEqual(glance(soonest: active(3600), signedOut: true)?.warning, true)
    }

    func testVoiceOverHearsItInWords() {
        XCTAssertEqual(glance(soonest: active(2 * 3600 + 46 * 60))?.spoken, "Claude: 2 hours 46 minutes until the reset, 42 percent left")
        XCTAssertEqual(glance(soonest: active(1800, used: 91))?.spoken, "Claude: 30 minutes until the reset, 9 percent left, almost empty")
        XCTAssertTrue(glance(soonest: active(2 * 3600, used: 14), out: 52 * 60)?.spoken
            .hasPrefix("Claude: 86 percent left, but at this pace it runs out at ") == true)
        XCTAssertEqual(glance(ready: s(.ready))?.spoken, "Claude: a fresh window is ready")
        XCTAssertTrue(glance(soonest: active(3600), signedOut: true)?.spoken.hasPrefix("Claude Code is signed out. Claude: ") == true)
        let pro = s(.active(resetsAt: now.addingTimeInterval(3600)), id: "claude-pro", name: "Claude · Pro", used: 20)
        XCTAssertEqual(glance(soonest: pro)?.spoken, "Claude Pro: 1 hour until the reset, 80 percent left", "no \"dot\" read aloud")
    }

    func testDurationsInWords() {
        XCTAssertEqual(MenuBarGlance.words(60), "1 minute")
        XCTAssertEqual(MenuBarGlance.words(3600), "1 hour")
        XCTAssertEqual(MenuBarGlance.words(2 * 3600 + 60), "2 hours 1 minute")
        XCTAssertEqual(MenuBarGlance.words(20), "less than a minute")
    }

    func testTheAccountInUseOutranksAnUnusedSecondAccount() {
        // Team (the CLI's account) at 45% left; Pro unused, so "ready", with a sooner reset elsewhere and a weekly limit.
        let team = s(.active(resetsAt: now.addingTimeInterval(3 * 3600)), name: "Claude · Team", used: 55)
        let pro = s(.ready, id: "claude-6ac79bdb", name: "Claude · Pro")
        let proSooner = s(.active(resetsAt: now.addingTimeInterval(600)), id: "claude-6ac79bdb", name: "Claude · Pro")
        let proBlocked = s(.ready, id: "claude-6ac79bdb", name: "Claude · Pro", blockedFor: 86400)
        for other in [pro, proSooner, proBlocked] {
            let p = MenuBarGlance.pick([other, team], now: now)
            XCTAssertNil(p.ready); XCTAssertNil(p.blocked)
            XCTAssertEqual(p.soonest?.id, "claude", "\(other.state)")
        }
        // Between Team windows, Pro being ready is worth saying.
        let p = MenuBarGlance.pick([s(.ready, name: "Claude · Team"), pro], now: now)
        XCTAssertEqual(p.ready?.id, "claude")
        // Team's own weekly limit still shows.
        let teamBlocked = s(.active(resetsAt: now.addingTimeInterval(3600)), blockedFor: 86400)
        XCTAssertEqual(MenuBarGlance.pick([teamBlocked, pro], now: now).blocked?.id, "claude")
    }

    func testNothingToShow() {
        XCTAssertNil(glance())
    }

    // MARK: Limits shown (Settings → Appearance)

    private func weekly(_ s: WindowStatus, used: Double?, in resetIn: TimeInterval = 3 * 86400 + 3600, label: String = "Weekly") -> WindowStatus {
        var s = s
        s.secondary = .init(label: label, resetsAt: now.addingTimeInterval(resetIn), usedPercent: used)
        return s
    }
    private func shown(_ limits: MenuBarGlance.Limits, ready: WindowStatus? = nil, soonest: WindowStatus? = nil,
                       blocked: WindowStatus? = nil, out: TimeInterval? = nil) -> MenuBarGlance? {
        MenuBarGlance.make(ready: ready, soonest: soonest, blocked: blocked, runsOutAt: out.map { now.addingTimeInterval($0) },
                           signedOut: false, limits: limits, now: now)
    }

    func testBothPutsTheWeeklyLimitUnderTheSessionWindow() {
        let s = weekly(active(2 * 3600 + 46 * 60), used: 40)
        let g = shown(.both, soonest: s)
        XCTAssertEqual(g?.text, "2:46 · 42%")
        XCTAssertEqual(g?.detail, "wk 3d · 60%")
        XCTAssertEqual(g?.tone, .normal)
        XCTAssertTrue(g?.spoken.hasSuffix("42 percent left; weekly limit 60 percent left, resets \(Fmt.when(s.secondary!.resetsAt, now: now))") == true)
        XCTAssertEqual(shown(.session, soonest: s), glance(soonest: s), "5-hour is how the bar has always been")
        XCTAssertNil(shown(.session, soonest: s)?.detail)
    }

    func testWeeklyAloneReplacesTheSessionWindow() {
        let g = shown(.weekly, soonest: weekly(active(2 * 3600 + 46 * 60), used: 40))
        XCTAssertEqual(g?.text, "wk 3d · 60%")
        XCTAssertNil(g?.detail)
        XCTAssertEqual(g?.tone, .normal)
        XCTAssertTrue(g?.spoken.hasPrefix("Claude: weekly limit 60 percent left, resets ") == true)
        XCTAssertEqual(shown(.weekly, soonest: weekly(active(3600), used: 40, in: 5 * 3600 + 59 * 60))?.text, "wk 5h · 60%", "under a day, hours")
        XCTAssertEqual(MenuBarGlance.roughly(40 * 60), "40m")
        let codex = weekly(s(.active(resetsAt: now.addingTimeInterval(3600)), id: "codex", name: "Codex", used: 20), used: 10)
        XCTAssertEqual(shown(.weekly, soonest: codex)?.text, "C wk 3d · 90%")
    }

    func testALowWeeklyLimitTurnsThePillRed() {
        XCTAssertEqual(shown(.weekly, soonest: weekly(active(3600, used: 10), used: 80))?.tone, .low, "where the weekly warning starts")
        XCTAssertEqual(shown(.weekly, soonest: weekly(active(3600, used: 10), used: 79))?.tone, .normal)
        XCTAssertEqual(shown(.both, soonest: weekly(active(3600, used: 10), used: 90))?.tone, .low, "the session is fine, the week isn't")
        XCTAssertEqual(shown(.both, soonest: weekly(active(3600, used: 10), used: 79))?.tone, .normal)
        XCTAssertEqual(shown(.both, ready: weekly(s(.ready), used: 90))?.tone, .ready, "a fresh window is still worth saying")
    }

    func testWithoutAWeeklyReadingTheSessionWindowShows() {
        let plain = active(3600)
        for limits in [MenuBarGlance.Limits.weekly, .both] {
            XCTAssertEqual(shown(limits, soonest: plain), glance(soonest: plain), "\(limits): no weekly limit (Enterprise, Gemini)")
            XCTAssertEqual(shown(limits, soonest: weekly(plain, used: nil)), glance(soonest: plain), "\(limits): no percentage")
            XCTAssertEqual(shown(limits, soonest: weekly(plain, used: 40, in: -60)), glance(soonest: plain), "\(limits): already reset")
            XCTAssertEqual(shown(limits, soonest: weekly(plain, used: 40, label: "Monthly")), glance(soonest: plain), "\(limits): not weekly")
        }
    }

    func testAUsedUpWeeklyLimitStillShowsTheMoon() {
        let b = weekly(s(.ready, blockedFor: 86400), used: 100)
        XCTAssertEqual(shown(.both, soonest: active(3600), blocked: b)?.tone, .blocked)
        XCTAssertNil(shown(.both, soonest: active(3600), blocked: b)?.detail)
        XCTAssertEqual(shown(.weekly, soonest: active(3600), blocked: b), glance(soonest: active(3600), blocked: b))
    }

    func testWeeklyModeKeepsTheGreenAndRedSignals() {
        // A fresh window is still green, and a pace that runs out first is still red, even showing the week.
        let ready = shown(.weekly, ready: weekly(s(.ready), used: 40))
        XCTAssertEqual(ready?.tone, .ready)
        XCTAssertEqual(ready?.text, "wk 3d · 60%")
        XCTAssertTrue(ready?.spoken.contains("a fresh window is ready; weekly limit 60 percent left") == true)
        let racing = shown(.weekly, soonest: weekly(active(3 * 3600, used: 60), used: 40), out: 3600)
        XCTAssertEqual(racing?.tone, .runningOut)
        XCTAssertTrue(racing?.spoken.contains("before the reset; weekly limit") == true, "VoiceOver hears why it's red")
        XCTAssertEqual(shown(.weekly, soonest: weekly(active(3 * 3600, used: 10), used: 85))?.tone, .low, "otherwise the week decides")
    }

    func testTheReadyEntrysWeeklyLimitIsTheOneShown() {
        let g = shown(.both, ready: weekly(s(.ready), used: 25), soonest: weekly(active(600), used: 90))
        XCTAssertEqual(g?.text, "ready")
        XCTAssertEqual(g?.detail, "wk 3d · 75%")
    }

    @MainActor func testPillIsAColouredImageNotATemplate() throws {
        let img = try XCTUnwrap(MenuBarPill.image(MenuBarGlance(tone: .runningOut, text: "0:52 · out 6:40")))
        XCTAssertFalse(img.isTemplate, "a template image would be painted in one colour")
        XCTAssertEqual(img.size.height, 17, accuracy: 1, "fits the menu bar")
        XCTAssertGreaterThan(img.size.width, 60)
        let both = try XCTUnwrap(MenuBarPill.image(MenuBarGlance(tone: .normal, text: "2:46 · 42%", detail: "wk 3d · 60%")))
        XCTAssertLessThanOrEqual(both.size.height, 22, "two lines still fit the menu bar")
        XCTAssertLessThan(both.size.width, img.size.width, "stacked, not side by side")
    }
}
