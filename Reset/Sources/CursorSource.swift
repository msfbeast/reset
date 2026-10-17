import Foundation
import SQLite3

/// Cursor's included usage for the current billing month, read live from Cursor's servers with the sign-in the
/// Cursor app keeps on this Mac. Off until you switch Cursor on in Settings: unlike the other tools its numbers
/// aren't on disk, so switching it on is what sends that sign-in to api2.cursor.sh. Reset never stores, refreshes
/// or rewrites the sign-in; the Cursor app renews it (it lasts about two months).
struct CursorSource: WindowSource {
    let id = "cursor"
    /// Off, it only says what switching it on does, and reads nothing.
    var enabled = true

    /// A month's usage moves slowly; every 5 minutes is plenty, and a failed fetch is tried again after a minute.
    static let interval: TimeInterval = 300, retryInterval: TimeInterval = 60

    func read(now: Date) -> WindowStatus {
        var status = WindowStatus(id: id, name: "Cursor", state: .unavailable("Off"), usedPercent: nil, isEstimate: false,
                                  source: "Switch on to read this month's usage from Cursor, with the Cursor app's sign-in",
                                  secondary: nil, canAutoStart: false)
        guard enabled else { return status }
        switch Self.current(now: now) {
        case nil:
            status.state = .unavailable("Reading Cursor's usage…")
            status.source = "Reading Cursor's usage…"
        case .success(let r)?:
            status.source = "Live from your Cursor account" + (Self.planLabel(r.plan).map { " · \($0)" } ?? "")
            if let end = r.resetsAt, end <= now {
                // Last month's percentage says nothing about the new one, and a reset time in the past would keep
                // the app rescanning; the next fetch is due within a minute.
                status.state = .unavailable("Cursor's new month is starting")
            } else {
                status.state = r.resetsAt.map { .active(resetsAt: $0) } ?? .unavailable("Cursor didn't say when the month resets")
                status.usedPercent = r.percent
                status.usageAsOf = now.timeIntervalSince(r.fetchedAt) > 2 * Self.interval ? r.fetchedAt : nil
            }
        case .failure(let problem)?:
            status.state = .unavailable(problem.message)
            status.source = problem.message
        }
        return status
    }

    // MARK: Fetching, in the background, at most every `interval`

    struct Reading: Equatable {
        var percent: Double
        var resetsAt: Date?
        var plan: String?
        var fetchedAt: Date
    }

    struct Problem: Error, Equatable { var message: String }

    /// Called on the main queue when a fetch finishes, so the app rescans with the new reading.
    static var onUpdate: (() -> Void)?

    private static let lock = NSLock()
    private static var last: (attempt: Date, result: Result<Reading, Problem>)?
    private static var lastGood: Reading?
    private static var fetching = false

    /// The latest reading (nil before the first), starting a fetch in the background once one is due. Never waits
    /// for the network, so a slow connection can't hold up the scan that every other tool's countdown waits on.
    static func current(now: Date) -> Result<Reading, Problem>? {
        lock.lock(); defer { lock.unlock() }
        let previous = last
        let result = previous.map { shown($0.result, lastGood: lastGood, now: now) }
        guard !fetching, isDue(previous, now: now) else { return result }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            fetch(now: now) { result in
                lock.lock()
                if case .success(let r) = result { lastGood = r }
                last = (now, result)
                fetching = false
                lock.unlock()
                DispatchQueue.main.async { onUpdate?() }
            }
        }
        return result
    }

    /// A blip shows the last good reading for up to 15 minutes instead of blanking the entry. The failure itself is
    /// kept as the last attempt, so the next try is a minute later rather than five.
    static func shown(_ result: Result<Reading, Problem>, lastGood: Reading?, now: Date) -> Result<Reading, Problem> {
        if case .failure = result, let good = lastGood, now.timeIntervalSince(good.fetchedAt) < 15 * 60 { return .success(good) }
        return result
    }

    /// A failure, or a month that has ended, is asked again after a minute; a good reading after five.
    static func isDue(_ previous: (attempt: Date, result: Result<Reading, Problem>)?, now: Date) -> Bool {
        guard let previous else { return true }
        let reading = try? previous.result.get()
        let soon = reading == nil || reading?.resetsAt.map { $0 <= now } == true
        return now.timeIntervalSince(previous.attempt) >= (soon ? retryInterval : interval)
    }

    private static func fetch(now: Date, done: @escaping (Result<Reading, Problem>) -> Void) {
        guard let auth = readSignIn() else { return done(.failure(Problem(message: "Sign in to the Cursor app to read its usage"))) }
        if let exp = expiry(of: auth.token), exp < now {
            return done(.failure(Problem(message: "Cursor's sign-in has expired. Opening Cursor renews it")))
        }
        var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
                             timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err { return done(.failure(Problem(message: "Couldn't reach Cursor: \(err.localizedDescription)"))) }
            if code == 401 || code == 403 {
                return done(.failure(Problem(message: "Cursor didn't accept the sign-in (HTTP \(code)). Opening Cursor renews it")))
            }
            guard code == 200, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return done(.failure(Problem(message: "Unexpected reply from Cursor (HTTP \(code))")))
            }
            guard var r = reading(from: obj, at: Date()) else {
                return done(.failure(Problem(message: "Cursor didn't report usage for this plan")))
            }
            r.plan = auth.plan
            done(.success(r))
        }.resume()
    }

    /// GetCurrentPeriodUsage's reply: `planUsage.totalPercentUsed` (else spend over the included amount, both in
    /// cents) and `billingCycleEnd` in milliseconds. Numbers can arrive as strings, as protobuf's JSON writes them.
    static func reading(from obj: [String: Any], at: Date) -> Reading? {
        guard let plan = obj["planUsage"] as? [String: Any] else { return nil }
        var percent = number(plan["totalPercentUsed"])
        if percent == nil, let limit = number(plan["limit"]), limit > 0 {
            let spent = number(plan["totalSpend"]) ?? number(plan["remaining"]).map { limit - $0 }
            percent = spent.map { $0 / limit * 100 }
        }
        guard let percent, percent.isFinite else { return nil }
        let end = number(obj["billingCycleEnd"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Reading(percent: min(max(percent, 0), 100), resetsAt: end, plan: nil, fetchedAt: at)
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// "pro" → "Pro", the way Claude's plans are named.
    static func planLabel(_ plan: String?) -> String? {
        guard let p = plan?.trimmingCharacters(in: .whitespaces), !p.isEmpty, p != "free" else { return nil }
        return p.prefix(1).uppercased() + p.dropFirst()
    }

    // MARK: The Cursor app's sign-in

    static var stateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// The access token and plan from Cursor's settings database, opened read-only.
    static func readSignIn(db url: URL = stateDB) -> (token: String, plan: String?)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        func value(_ key: String) -> String? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
            let s = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        guard let token = value("cursorAuth/accessToken") else { return nil }
        return (token, value("cursorAuth/stripeMembershipType"))
    }

    /// The `exp` claim of a JWT, without checking its signature (Cursor's servers do that).
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = number(claims["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
