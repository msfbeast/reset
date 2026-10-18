import XCTest
@testable import Reset

/// Setting up Claude Code's status line and MCP server from Settings, on temporary copies of its files.
final class IntegrationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ obj: [String: Any], _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    func testStatusLineStates() throws {
        XCTAssertEqual(ClaudeIntegration.statusLineState(settings: dir.appendingPathComponent("none.json")), .missing)
        let ours = try write(["statusLine": ["type": "command", "command": #"cat "$HOME/Library/Application Support/Reset/statusline.txt""#]], "a.json")
        XCTAssertEqual(ClaudeIntegration.statusLineState(settings: ours), .outdated, "the older plain cat can't tell Reset quit")
        let theirs = try write(["statusLine": ["type": "command", "command": "~/bin/my-line"]], "b.json")
        XCTAssertEqual(ClaudeIntegration.statusLineState(settings: theirs), .other("~/bin/my-line"))
    }

    func testInstallKeepsOtherSettingsAndBacksUpTheFile() throws {
        let settings = try write(["model": "opus", "permissions": ["allow": ["Bash(ls:*)"]]], "settings.json")
        try ClaudeIntegration.installStatusLine(settings: settings)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "opus")
        XCTAssertEqual((obj["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(ClaudeIntegration.statusLineState(settings: settings), .installed)
        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings.appendingPathExtension("before-reset"))) as? [String: Any])
        XCTAssertNil(backup["statusLine"], "the backup is the file as it was")
    }

    func testInstallCreatesAMissingFileButLeavesBrokenOnesAlone() throws {
        let fresh = dir.appendingPathComponent("sub/settings.json")
        try ClaudeIntegration.installStatusLine(settings: fresh)
        XCTAssertEqual(ClaudeIntegration.statusLineState(settings: fresh), .installed)
        let broken = dir.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: broken)
        XCTAssertThrowsError(try ClaudeIntegration.installStatusLine(settings: broken))
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{ not json")
    }

    /// Runs the real status line command in a shell, against a made-up home folder.
    private func runStatusLine(home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", ClaudeIntegration.statusLineCommand]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func testStatusLineSaysWhenResetIsntRunning() throws {
        let folder = dir.appendingPathComponent("Library/Application Support/Reset")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "◷ Claude 42% left".write(to: folder.appendingPathComponent("statusline.txt"), atomically: true, encoding: .utf8)
        let beat = folder.appendingPathComponent("running")
        Heartbeat.beat(at: beat)
        XCTAssertEqual(try runStatusLine(home: dir), "◷ Claude 42% left")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: beat.path)
        XCTAssertEqual(try runStatusLine(home: dir), "◷ Reset isn't running", "a heartbeat 10 minutes old")
        Heartbeat.stop(at: beat)
        XCTAssertEqual(try runStatusLine(home: dir), "◷ Reset isn't running", "quit")
        XCTAssertFalse(WidgetSnapshot.appRunning(heartbeat: beat))
    }

    func testMCPStateFollowsWhereThisCopyLives() throws {
        let path = "/Applications/Reset.app/Contents/MacOS/reset-mcp"
        let json = try write(["mcpServers": ["reset": ["type": "stdio", "command": path]]], "claude.json")
        XCTAssertEqual(ClaudeIntegration.mcpState(claudeJSON: json, path: path), .installed)
        let moved = "/Users/x/Applications/Reset.app/Contents/MacOS/reset-mcp"
        XCTAssertEqual(ClaudeIntegration.mcpState(claudeJSON: json, path: moved), .other(path))
        XCTAssertEqual(ClaudeIntegration.mcpCommands(state: .other(path), path: moved).map { $0[1] }, ["remove", "add"],
                       "an old path is replaced, not added twice")
        XCTAssertEqual(ClaudeIntegration.mcpCommands(state: .missing, path: moved).last?.last, moved)
        XCTAssertEqual(ClaudeIntegration.mcpState(claudeJSON: try write(["mcpServers": [:]], "empty.json"), path: path), .missing)
    }
}

/// Small pieces of the dashboard and Settings that are easy to get subtly wrong.
final class SmallUXTests: XCTestCase {
    func testResumeCommandQuotesTheFolder() {
        XCTAssertEqual(DashboardView.resumeCommand(project: "/Users/a/My App", session: "abc-123"),
                       "cd '/Users/a/My App' && claude --resume abc-123")
        XCTAssertEqual(DashboardView.resumeCommand(project: "/Users/a/Sam's", session: "x"),
                       #"cd '/Users/a/Sam'\''s' && claude --resume x"#, "a quote in the folder name can't break out")
    }

    func testPhoneTestOutcomeFitsBesideTheButton() {
        XCTAssertEqual(Alerts.testOutcome("Phone test sent"), "Sent ✓")
        XCTAssertEqual(Alerts.testOutcome("Phone push failed: HTTP 403. Will retry"), "Failed: HTTP 403")
    }
}

/// "All" means all time: everything on disk, with the plan spread from the first response on record.
final class AllTimeRangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    func testAllRunsFromTheFirstResponseOnRecord() {
        XCTAssertEqual(UsageRange.all.start(now: now), .distantPast, "every response counts, not the last 35 days")
        XCTAssertEqual(UsageRange.all.days(now: now, first: now.addingTimeInterval(-96 * 86400)), 96, accuracy: 0.001,
                       "the plan price for All covers the 96 days since the first response")
        XCTAssertEqual(UsageRange.week.days(now: now, first: now.addingTimeInterval(-96 * 86400)), 7, accuracy: 0.001,
                       "other ranges ignore it")
        XCTAssertEqual(UsageRange.all.days(now: now), 1 / 24, accuracy: 0.001, "nothing on record yet")
    }

    func testTheHeatmapStillCoversFiveWeeks() {
        func call(_ daysAgo: Double) -> Call {
            Call(id: UUID().uuidString, time: now.addingTimeInterval(-daysAgo * 86400), model: "claude-opus-5-5", session: "s",
                 project: "/tmp/p", sidechain: false, input: 0, cw5: 0, cw1h: 0, cacheRead: 0, output: 10, advisorTokens: 0,
                 tools: 0, mcpServers: [:], webSearches: 0, mcpAttribution: nil, cost: 0, autoStart: false, org: nil)
        }
        XCTAssertEqual(UsageStore.recent([call(2), call(34), call(36), call(90)], now: now).count, 2,
                       "\"last 5 weeks\" stays true now that All reaches further back")
    }
}
