import Foundation

/// Why Claude's numbers are a guess, so an estimate never looks as sure as a live reading. Shared by the app
/// (menu, dashboard), the widgets and the MCP server, which all show the same short reason.
enum UsageAccuracy {
    /// nil when the numbers are solid: live usage, or an exact reset with a known usage reading. Otherwise a
    /// few words on why not, in the order a user would want to fix them.
    static func reason(isEstimate: Bool, usageKnown: Bool, liveEnabled: Bool, liveWorking: Bool, needsSignIn: Bool,
                       expired: Bool = false) -> String? {
        guard isEstimate || !usageKnown else { return nil }
        if !liveEnabled { return "live usage off" }
        if needsSignIn { return "Claude Code signed out" }
        // Claude Code renews its own sign-in when it next runs; nothing to sign in to.
        if expired { return "live again once Claude Code runs in Terminal" }
        if !liveWorking { return "live usage unavailable" }
        // Live usage is on and fine but hasn't answered yet (just switched on, or the first poll after launch).
        return "waiting for live usage"
    }

    /// For a Claude account other than the terminal's: live usage reads only the terminal's sign-in, so this one's
    /// window comes from its sessions and the desktop app's log. Without this, an agent on that account was told
    /// to "see estimate_note" and found none.
    /// With the desktop app's accounts switched on, an account still left out isn't signed in there.
    static func otherAccountNote(isEstimate: Bool, usageKnown: Bool, desktopOn: Bool = false) -> String? {
        guard isEstimate || !usageKnown else { return nil }
        let why = desktopOn ? "not signed in to the Claude desktop app" : "live usage only reads the account Claude Code in Terminal is signed in to"
        return (isEstimate ? "estimated" : "usage unknown") + " · " + why
    }

    /// For an account read live through the desktop app: nil once a live reading is on it; before that (just
    /// switched on, or the last reading too old to use) or while it fails, why it's still a guess. An estimate
    /// without a note sent agents looking for an estimate_note that wasn't there.
    static func desktopAccountNote(isEstimate: Bool, usageKnown: Bool, problem: String?) -> String? {
        guard isEstimate || !usageKnown else { return nil }
        return (isEstimate ? "estimated" : "usage unknown") + " · " + (problem ?? "waiting for live usage through the Claude desktop app")
    }

    /// The line to show: "estimated · live usage off" when the window itself is guessed from activity, or
    /// "usage unknown · …" when the reset is exact (from a limit message) but there's no usage reading.
    static func note(isEstimate: Bool, usageKnown: Bool, liveEnabled: Bool, liveWorking: Bool, needsSignIn: Bool,
                     expired: Bool = false) -> String? {
        guard let why = reason(isEstimate: isEstimate, usageKnown: usageKnown, liveEnabled: liveEnabled,
                               liveWorking: liveWorking, needsSignIn: needsSignIn, expired: expired) else { return nil }
        return (isEstimate ? "estimated" : "usage unknown") + " · " + why
    }
}
