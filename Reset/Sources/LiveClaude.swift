import CryptoKit
import Foundation

/// Opt-in exact Claude usage: reads Claude Code's own sign-in from the Keychain and asks Anthropic's usage
/// endpoint for the current 5-hour and weekly windows. Only usage numbers are fetched, the token is only
/// ever sent to api.anthropic.com, and Reset never refreshes or rewrites it (that would sign Claude Code out).
/// One more copy per other account signed in to the Claude desktop app does the same with that app's sign-in.
final class LiveClaude {
    struct Window: Codable, Equatable { var percent: Double; var resetsAt: Date? }
    /// `org` is the account the reading is for (see `TokenAccount`); nil in readings saved before it was asked.
    struct Snapshot: Codable, Equatable { var fiveHour: Window?; var sevenDay: Window?; var fetchedAt: Date; var org: String? = nil }

    /// Which account the Keychain sign-in belongs to, asked of Anthropic once per sign-in. That's the account the
    /// terminal's Claude Code runs on, and so the live numbers, auto-start and budgets. `claude auth status` can't
    /// say: its orgId comes from ~/.claude.json, which the Claude desktop app rewrites when you switch accounts
    /// there, while its plan comes from the Keychain, so after a switch it named one account with the other's plan.
    /// Only a hash of the token is kept, to know when the sign-in changed.
    struct TokenAccount: Codable, Equatable { var tokenHash: String; var org: String; var plan: String? }

    /// Whose sign-in this copy reads.
    enum Source: Equatable {
        case claudeCode
        /// The Claude desktop app's token for this organization (see ClaudeDesktopSignIn).
        case desktop(org: String)
    }

    /// When Reset last asked, until when Anthropic told it to wait, and the last good reading. Saved to
    /// live-schedule.json and re-read before every fetch, so a restart (or a second copy of the app) respects a
    /// "slow down" instead of asking again straight away, and shows the last reading instead of an estimate.
    struct Schedule: Codable, Equatable {
        var lastAttempt: Date = .distantPast
        var backoffUntil: Date = .distantPast
        var lastGood: Snapshot?
        /// Every "slow down" (HTTP 429) received, newest last, to learn where Anthropic's undocumented limit sits.
        /// Optional so schedules saved before it existed still load.
        var limits: [LimitHit]? = nil
        /// Optional so schedules saved before it existed still load.
        var account: TokenAccount? = nil
    }

    /// One "slow down": when, and how long Anthropic asked Reset to wait (its Retry-After header), if it said.
    struct LimitHit: Codable, Equatable {
        var at: Date
        var retryAfter: Double?
    }

    /// Only the most recent hits are kept; enough to see a pattern over a few days.
    static let keptLimitHits = 50

    /// The saved "slow down" log, for the self-test.
    var limitHits: [LimitHit] { Self.loadSchedule(scheduleURL)?.limits ?? [] }

    /// A reading older than this says nothing about the current window; matches what `apply` accepts.
    static let freshFor: TimeInterval = 15 * 60

    static var scheduleURL: URL { WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("live-schedule.json") }

    /// A desktop-app account's own schedule, so one account's "slow down" doesn't hold back the others.
    static func scheduleURL(org: String) -> URL {
        scheduleURL.deletingLastPathComponent().appendingPathComponent("live-schedule-\(org.prefix(8)).json")
    }

    static func loadSchedule(_ url: URL?) -> Schedule? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Schedule.self, from: d)
    }

    static func saveSchedule(_ s: Schedule, to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Whether a fetch is due: the interval has passed since the last attempt, and any back-off is over.
    /// Never while one is still running: a Keychain prompt nobody answers, or a slow network, used to let every
    /// later poll start another fetch beside it.
    static func shouldFetch(now: Date, lastAttempt: Date, backoffUntil: Date, interval: TimeInterval, inFlight: Bool = false) -> Bool {
        !inFlight && now.timeIntervalSince(lastAttempt) >= interval && now >= backoffUntil
    }

    enum State: Equatable {
        case off, loading
        case ok(Date)
        case problem(String)
    }

    private(set) var snapshot: Snapshot?
    /// The account the sign-in belongs to, once known; kept on disk so the first scan after a launch has it.
    private(set) var tokenAccount: TokenAccount?
    private(set) var state: State = .off
    /// True when the failure is about Claude Code's sign-in, which the user has to fix (not a network blip).
    private(set) var needsSignIn = false
    /// Claude Code's sign-in lasts about 8 hours and renews itself the next time Claude Code runs. With most work in
    /// the desktop app, the terminal's lapses every day; that's a pause, not a reason to sign in again.
    private(set) var signInExpired = false

    static let expiredMessage = "Claude Code's sign-in has expired; it renews the next time you use Claude Code in Terminal"

    /// Whether a problem needs the user to sign in: no sign-in at all, or Anthropic refusing it. An expired one doesn't.
    static func needsSignIn(_ problem: String) -> Bool {
        let w = problem.lowercased()
        if w.contains("has expired") { return false }
        return w.contains("sign-in") || w.contains("signed in") || w.contains("didn't accept")
    }
    /// When the live check started failing, cleared by the next good answer. Agents pacing on the last reading
    /// need to know it's getting old (see the MCP server's usage_as_of).
    private(set) var failingSince: Date?
    private var lastAttempt = Date.distantPast
    private var backoffUntil = Date.distantPast
    /// A fetch has started and not finished (see `shouldFetch`).
    private var inFlight = false
    private let lock = NSLock()
    private let scheduleURL: URL?
    let source: Source

    /// With no `scheduleURL` nothing is read or written (tests).
    init(scheduleURL: URL? = nil, now: Date = Date(), source: Source = .claudeCode) {
        self.scheduleURL = scheduleURL
        self.source = source
        guard let saved = Self.loadSchedule(scheduleURL) else { return }
        tokenAccount = saved.account
        lastAttempt = saved.lastAttempt
        backoffUntil = saved.backoffUntil
        if let good = saved.lastGood, now.timeIntervalSince(good.fetchedAt) < Self.freshFor {
            snapshot = good
            state = .ok(good.fetchedAt)
        }
    }

    /// Saves the schedule, keeping whatever is latest on disk (another copy of the app may have asked since).
    private func persist(_ update: (inout Schedule) -> Void) {
        guard scheduleURL != nil else { return }
        var s = Self.loadSchedule(scheduleURL) ?? Schedule()
        update(&s)
        Self.saveSchedule(s, to: scheduleURL)
    }

    /// How often to ask: every 2 minutes while Claude Code is in use, when the numbers move and you're watching
    /// them, and every 5 minutes otherwise. Once a minute drew Anthropic's first "slow down" within 40 minutes
    /// (alongside a lot of restarts), and the endpoint isn't a public API with a published limit, so 2 minutes it
    /// is until the 429 log says more is safe. Just under 120 s, because the app's refresh runs every 60 s and a
    /// strict 120 would sometimes miss a tick and wait three.
    static let activeInterval: TimeInterval = 115, idleInterval: TimeInterval = 300
    static let activeWindow: TimeInterval = 5 * 60

    static func interval(lastActivity: Date?, now: Date = Date()) -> TimeInterval {
        guard let a = lastActivity, now.timeIntervalSince(a) < activeWindow else { return idleInterval }
        return activeInterval
    }

    /// Fetch if the last one is older than `interval`. Calls `done` on the main queue when something changed.
    func poll(interval: TimeInterval = 180, done: @escaping () -> Void) {
        lock.lock()
        let now = Date()
        // Whatever another copy (or this one before a restart) recorded counts too.
        if let disk = Self.loadSchedule(scheduleURL) {
            lastAttempt = max(lastAttempt, disk.lastAttempt)
            backoffUntil = max(backoffUntil, disk.backoffUntil)
        }
        guard Self.shouldFetch(now: now, lastAttempt: lastAttempt, backoffUntil: backoffUntil, interval: interval, inFlight: inFlight)
        else { lock.unlock(); return }
        lastAttempt = now
        inFlight = true
        lock.unlock()
        persist { $0.lastAttempt = now }
        if snapshot == nil { state = .loading }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Test hook: `-simulateSignedOut YES` behaves as if Claude Code's sign-in expired.
            if self.source == .claudeCode, UserDefaults.standard.bool(forKey: "simulateSignedOut") {
                self.finish(.problem("Claude Code isn't signed in on this Mac, or Keychain access was denied"), done)
                return
            }
            let token: Token?
            switch self.source {
            case .claudeCode: token = Self.readToken()
            case .desktop(let org): token = ClaudeDesktopSignIn.token(org: org)
            }
            guard let token else {
                self.finish(.problem(self.source == .claudeCode ? "Claude Code isn't signed in on this Mac, or Keychain access was denied"
                                     : "The Claude desktop app's sign-in for this account has expired. Opening the desktop app renews it"), done)
                return
            }
            if let exp = token.expiresAt, exp < Date() {
                self.finish(.problem(self.source == .claudeCode ? Self.expiredMessage
                                     : "The Claude desktop app's sign-in for this account has expired. Opening the desktop app renews it"), done)
                return
            }
            // A desktop app sign-in is filed under its organization already; only Claude Code's needs asking.
            if case .desktop(let org) = self.source { self.fetchUsage(token, org: org, done); return }
            let hash = Self.hash(token.access)
            let known = Self.loadSchedule(self.scheduleURL)?.account ?? self.tokenAccount
            if let known, known.tokenHash == hash {
                self.fetchUsage(token, org: known.org, done)
            } else {
                // A new sign-in (Claude Code renews it every few hours, or you signed in to another account):
                // ask whose it is first. If that fails, the reading goes untagged, as before.
                Self.fetchAccount(token) { org, plan in
                    if let org {
                        let a = TokenAccount(tokenHash: hash, org: org, plan: plan)
                        self.persist { $0.account = a }
                        DispatchQueue.main.async { self.tokenAccount = a }
                    }
                    self.fetchUsage(token, org: org, done)
                }
            }
        }
    }

    /// Asks Anthropic's profile endpoint (same host, same sign-in, needs the user:profile scope the usage
    /// endpoint also needs) which organization the token is for, and its plan.
    private static func fetchAccount(_ token: Token, _ done: @escaping (String?, String?) -> Void) {
        let req = request("profile", token: token)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { done(nil, nil); return }
            let a = profileAccount(obj)
            done(a?.org, a?.plan)
        }.resume()
    }

    /// The organization and plan in a profile reply: "claude_team" → "team", like `claude auth status` spells plans.
    static func profileAccount(_ obj: [String: Any]) -> (org: String, plan: String?)? {
        guard let o = obj["organization"] as? [String: Any], let id = o["uuid"] as? String, !id.isEmpty else { return nil }
        let type = o["organization_type"] as? String
        return (id.lowercased(), type.map { $0.hasPrefix("claude_") ? String($0.dropFirst("claude_".count)) : $0 })
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchUsage(_ token: Token, org: String?, _ done: @escaping () -> Void) {
        let req = Self.request("usage", token: token)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err { self.finish(.problem("Couldn't reach Anthropic: \(err.localizedDescription)"), done); return }
            if code == 429 {
                let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let retry = header ?? 600
                let until = Date().addingTimeInterval(max(retry, 300))
                self.lock.lock(); self.backoffUntil = until; self.lock.unlock()
                self.persist {
                    $0.backoffUntil = until
                    $0.limits = Array((($0.limits ?? []) + [LimitHit(at: Date(), retryAfter: header)]).suffix(Self.keptLimitHits))
                }
                self.finish(.problem("Anthropic asked Reset to slow down; trying again in a few minutes"), done)
                return
            }
            if code == 401 || code == 403 {
                self.finish(.problem("Anthropic didn't accept the sign-in (HTTP \(code))"), done)
                return
            }
            guard code == 200, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finish(.problem("Unexpected reply from Anthropic (HTTP \(code))"), done)
                return
            }
            let snap = Snapshot(fiveHour: Self.window(obj["five_hour"]), sevenDay: Self.window(obj["seven_day"]), fetchedAt: Date(), org: org)
            self.persist { $0.lastGood = snap }
            // Diagnostics: the usage windows exactly as received (percentages and reset times only).
            var diag: [String: Any] = ["fetched": ISO8601DateFormatter().string(from: Date())]
            for k in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] { diag[k] = obj[k] ?? NSNull() }
            if self.source == .claudeCode, let d = try? JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("live-usage.json"))
            }
            self.lock.lock(); self.inFlight = false; self.lock.unlock()
            DispatchQueue.main.async {
                self.needsSignIn = false
                self.signInExpired = false
                self.failingSince = nil
                self.snapshot = snap
                self.state = snap.fiveHour == nil && snap.sevenDay == nil
                    ? .problem("Signed in, but Anthropic reports no usage windows for this account")
                    : .ok(snap.fetchedAt)
                done()
            }
        }.resume()
    }

    /// Whether a reading is for this entry: never one account's numbers on another's card. Readings and entries
    /// that don't say whose they are still match, as before accounts were told apart.
    static func belongs(_ snap: Snapshot, to s: WindowStatus) -> Bool {
        guard let org = snap.org, let account = s.account else { return true }
        return org == account
    }

    /// Fetch again right away, e.g. after the user signs Claude Code back in.
    func retryNow(done: @escaping () -> Void) {
        // Asked for by the user (after signing in), so it overrides the schedule, saved one included.
        lock.lock(); lastAttempt = .distantPast; backoffUntil = .distantPast; lock.unlock()
        persist { $0.lastAttempt = .distantPast; $0.backoffUntil = .distantPast }
        poll(interval: 0, done: done)
    }

    func reset() {
        needsSignIn = false
        signInExpired = false
        lock.lock(); lastAttempt = .distantPast; backoffUntil = .distantPast; lock.unlock()
        // Switched off: forget the last reading too, so switching back on never shows something stale.
        persist { $0.lastGood = nil }
        snapshot = nil
        state = .off
    }

    private func finish(_ s: State, _ done: @escaping () -> Void) {
        lock.lock(); inFlight = false; lock.unlock()
        // Read by the menu on the main thread, so it's only ever written there.
        let signIn: Bool? = { if case .problem(let why) = s { return Self.needsSignIn(why) } else { return nil } }()
        let expired: Bool = { if case .problem(let why) = s { return why.lowercased().contains("has expired") } else { return false } }()
        if case .problem(let why) = s, source == .claudeCode {
            let diag: [String: Any] = ["fetched": ISO8601DateFormatter().string(from: Date()), "problem": why]
            if let d = try? JSONSerialization.data(withJSONObject: diag, options: .prettyPrinted) {
                try? d.write(to: WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("live-usage.json"))
            }
        }
        DispatchQueue.main.async {
            if let signIn { self.needsSignIn = signIn }
            self.signInExpired = expired
            self.state = s
            if case .problem = s { self.failingSince = self.failingSince ?? Date() }
            done()
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func window(_ v: Any?) -> Window? {
        guard let d = v as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        let r = (d["resets_at"] as? String).flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) }
        return Window(percent: u, resetsAt: r.map(roundedToMinute))
    }

    /// Anthropic's reset times sit a fraction of a second either side of the minute (19:09:59.68 for 19:10), and
    /// clock formatting cuts seconds off, so some resets showed a minute early.
    static func roundedToMinute(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    struct Token { var access: String; var expiresAt: Date? }

    /// Uses /usr/bin/security, the same tool Claude Code writes the item with.
    static func readToken() -> Token? {
        // macOS can stop to ask about Keychain access; nobody answering mustn't hold a fetch open forever.
        guard let data = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 30)
        else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else { return nil }
        let exp = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(access: access, expiresAt: exp)
    }

    /// A GET to one of Anthropic's OAuth endpoints ("usage", "profile"), sent the way Claude Code sends it.
    static func request(_ endpoint: String, token: Token) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)")!, timeoutInterval: 20)
        req.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-cli/2.1 (external, cli)", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Runs a tool and returns what it printed, or nil if it failed or took longer than `timeout` (then it's stopped).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        // Stopped by the timeout, it ends on a signal rather than exiting.
        return p.terminationReason == .exit && p.terminationStatus == 0 ? data : nil
    }

    /// Overlays live numbers on the transcript-based status.
    func apply(to s: inout WindowStatus, now: Date) {
        guard let snap = snapshot, now.timeIntervalSince(snap.fetchedAt) < 15 * 60, Self.belongs(snap, to: s) else { return }
        if let fh = snap.fiveHour {
            s.usedPercent = fh.percent
            // A reading can be up to 15 minutes old (polling slows when idle or when asked to); past 3 minutes the
            // menu says how old, rather than passing it off as current.
            s.usageAsOf = now.timeIntervalSince(snap.fetchedAt) > 180 ? snap.fetchedAt : nil
            if let r = fh.resetsAt, r > now { s.state = .active(resetsAt: r) }
            else if fh.percent == 0 { s.state = .ready }
            s.isEstimate = false
            s.source = source == .claudeCode ? "Live from your Claude account" : "Live, through the Claude desktop app's sign-in"
        }
        // Live weekly data is authoritative both ways: it sets the block when the limit is used up,
        // and clears a stale one (for example from an old transcript limit row) once it isn't.
        if let sd = snap.sevenDay {
            if let r = sd.resetsAt, r > now {
                s.secondary = .init(label: "Weekly", resetsAt: r, usedPercent: sd.percent)
                s.blockedUntil = sd.percent >= 100 ? r : nil
                s.blockedEstimate = false
            } else {
                s.blockedUntil = nil
            }
        }
    }
}
