import XCTest
@testable import Reset

/// Work Reset does over and over in the background: each scan and each redraw should only redo what changed.
final class ScanCostTests: XCTestCase {
    func testATenHourLookbackKeepsTheWeeksParsedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("-Users-example-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func write(_ name: String, at time: Date, modified: Date? = nil) throws {
            let url = folder.appendingPathComponent(name)
            let row = #"{"type":"assistant","timestamp":""# + iso.string(from: time)
                + #"","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":5}}}"#
            try (row + "\n").write(to: url, atomically: true, encoding: .utf8)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        // Enough files from earlier in the week that the scanner tidies its cache after the 10-hour look.
        let twoDaysAgo = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 2 * 86400).rounded())
        for i in 0...201 { try write("old-\(i).jsonl", at: twoDaysAgo, modified: twoDaysAgo) }
        try write("new.jsonl", at: Date().addingTimeInterval(-60))

        let scanner = TranscriptScanner()
        let week = Date().addingTimeInterval(-7 * 86400)
        XCTAssertEqual(scanner.events(under: root, since: week).count, 203)
        XCTAssertEqual(scanner.events(under: root, since: Date().addingTimeInterval(-10 * 3600)).count, 1)

        // Same size, same date, different content: only a file that's no longer remembered is read again.
        try write("old-0.jsonl", at: twoDaysAgo.addingTimeInterval(3600), modified: twoDaysAgo)
        let again = scanner.events(under: root, since: week)
        XCTAssertEqual(again.count, 203)
        XCTAssertFalse(again.contains { $0.time > twoDaysAgo.addingTimeInterval(60) && $0.time < Date().addingTimeInterval(-3600) },
                       "the week's transcripts were parsed again instead of coming from the cache")
    }

    func testParsingMarksATranscriptSearchedForItsAccount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // A subagent's transcript: usage, but no credential rows naming the account.
        let row = #"{"type":"assistant","timestamp":"2026-03-02T09:14:05.120Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":5}}}"#
        try (row + "\n").write(to: url, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

        let parsed = ClaudeUsageScanner.parse(url, mtime: Date(), size: size, from: 0)
        XCTAssertNil(parsed.org)
        XCTAssertEqual(parsed.orgSearched, true, "searched, found nothing: not worth searching again")
        XCTAssertEqual(ClaudeUsageScanner.merge(parsed, parsed).orgSearched, true)
        var older = parsed
        older.orgSearched = nil
        XCTAssertNil(ClaudeUsageScanner.merge(older, parsed).orgSearched, "the part cached before accounts were tracked wasn't searched")
    }

    func testRememberedTotalsFollowEachScanRangeAndAccount() {
        func call(_ id: String, cost: Double, daysAgo: Double = 0, org: String? = nil) -> Call {
            Call(id: id, time: Date().addingTimeInterval(-daysAgo * 86400), model: "claude-opus-5-5", session: "s", project: "/tmp/p",
                 sidechain: false, input: 0, cw5: 0, cw1h: 0, cacheRead: 0, output: 0, advisorTokens: 0, tools: 0, mcpServers: [:],
                 webSearches: 0, mcpAttribution: nil, cost: cost, autoStart: false, org: org)
        }
        // The range and account are saved settings; put back whatever they were.
        let d = UserDefaults.standard
        let saved = ["usageRange", "usageAccount"].map { ($0, d.object(forKey: $0)) }
        addTeardownBlock { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        let usage = UsageStore()
        usage.range = .month
        usage.account = nil
        usage.load(calls: [call("a", cost: 2)])
        XCTAssertEqual(usage.totalCost, 2)
        XCTAssertEqual(usage.todayCost, 2)
        XCTAssertEqual(usage.projects.first?.cost, 2)

        usage.load(calls: [call("a", cost: 2), call("b", cost: 3)])
        XCTAssertEqual(usage.totalCost, 5, "the new scan's calls, not the remembered total")
        XCTAssertEqual(usage.todayCost, 5)
        XCTAssertEqual(usage.weekCost, 5)
        XCTAssertEqual(usage.projects.first?.cost, 5)
        XCTAssertEqual(usage.sessions.first?.cost, 5)

        usage.load(calls: [call("a", cost: 2, org: "org-a"), call("b", cost: 3, daysAgo: 3, org: "org-b")])
        XCTAssertEqual(usage.totalCost, 5)
        usage.range = .today
        XCTAssertEqual(usage.totalCost, 2, "a new range")
        usage.range = .month
        // The account is chosen first and the list arrives with a scan, as when the app starts.
        usage.account = "claude-orgb"
        XCTAssertEqual(usage.totalCost, 5, "one account isn't a choice yet")
        usage.accounts = [("claude", "Team", "org-a"), ("claude-orgb", "Pro", "org-b")]
        XCTAssertEqual(usage.totalCost, 3, "another account")
    }
}
