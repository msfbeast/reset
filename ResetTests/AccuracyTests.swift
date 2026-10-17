import XCTest
import SwiftUI
@testable import Reset

/// Estimates must say so, and why; the clock must never be passed off as usage.
final class AccuracyTests: XCTestCase {
    private func note(estimate: Bool = true, known: Bool = false, live: Bool = false, working: Bool = false, signedOut: Bool = false) -> String? {
        UsageAccuracy.note(isEstimate: estimate, usageKnown: known, liveEnabled: live, liveWorking: working, needsSignIn: signedOut)
    }

    func testReasonsInTheOrderAUserWouldFixThem() {
        XCTAssertEqual(note(), "estimated · live usage off")
        XCTAssertEqual(note(live: true, signedOut: true), "estimated · Claude Code signed out")
        XCTAssertEqual(note(live: true), "estimated · live usage unavailable")
        XCTAssertEqual(note(live: true, working: true), "estimated · waiting for live usage")
    }

    func testSolidNumbersHaveNoNote() {
        XCTAssertNil(note(estimate: false, known: true, live: true, working: true), "live")
        XCTAssertNil(note(estimate: false, known: true), "exact reset plus a desktop-app reading, live off")
    }

    func testExactResetWithoutUsageSaysUsageUnknown() {
        XCTAssertEqual(note(estimate: false, known: false), "usage unknown · live usage off")
    }

    private func card(used: Double?, resetIn: TimeInterval? = 3 * 3600, ready: Bool = false) -> CardData {
        let now = Date()
        return CardData(id: "claude", name: "Claude", color: .orange, windowStart: nil,
                        resetsAt: resetIn.map { now.addingTimeInterval($0) }, ready: ready, used: used)
    }

    func testLeftPhraseSaysTimeWhenUsageIsUnknown() {
        let now = Date()
        XCTAssertEqual(card(used: 58).leftPhrase(at: now), "42% left")
        XCTAssertEqual(card(used: nil).leftPhrase(at: now), "~60% of time left", "3h of 5h is time, not usage")
        XCTAssertEqual(card(used: nil, resetIn: nil, ready: true).leftPhrase(at: now), "100% left", "a fresh window is full either way")
        XCTAssertEqual(card(used: 58).leftWord(at: now), "left")
        XCTAssertEqual(card(used: nil).leftWord(at: now), "time left")
    }

    func testMCPReportsWhetherNumbersAreEstimated() {
        let now = Date()
        func report(_ estimate: String?) -> [String: Any]? {
            let p = WidgetSnapshot.Provider(id: "claude", name: "Claude", resetsAt: now.addingTimeInterval(3600), ready: false,
                                            available: true, used: 40, blockedUntil: nil, estimate: estimate)
            let snap = WidgetSnapshot(updated: now, providers: [p], windows: [], weekCost: 0, cacheHit: 0)
            return MCPServer.usageReport(snapshot: snap, budget: nil, now: now)["claude"] as? [String: Any]
        }
        XCTAssertEqual(report(nil)?["estimated"] as? Bool, false)
        XCTAssertNil(report(nil)?["estimate_note"])
        XCTAssertEqual(report("estimated · live usage off")?["estimated"] as? Bool, true)
        XCTAssertEqual(report("estimated · live usage off")?["estimate_note"] as? String, "estimated · live usage off")
    }

    func testOldSnapshotsWithoutTheFieldStillDecode() throws {
        let json = #"{"id":"claude","name":"Claude","ready":false,"available":true,"used":40}"#
        let p = try JSONDecoder().decode(WidgetSnapshot.Provider.self, from: Data(json.utf8))
        XCTAssertNil(p.estimate)
    }

    /// Another account's window is always from its sessions; an agent on it should be told why, not pointed at nothing.
    func testAnotherAccountSaysWhyItsUsageIsAGuess() {
        XCTAssertEqual(UsageAccuracy.otherAccountNote(isEstimate: false, usageKnown: false),
                       "usage unknown · live usage only reads the account Claude Code in Terminal is signed in to")
        XCTAssertTrue(UsageAccuracy.otherAccountNote(isEstimate: true, usageKnown: true)?.hasPrefix("estimated") == true)
        XCTAssertNil(UsageAccuracy.otherAccountNote(isEstimate: false, usageKnown: true), "an exact reset with a reading is solid")
        // With the desktop app's accounts on, one still estimated is one the desktop app isn't signed in to.
        XCTAssertEqual(UsageAccuracy.otherAccountNote(isEstimate: true, usageKnown: false, desktopOn: true),
                       "estimated · not signed in to the Claude desktop app")
        XCTAssertNil(UsageAccuracy.desktopAccountNote(isEstimate: false, usageKnown: true, problem: nil), "live through the desktop app")
        XCTAssertEqual(UsageAccuracy.desktopAccountNote(isEstimate: true, usageKnown: false, problem: nil),
                       "estimated · waiting for live usage through the Claude desktop app", "no reading on it yet still says why")
        XCTAssertEqual(UsageAccuracy.desktopAccountNote(isEstimate: true, usageKnown: false, problem: "expired"), "estimated · expired")
    }
}
