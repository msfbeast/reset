import Foundation
import IOKit.pwr_mgt

/// What one auto-start run achieved. Exit codes alone can't say: a signed-out Claude Code and a run that
/// never reached the API both just "fail", and only one of them needs you.
enum KickOutcome: Equatable {
    /// A real response came back, so the window is open.
    case started
    /// Claude Code isn't signed in or its sign-in was rejected. Retrying can't help until you sign in.
    case signedOut
    /// The provider said the limit is still in force; the estimate was early, so a later retry may work.
    case rateLimited
    /// No answer within the time limit: usually no network, or a slow startup hook or MCP server.
    case timedOut
    case failed(String)

    /// Short code for the auto-start log.
    var kind: String {
        switch self {
        case .started: return "started"
        case .signedOut: return "signed_out"
        case .rateLimited: return "rate_limited"
        case .timedOut: return "timed_out"
        case .failed: return "failed"
        }
    }

    var summary: String {
        switch self {
        case .started: return "started a new window"
        case .signedOut: return "Claude Code is signed out"
        case .rateLimited: return "the limit hadn't reset yet"
        case .timedOut: return "no answer within 3 minutes (no network, or a slow hook or MCP server)"
        case .failed(let why): return why
        }
    }

    /// Judges a run from its exit status, whether Reset had to stop it, the tail of its output, and the last
    /// assistant row of the transcript it wrote (Claude only). The transcript row wins: a token that is present
    /// but rejected still exits like any other failure, and only the row says why.
    static func classify(status: Int32, timedOut: Bool, output: String, lastAssistant: [String: Any]?) -> KickOutcome {
        if let row = lastAssistant {
            let msg = row["message"] as? [String: Any]
            let isError = (row["isApiErrorMessage"] as? Bool) == true
            if !isError, (msg?["model"] as? String) != "<synthetic>", msg?["usage"] != nil { return .started }
            switch row["error"] as? String {
            case "authentication_failed"?: return .signedOut
            case "rate_limit"?: return .rateLimited
            case let e?: return .failed("Claude Code reported \(e)")
            case nil: break
            }
        }
        // A clean exit with no error row is a success; a missing transcript isn't evidence of failure. Checked
        // before the output wording, because a normal reply could mention "rate limit" or "login".
        if status == 0 && !timedOut { return .started }
        let text = output.lowercased()
        // Claude Code's own wording when there is no sign-in, or the sign-in was refused.
        if text.contains("not logged in") || text.contains("please run /login") || text.contains("failed to authenticate") {
            return .signedOut
        }
        if text.contains("rate limit") || text.contains("usage limit") { return .rateLimited }
        if timedOut { return .timedOut }
        let tail = output.split(separator: "\n").last.map(String.init) ?? ""
        return .failed("exit \(status)\(tail.isEmpty ? "" : ": " + tail.prefix(120))")
    }
}

/// Auto-start: when a provider's window has run out, send it a one-word prompt so the next window
/// starts right away instead of waiting for you to wake up. Off by default for every provider.
final class Kicker {
    private var running: Set<String> = []
    private var nextAllowed: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    /// How long a run may take before it's stopped and counted as timed out. Tests shorten it.
    var timeLimit: TimeInterval = 180

    /// Settings for a kick run that switch every hook off while keeping Claude Code's own sign-in (`--bare` skips
    /// hooks too, but then only an API key works, so a kick wouldn't open the subscription's window).
    static let noHooks = #"--settings '{"disableAllHooks":true}'"#

    /// A saved Claude command from before kicks skipped hooks gets the flag added, unless the user changed it into
    /// something else.
    static func upgraded(_ commands: [String: String]) -> [String: String] {
        var out = commands
        if let c = out["claude"], c.hasSuffix("--strict-mcp-config"), !c.contains("disableAllHooks") { out["claude"] = c + " " + noHooks }
        return out
    }

    static func defaultCommands() -> [String: String] {
        let home = NSHomeDirectory()
        func firstExisting(_ paths: [String]) -> String? {
            paths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let claude = firstExisting(["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
            .map { "\"\($0)\"" } ?? "claude"
        let codex = firstExisting(["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                                   "/Applications/Codex.app/Contents/Resources/codex"])
            .map { "\"\($0)\"" } ?? "codex"
        return [
            // No tools and no MCP servers: the kick only needs one API call to open the window. It must
            // still write a transcript (no --no-session-persistence), because that is how Reset sees it.
            // No hooks either (yours or plugins'): a one-word kick has nothing for them to do, and anything they
            // touch is charged to Reset by macOS, which is how Reset came to ask for Apple Music access.
            "claude": "\(claude) -p \"hi\" --model haiku --tools \"\" --strict-mcp-config " + Self.noHooks,
            "codex": "\(codex) exec --skip-git-repo-check \"hi\"",
        ]
    }

    /// Runs `command` in a login shell. Rate-limited per provider: 10 min after a success, and
    /// 15, 30, 60 min after consecutive failures, so a wrong estimate never turns into a retry storm.
    func kick(_ id: String, name: String, command: String, force: Bool = false,
              log: @escaping (String) -> Void, done: @escaping (KickOutcome) -> Void) {
        let now = Date()
        guard !running.contains(id) else { return }
        if !force, let t = nextAllowed[id], now < t { return }
        running.insert(id)
        log("Auto-starting \(name)")

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reset/kick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        // Drain output while the process runs, so a chatty command can never fill the pipe and hang.
        var collected = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            collected = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        // Only a run still going when the limit hits counts as timed out; one that ends at 179 s doesn't.
        let stopped = NSLock()
        var timedOut = false
        let timeout = DispatchWorkItem {
            stopped.lock(); defer { stopped.unlock() }
            if p.isRunning { timedOut = true; p.terminate() }
        }
        let started = Date()
        // A run often starts in a few-second background wake while the Mac sleeps on battery; without this the
        // Mac dozes off mid-run and the window opens minutes late. Held only for the run, capped at its limit.
        let awake = AwakeHold(reason: "Reset is starting your next \(name) window", seconds: timeLimit + 30)
        p.terminationHandler = { [weak self] proc in
            timeout.cancel()
            awake.release()
            _ = reader.wait(timeout: .now() + 5)
            let text = String(data: collected, encoding: .utf8) ?? ""
            stopped.lock(); let wasTimedOut = timedOut; stopped.unlock()
            let row = id == "claude" ? Self.lastAssistantRow(kickDir: dir, since: started) : nil
            let outcome = KickOutcome.classify(status: proc.terminationStatus, timedOut: wasTimedOut, output: text, lastAssistant: row)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running.remove(id)
                if outcome == .started {
                    self.failures[id] = 0
                    self.nextAllowed[id] = Date().addingTimeInterval(600)
                    log("\(name) started a new window")
                } else {
                    let n = (self.failures[id] ?? 0) + 1
                    self.failures[id] = n
                    let wait = Double(15 * (1 << min(n - 1, 2))) * 60
                    self.nextAllowed[id] = Date().addingTimeInterval(wait)
                    log("\(name) auto-start failed: \(outcome.summary)")
                }
                done(outcome)
            }
        }
        do {
            try p.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: timeout)
        } catch {
            awake.release()
            running.remove(id)
            log("\(name) auto-start could not run: \(error.localizedDescription)")
            done(.failed("couldn't run the command: \(error.localizedDescription)"))
        }
    }

    /// Lets the next run go right away, after the reason for the failures (a sign-in) has been fixed.
    func clearBackoff(_ id: String) {
        nextAllowed[id] = nil
        failures[id] = 0
    }

    /// The last assistant row of the newest transcript Claude Code wrote for a kick run in `kickDir`.
    /// Claude Code names a project's folder after its path with every non-alphanumeric character as "-".
    static func lastAssistantRow(kickDir: URL, since: Date,
                                 projects: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) -> [String: Any]? {
        let folder = kickDir.path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let fm = FileManager.default
        let dir = projects.appendingPathComponent(folder)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "jsonl" }
            .compactMap { u -> (URL, Date)? in
                guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      m >= since.addingTimeInterval(-2) else { return nil }
                return (u, m)
            }
            .max { $0.1 < $1.1 }?.0
        guard let newest, let data = try? Data(contentsOf: newest) else { return nil }
        let marker = Data("\"type\":\"assistant\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               (obj["type"] as? String) == "assistant" { return obj }
        }
        return nil
    }
}

/// Asks macOS not to sleep for a short while, on battery too, and lets go when released or when time runs out.
/// Two assertions: idle-sleep prevention for a normal wake, and "network client active", which is what keeps a
/// background (dark) wake from dropping back to sleep while a request is in flight.
final class AwakeHold {
    private(set) var ids: [IOPMAssertionID] = []
    private let lock = NSLock()

    init(reason: String, seconds: TimeInterval) {
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, "NetworkClientActive"] {
            let props: [String: Any] = [
                kIOPMAssertionTypeKey: type,
                kIOPMAssertionNameKey: reason,
                kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
                // macOS lets go by itself after this, so a run that never ends can't keep the Mac awake.
                kIOPMAssertionTimeoutKey: seconds,
                kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
            ]
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess { ids.append(id) }
        }
    }

    /// Safe to call more than once.
    func release() {
        lock.lock(); defer { lock.unlock() }
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
    }

    deinit { release() }
}
