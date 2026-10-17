import Foundation

/// The Claude Code command-line tool: whether it is signed in, and signing it in. Live usage and auto-start
/// both depend on it, and the desktop app has its own separate login, so it can be signed out without anyone noticing.
enum ClaudeCLI {
    static var path: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Status { var installed: Bool; var signedIn: Bool; var plan: String? }

    /// `claude auth status` prints JSON with `loggedIn` and `subscriptionType`. Only those two fields are read.
    static func status(completion: @escaping (Status) -> Void) {
        guard let path else { completion(Status(installed: false, signedIn: false, plan: nil)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "status"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var result = Status(installed: true, signedIn: false, plan: nil)
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result.signedIn = (obj["loggedIn"] as? Bool) ?? false
                    result.plan = obj["subscriptionType"] as? String
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The account the CLI is signed in to: its organization and plan ("team", "pro", "max"…). Live usage,
    /// auto-start and budgets all go through the CLI, so this decides which account is the main "Claude" entry.
    struct Account: Equatable { var orgId: String; var plan: String? }

    private static var cachedAccount: (at: Date, value: Account?)?
    private static let accountLock = NSLock()

    /// Blocking, so call it off the main thread. Cached for 10 minutes: spawning the CLI isn't free, and the
    /// signed-in account rarely changes. Reads only `orgId` and `subscriptionType` from `claude auth status`.
    static func account(now: Date = Date()) -> Account? {
        accountLock.lock()
        if let c = cachedAccount, now.timeIntervalSince(c.at) < 600 { accountLock.unlock(); return c.value }
        accountLock.unlock()
        var found: Account?
        if let path {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "status"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            if (try? p.run()) != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timeout.cancel()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (obj["loggedIn"] as? Bool) == true, let org = obj["orgId"] as? String, !org.isEmpty {
                    let config = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    found = Account(orgId: org, plan: configPlan(org: org, config: config) ?? obj["subscriptionType"] as? String)
                }
            }
        }
        accountLock.lock(); cachedAccount = (now, found); accountLock.unlock()
        return found
    }

    /// The terminal's account: whose the Keychain sign-in is, when live usage has asked Anthropic (see
    /// LiveClaude.TokenAccount), else what `claude auth status` said. The status's orgId follows ~/.claude.json,
    /// which the desktop app rewrites when you switch accounts there, so it's only the fallback.
    static func resolve(signIn: LiveClaude.TokenAccount?, status: Account?) -> Account? {
        signIn.map { Account(orgId: $0.org, plan: $0.plan) } ?? status
    }

    /// The plan for `org` from ~/.claude.json, where `claude auth status` gets its orgId. Its own plan comes from
    /// the Keychain, which after switching accounts in the desktop app is still the other account's.
    static func configPlan(org: String, config: [String: Any]?) -> String? {
        guard let a = config?["oauthAccount"] as? [String: Any], a["organizationUuid"] as? String == org,
              let type = a["organizationType"] as? String else { return nil }
        return type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
    }

    /// The account in ~/.claude.json, which both the desktop app and `claude auth login` rewrite on a switch.
    static func configOrg() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = obj["oauthAccount"] as? [String: Any], let org = a["organizationUuid"] as? String, !org.isEmpty else { return nil }
        return org
    }

    static func forgetAccount() {
        accountLock.lock(); cachedAccount = nil; accountLock.unlock()
    }

    /// Runs `claude auth login`, which opens the browser and finishes once the user approves there.
    static func signIn(completion: @escaping (Bool) -> Void) {
        guard let path else { completion(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "login"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            timeout.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

/// Which AI tools this Mac has, from their usual folders and apps.
enum InstalledTools {
    static func detect() -> Set<String> {
        let home = NSHomeDirectory(), fm = FileManager.default
        var out: Set<String> = []
        if fm.fileExists(atPath: "\(home)/.claude") || ClaudeCLI.path != nil { out.insert("claude") }
        if fm.fileExists(atPath: "\(home)/.codex/sessions") { out.insert("codex") }
        if fm.fileExists(atPath: "\(home)/.gemini") { out.insert("gemini") }
        if fm.fileExists(atPath: "/Applications/Antigravity.app") { out.insert("antigravity") }
        return out
    }
}
