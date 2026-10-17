import Foundation

/// A pacing budget an agent sets through the MCP server: "spend at most this much of the window on this task".
/// Saved to ~/Library/Application Support/Reset/budget.json next to widget.json. The MCP server writes it,
/// the app only reads it (and removes it when you press clear on the dashboard). It never leaves the Mac.
///
/// The cap is absolute: `maxPercent` is the window's used percentage at which the task should stop or
/// downshift, not a share counted from when the budget was set. That needs no baseline, so a window reset
/// in the middle of a task simply drops usage back under the cap.
struct Budget: Codable, Equatable {
    var task: String
    var maxPercent: Int
    var downshiftModel: String?
    var setAt: Date
    /// The account of the agent that set it (see MCPServer.Environment.org), so it's judged on that account's
    /// window; nil for budgets set from a plain terminal, or before accounts were told apart: the terminal's.
    var org: String? = nil

    static let fileName = "budget.json"
    static var url: URL { WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent(fileName) }

    static func load(from url: URL = Budget.url) -> Budget? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Budget.self, from: d)
    }

    /// Atomic, so the app never reads a half-written file while the MCP server is saving.
    func save(to url: URL = Budget.url) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let d = try enc.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }

    static func clear(at url: URL = Budget.url) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Validation

    /// Builds a budget from raw tool arguments, or says what is wrong with them. The input schema already
    /// states the limits, but clients don't all enforce schemas, so the server checks again.
    static func from(arguments a: [String: Any], now: Date) -> (budget: Budget?, error: String?) {
        guard let rawTask = a["task"] as? String, !rawTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, "task must be a non-empty string")
        }
        guard let n = a["max_window_percent"] as? NSNumber,
              // JSONSerialization turns true into a number that bridges to 1, so booleans are rejected by type.
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              // 50.5 doesn't bridge to Int, so only whole numbers get through; 50.0 is accepted as 50.
              let cap = n as? Int, (1...100).contains(cap) else {
            return (nil, "max_window_percent must be a whole number from 1 to 100")
        }
        var model: String?
        if let m = a["downshift_model"], !(m is NSNull) {
            guard let s = m as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                return (nil, "downshift_model must be a model name, for example haiku")
            }
            model = s.trimmingCharacters(in: .whitespaces)
        }
        return (Budget(task: rawTask.trimmingCharacters(in: .whitespacesAndNewlines), maxPercent: cap,
                       downshiftModel: model, setAt: now), nil)
    }

    // MARK: Status

    enum Status: String {
        case normal
        /// From 80% of the cap: finish what's in progress, start nothing new.
        case wrapUp = "wrap_up"
        /// At or past the cap: switch to the downshift model, or stop and check in.
        case over
        /// Window usage isn't known (live usage off and no recent reading), so the cap can't be checked.
        case unknown
    }

    static let wrapUpFraction = 0.8

    /// One evaluation shared by the MCP server and the dashboard, so both always agree.
    func status(used: Double?) -> Status {
        guard let used else { return .unknown }
        if used >= Double(maxPercent) { return .over }
        if used >= Double(maxPercent) * Self.wrapUpFraction { return .wrapUp }
        return .normal
    }

    /// Short form for the terminal status line: "budget 60%", "budget 60% wrap up", "budget 60% over, use haiku".
    /// Leaves out the task name, which can be long and is already on the dashboard.
    func tag(used: Double?) -> String {
        let cap = "budget \(maxPercent)%"
        switch status(used: used) {
        case .normal: return cap
        case .wrapUp: return cap + " wrap up"
        case .over: return cap + (downshiftModel.map { " over, use \($0)" } ?? " over, stop")
        case .unknown: return cap + " (usage unknown)"
        }
    }

    func advice(used: Double?) -> String {
        let task = "\u{201C}\(self.task)\u{201D}"
        let pace = used.map { "\(Int($0.rounded()))% of the window used, cap \(maxPercent)%" } ?? ""
        switch status(used: used) {
        case .unknown:
            return "Reset can't see how much of the window is used, so the budget for \(task) can't be checked. Turn on live Claude usage in Reset."
        case .normal:
            return "Within budget for \(task): \(pace)."
        case .wrapUp:
            return "Nearing the budget for \(task) (\(pace)). Wrap up: finish the current step and don't start new subtasks."
        case .over:
            if let m = downshiftModel {
                // Claude can't change its own model mid-session, so "switch to haiku" left it guessing. Say both
                // ways: subagents on that model (they start cold, so brief them fully), or the user's /model,
                // which keeps the conversation.
                return "Over the budget for \(task) (\(pace)). Do the rest of this task on \(m): give remaining steps to \(m) subagents with a complete brief (they don't see this conversation), or ask the user to run /model \(m) to continue here with full context."
            }
            return "Over the budget for \(task) (\(pace)). Stop at the next safe point and check in with the user before continuing."
        }
    }
}
