import Foundation
import UserNotifications

/// Mac notifications are scheduled with the system, so they fire on time even if Reset is busy.
/// Phone alerts go through ntfy with a server-side delivery time ("At" header), so they still
/// arrive when the Mac is asleep or the lid is closed.
final class Alerts {
    private let center = UNUserNotificationCenter.current()
    /// v2 ids carry calendar triggers. Older "reset-" requests used interval triggers and are cleared out.
    private let prefix = "reset2-"
    private let legacyPrefix = "reset-"

    /// Buttons on notifications; AppDelegate acts on them. Without them a "signed out" alert asked you to go and
    /// find a button, and a click on any banner opened nothing (Reset has no Dock icon).
    enum Action { static let signIn = "reset.signin", start = "reset.start" }
    enum Category { static let signIn = "reset.cat.signin", start = "reset.cat.start" }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.signIn,
                                   actions: [UNNotificationAction(identifier: Action.signIn, title: "Sign in", options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.start,
                                   actions: [UNNotificationAction(identifier: Action.start, title: "Start now", options: [])],
                                   intentIdentifiers: []),
        ])
    }

    /// Minute precision, so a reset time that wobbles by a second keeps the same identity.
    static func minuteKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 60).rounded()) }

    /// `autoStarting`: ids auto-start will start at the reset. `startable`: ids Reset can start on request.
    func sync(_ windows: [WindowStatus], leadMinutes: Int, autoStarting: Set<String> = [], startable: Set<String> = []) {
        let now = Date()
        var wanted: [String: UNNotificationRequest] = [:]
        for w in windows {
            guard let at = w.resetsAt, at > now else { continue }
            let auto = autoStarting.contains(w.id)
            // The auto-start mark is part of the id, so switching auto-start replaces the queued wording.
            let id = "\(prefix)\(w.id)-\(Self.minuteKey(at))\(auto ? "-auto" : "")"
            // "Send a message to start it" was wrong when auto-start was about to do exactly that.
            let body = w.blockedUntil.map { "Session window is fresh, but the \(w.secondary?.label.lowercased() ?? "longer") limit lasts until \(Fmt.when($0))." }
                ?? (w.id == "cursor" ? "A new month of usage has started." // a billing month, not a window to start
                    : auto ? "A fresh window is ready. Auto-start will open it in a couple of minutes."
                    : "A fresh window is ready. Send a message to start it.")
            let canStart = !auto && w.blockedUntil == nil && startable.contains(w.id)
            wanted[id] = request(id: id, title: "\(w.name) has reset", body: body, at: at,
                                 category: canStart ? Category.start : nil, provider: w.id)
            if leadMinutes > 0 {
                let early = at.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                if early > now {
                    let lid = "\(id)-lead\(leadMinutes)"
                    wanted[lid] = request(id: lid, title: "\(w.name) resets in \(leadMinutes) min",
                                          body: "At \(Fmt.clock.string(from: at)).", at: early)
                }
            }
        }
        center.getPendingNotificationRequests { [center, prefix, legacyPrefix] pending in
            let legacy = pending.map(\.identifier).filter { $0.hasPrefix(legacyPrefix) }
            if !legacy.isEmpty { center.removePendingNotificationRequests(withIdentifiers: legacy) }
            let have = Set(pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            let stale = have.subtracting(wanted.keys)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            for (id, req) in wanted where !have.contains(id) { center.add(req) }
        }
    }

    private func request(id: String, title: String, body: String, at: Date, category: String? = nil,
                         provider: String? = nil) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let category { c.categoryIdentifier = category }
        if let provider { c.userInfo = ["id": provider] }
        // A calendar trigger fires at the wall-clock time, including after the Mac wakes from sleep.
        // An interval trigger counts elapsed time, which drifts across sleep and reports the wrong time.
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        comps.timeZone = TimeZone.current
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: c, trigger: trigger)
    }

    /// `id` keeps a repeat of the same alert (say, a second auto-start failure) replacing the first instead of stacking.
    func notifyNow(title: String, body: String, id: String? = nil, category: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        if let category { c.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: prefix + (id ?? "forecast-\(Int(Date().timeIntervalSince1970))"), content: c,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    func pushNow(title: String, body: String, server: String, topic: String, log: @escaping (String) -> Void) {
        guard let url = Self.endpoint(server: server, topic: topic) else { return }
        post(url: url, sid: nil, title: title, body: body, at: nil, priority: 4, log: log) { _ in }
    }

    // MARK: Phone (ntfy)

    /// What is queued on the ntfy server, per provider. Each provider uses one ntfy sequence ID, so
    /// posting again replaces the pending push and DELETE withdraws it.
    private struct Queued: Codable { var destination: String; var minute: Int; var at: Date }
    private var queued: [String: Queued] = {
        UserDefaults.standard.data(forKey: "ntfyQueued").flatMap { try? JSONDecoder().decode([String: Queued].self, from: $0) } ?? [:]
    }()
    private var inFlight: Set<String> = []

    /// For the self-test: what's queued on ntfy, per provider.
    var queuedSummary: [String: String] { queued.mapValues { "\(Fmt.when($0.at)) to \($0.destination.split(separator: "/").last ?? "")" } }

    private func saveQueued() {
        UserDefaults.standard.set(try? JSONEncoder().encode(queued), forKey: "ntfyQueued")
    }

    static func endpoint(server: String, topic: String) -> URL? {
        let base = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              base.hasPrefix("https://") || base.hasPrefix("http://") else { return nil }
        return URL(string: "\(base)/\(t)")
    }

    /// Main-thread only. `windows` are the providers that should alert; anything queued for a provider
    /// no longer in that list (or whose time moved) is replaced or withdrawn.
    func syncPhone(_ windows: [WindowStatus], server: String, topic: String, enabled: Bool,
                   log: @escaping (String) -> Void) {
        let now = Date()
        let dest = Self.endpoint(server: server, topic: topic)
        var want: [String: Date] = [:]
        if enabled, dest != nil {
            for w in windows {
                // ntfy accepts delivery times between 10 s and 3 days out.
                if let at = w.resetsAt, at.timeIntervalSince(now) > 15, at.timeIntervalSince(now) < 3 * 86400 {
                    want[w.id] = at
                }
            }
        }
        // Withdraw pushes that should no longer go out.
        for (id, q) in queued where want[id] == nil || q.destination != dest?.absoluteString {
            guard !inFlight.contains(id) else { continue }
            queued[id] = nil
            if q.at > now, let url = URL(string: q.destination) { delete(url: url, sid: Self.sid(id), log: log) }
        }
        saveQueued()
        guard let dest else { return }
        for w in windows {
            guard let at = want[w.id], !inFlight.contains(w.id) else { continue }
            let minute = Self.minuteKey(at)
            if let q = queued[w.id], q.minute == minute, q.destination == dest.absoluteString { continue }
            inFlight.insert(w.id)
            let id = w.id
            post(url: dest, sid: Self.sid(id), title: "\(w.name) has reset",
                 body: (id == "cursor" ? "New month of usage since " : "Fresh window ready since ") + "\(Fmt.clock.string(from: at)).",
                 at: at, priority: 4, log: log) { [weak self] ok in
                guard let self else { return }
                self.inFlight.remove(id)
                guard ok else { return }  // not recorded, so the next rescan retries
                self.queued[id] = Queued(destination: dest.absoluteString, minute: minute, at: at)
                self.saveQueued()
            }
        }
    }

    static func sid(_ providerId: String) -> String { "reset-\(providerId)" }

    /// `result` gets a short outcome for beside the button ("Sent ✓", "Failed: HTTP 403"); it used to reach only
    /// the Activity log, so a press seemed to do nothing either way.
    func sendTest(server: String, topic: String, log: @escaping (String) -> Void, result: @escaping (String) -> Void = { _ in }) {
        guard let url = Self.endpoint(server: server, topic: topic) else {
            log("Phone test not sent: topic must be letters, numbers, - or _")
            result("Not sent: check the topic")
            return
        }
        post(url: url, sid: nil, title: "Reset test", body: "Phone alerts are working.", at: nil, priority: 3, log: { line in
            log(line)
            result(Self.testOutcome(line))
        }) { _ in }
    }

    /// The log line, cut down to what fits beside the button. A test isn't retried, so "Will retry" goes.
    static func testOutcome(_ line: String) -> String {
        if line.hasPrefix("Phone test sent") { return "Sent ✓" }
        return line.replacingOccurrences(of: "Phone push failed: ", with: "Failed: ").replacingOccurrences(of: ". Will retry", with: "")
    }

    private func post(url: URL, sid: String?, title: String, body: String, at: Date?, priority: Int,
                      log: @escaping (String) -> Void, done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("hourglass", forHTTPHeaderField: "Tags")
        req.setValue(String(priority), forHTTPHeaderField: "Priority")
        if let sid { req.setValue(sid, forHTTPHeaderField: "X-Sequence-ID") }
        if let at { req.setValue(String(Int(at.timeIntervalSince1970)), forHTTPHeaderField: "At") }
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = err == nil && (200..<300).contains(code)
            DispatchQueue.main.async {
                if let err { log("Phone push failed: \(err.localizedDescription). Will retry") }
                else if !ok { log("Phone push failed: HTTP \(code). Will retry") }
                else { log(at.map { "Phone push queued for \(Fmt.when($0))" } ?? "Phone test sent") }
                done(ok)
            }
        }.resume()
    }

    private func delete(url: URL, sid: String, log: @escaping (String) -> Void) {
        var req = URLRequest(url: url.appendingPathComponent(sid), timeoutInterval: 20)
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                log(err == nil && (200..<300).contains(code) ? "Withdrew a queued phone push" : "Could not withdraw a queued phone push (HTTP \(code))")
            }
        }.resume()
    }
}
