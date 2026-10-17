import SQLite3
import XCTest
@testable import Reset

/// Cursor's monthly usage, read with the sign-in the Cursor app keeps on this Mac.
final class CursorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    func testReadsThePercentAndTheMonthsEnd() throws {
        // Protobuf's JSON writes 64-bit numbers as strings.
        let r = try XCTUnwrap(CursorSource.reading(from: ["billingCycleStart": "1770000000000", "billingCycleEnd": "1772592000000",
                                                          "planUsage": ["totalPercentUsed": 46.5, "autoPercentUsed": 25, "apiPercentUsed": 67.8]],
                                                   at: now))
        XCTAssertEqual(r.percent, 46.5)
        XCTAssertEqual(r.resetsAt, Date(timeIntervalSince1970: 1_772_592_000))
        XCTAssertEqual(r.fetchedAt, now)
    }

    func testWorksOutThePercentFromSpendWhenItIsMissing() throws {
        let fromRemaining = try XCTUnwrap(CursorSource.reading(from: ["planUsage": ["limit": 2000, "remaining": 1500]], at: now))
        XCTAssertEqual(fromRemaining.percent, 25)
        XCTAssertNil(fromRemaining.resetsAt)
        XCTAssertEqual(CursorSource.reading(from: ["planUsage": ["limit": "2000", "totalSpend": "500"]], at: now)?.percent, 25)
        XCTAssertEqual(CursorSource.reading(from: ["planUsage": ["totalPercentUsed": 130]], at: now)?.percent, 100, "capped")
        XCTAssertNil(CursorSource.reading(from: ["planUsage": ["limit": 0]], at: now), "nothing to work it out from")
        XCTAssertNil(CursorSource.reading(from: ["billingCycleEnd": "1772592000000"], at: now), "no plan usage at all")
        XCTAssertNil(CursorSource.reading(from: ["planUsage": ["totalPercentUsed": "NaN"]], at: now), "protobuf's JSON for NaN")
    }

    func testFetchesAgainSoonerAfterAFailureOrWhenTheMonthEnds() {
        let good = CursorSource.Reading(percent: 40, resetsAt: now.addingTimeInterval(86400), plan: nil, fetchedAt: now)
        let ended = CursorSource.Reading(percent: 99, resetsAt: now.addingTimeInterval(-1), plan: nil, fetchedAt: now)
        let failed: Result<CursorSource.Reading, CursorSource.Problem> = .failure(.init(message: "offline"))
        XCTAssertTrue(CursorSource.isDue(nil, now: now), "nothing read yet")
        XCTAssertFalse(CursorSource.isDue((now.addingTimeInterval(-299), .success(good)), now: now))
        XCTAssertTrue(CursorSource.isDue((now.addingTimeInterval(-300), .success(good)), now: now))
        XCTAssertFalse(CursorSource.isDue((now.addingTimeInterval(-59), failed), now: now))
        XCTAssertTrue(CursorSource.isDue((now.addingTimeInterval(-60), failed), now: now))
        XCTAssertTrue(CursorSource.isDue((now.addingTimeInterval(-60), .success(ended)), now: now), "a new month is starting")
    }

    func testABlipShowsTheLastGoodReadingForAWhile() {
        let good = CursorSource.Reading(percent: 40, resetsAt: now.addingTimeInterval(86400), plan: nil, fetchedAt: now)
        let failed: Result<CursorSource.Reading, CursorSource.Problem> = .failure(.init(message: "offline"))
        XCTAssertEqual(CursorSource.shown(failed, lastGood: good, now: now.addingTimeInterval(14 * 60)), .success(good))
        XCTAssertEqual(CursorSource.shown(failed, lastGood: good, now: now.addingTimeInterval(15 * 60)), failed, "too old by now")
        XCTAssertEqual(CursorSource.shown(failed, lastGood: nil, now: now), failed, "nothing good to show")
        let newer = CursorSource.Reading(percent: 45, resetsAt: nil, plan: nil, fetchedAt: now)
        XCTAssertEqual(CursorSource.shown(.success(newer), lastGood: good, now: now), .success(newer))
    }

    func testOffReadsNothing() {
        let s = CursorSource(enabled: false).read(now: now)
        XCTAssertEqual(s.state, .unavailable("Off"))
        XCTAssertFalse(s.canAutoStart)
        XCTAssertTrue(s.source.hasPrefix("Switch on"), "the Settings row says what switching it on does")
    }

    func testReadsTheSignInFromCursorsSettingsDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vscdb")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'a.b.c'), ('cursorAuth/stripeMembershipType', 'pro'),
                                         ('cursorAuth/refreshToken', 'never-read');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let auth = try XCTUnwrap(CursorSource.readSignIn(db: url))
        XCTAssertEqual(auth.token, "a.b.c")
        XCTAssertEqual(auth.plan, "pro")
        XCTAssertNil(CursorSource.readSignIn(db: url.appendingPathExtension("missing")), "no Cursor on this Mac")
    }

    func testTheSignInsExpiryComesFromTheToken() {
        let claims = Data(#"{"sub":"auth0|user_1","exp":1781100000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(CursorSource.expiry(of: "header.\(claims).signature"), Date(timeIntervalSince1970: 1_781_100_000))
        XCTAssertNil(CursorSource.expiry(of: "not-a-token"))
    }

    func testNames() {
        XCTAssertEqual(CursorSource.planLabel("pro"), "Pro")
        XCTAssertEqual(CursorSource.planLabel("business"), "Business")
        XCTAssertNil(CursorSource.planLabel("free"))
        XCTAssertNil(CursorSource.planLabel(nil))
    }

    func testAMonthLongWindow() {
        XCTAssertEqual(WindowStatus.length(of: "cursor"), 30 * 86400)
        XCTAssertEqual(WindowStatus.length(of: "gemini"), 86400)
        XCTAssertEqual(WindowStatus.length(of: "claude"), 5 * 3600)
        XCTAssertEqual(CountdownText.hm(5 * 86400 + 7 * 3600 + 30 * 60), "5d 7h", "not \"127:30\"")
        XCTAssertEqual(CountdownText.hm(2 * 3600 + 46 * 60), "2:46")
    }
}
