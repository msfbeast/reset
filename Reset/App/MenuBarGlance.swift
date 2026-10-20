import AppKit
import SwiftUI

/// What the menu bar says at a glance, and in which colour: an orange pill with the countdown and how much is
/// left, red when the window is nearly empty or the pace runs out before the reset, green when a fresh window is
/// waiting, and a quiet moon during a weekly limit. Pure, so the choices are tested.
struct MenuBarGlance: Equatable {
    /// Which limits to show, from Settings → Appearance. A tool without a weekly reading shows its 5-hour window.
    enum Limits: String, CaseIterable, Identifiable {
        case session, weekly, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .session: return "5-hour"
            case .weekly: return "Weekly"
            case .both: return "Both"
            }
        }
    }

    enum Tone: String {
        case normal      // orange pill
        case low         // red pill: little left
        case runningOut  // red pill: today's pace runs out before the reset
        case ready       // green pill
        case blocked     // no pill: a weekly (or longer) limit, nothing to do until it lifts
    }

    var tone: Tone
    var text: String
    /// The weekly limit, drawn under `text` when both limits are shown.
    var detail: String? = nil
    /// Claude Code is signed out, so live usage is paused; a small warning sign goes in front.
    var warning = false
    /// What VoiceOver says. The pill is an image, so without this it would be silent; spelled out in words,
    /// because "2:46 · 42%" read aloud is a riddle.
    var spoken = ""

    /// Left at or below this is "low". Matches where the menu's health bar turns red.
    static let lowPercent = 15.0

    /// Which entries the bar speaks for. The account the Claude Code CLI is signed in to ("claude") is the one in
    /// use, so while its window runs the bar follows it alone: a second account that's merely unused reads "ready"
    /// (a green "Pro ready" hid Team's 45% and its run-out warning), and its weekly limit or sooner reset says
    /// nothing about the window you're spending. Otherwise a weekly limit, then a fresh window, then the soonest reset.
    /// `main` is the account you're using (Store.activeClaudeId), which after a switch in the desktop app isn't the CLI's.
    static func pick(_ candidates: [WindowStatus], main mainId: String = "claude", now: Date)
        -> (ready: WindowStatus?, soonest: WindowStatus?, blocked: WindowStatus?) {
        if let main = candidates.first(where: { $0.id == mainId }), main.resetsAt != nil,
           (main.blockedUntil ?? .distantPast) <= now {
            return (nil, main, nil)
        }
        return (candidates.first { $0.state == .ready && $0.blockedUntil == nil },
                candidates.filter { $0.resetsAt != nil }.min { $0.resetsAt! < $1.resetsAt! },
                candidates.first { ($0.blockedUntil ?? .distantPast) > now })
    }

    static func make(ready: WindowStatus?, soonest: WindowStatus?, blocked: WindowStatus?, runsOutAt: Date?,
                     signedOut: Bool, limits: Limits = .session, now: Date) -> MenuBarGlance? {
        let g = session(ready: ready, soonest: soonest, blocked: blocked, runsOutAt: runsOutAt, signedOut: signedOut, now: now)
        // A used-up weekly limit already shows on its own, and a tool without a weekly reading keeps its 5-hour window.
        guard limits != .session, var g, g.tone != .blocked, let s = ready ?? soonest, let week = s.secondary,
              let left = weeklyLeft(s, now: now) else { return g }
        let text = "wk \(roughly(week.resetsAt.timeIntervalSince(now))) · \(Int(left.rounded()))%"
        // Red from the point the menu, status line and notification warn about the weekly limit.
        let low = week.isHigh
        let spoken = "weekly limit \(Int(left.rounded())) percent left, resets \(Fmt.when(week.resetsAt, now: now))" + (low ? ", running low" : "")
        if limits == .weekly {
            // The 5-hour window's urgent states still set the colour: green when a fresh window is waiting, red when
            // today's pace runs out first. Weekly mode used to turn those plain orange, hiding the pill's main signals.
            let keep = g.tone == .ready || g.tone == .runningOut
            let lead = (g.warning ? "Claude Code is signed out. " : "") + spokenName(s) + ": "
            return MenuBarGlance(tone: keep ? g.tone : (low ? .low : .normal), text: prefix(s) + text, warning: g.warning,
                                 spoken: keep ? g.spoken + "; " + spoken : lead + spoken)
        }
        g.detail = text
        if low, g.tone == .normal { g.tone = .low }
        g.spoken += "; " + spoken
        return g
    }

    /// "3d", "18h", "45m": a weekly reset needs no minutes, and it keeps the menu's rows narrow.
    static func roughly(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        if m >= 1440 { return "\(m / 1440)d" }
        return m >= 60 ? "\(m / 60)h" : "\(m)m"
    }

    /// Percent of the weekly limit left, when the tool reports it and it hasn't reset yet.
    static func weeklyLeft(_ s: WindowStatus, now: Date) -> Double? {
        guard let w = s.secondary, w.label.hasPrefix("Weekly"), w.resetsAt > now, let used = w.usedPercent else { return nil }
        return max(0, 100 - used)
    }

    private static func session(ready: WindowStatus?, soonest: WindowStatus?, blocked: WindowStatus?, runsOutAt: Date?,
                                signedOut: Bool, now: Date) -> MenuBarGlance? {
        // A weekly limit outranks everything: no countdown or "ready" would be true until it lifts.
        if let b = blocked, let until = b.blockedUntil, until > now {
            // A lift time worked out from history is the latest it can be, so it reads "~Fri 9:00" and "about".
            return MenuBarGlance(tone: .blocked, text: prefix(b) + (b.blockedEstimate ? "~" : "") + Fmt.when(until, now: now),
                                 spoken: "\(spokenName(b)): weekly limit used up until \(b.blockedEstimate ? "about " : "")\(Fmt.when(until, now: now))")
        }
        if let r = ready {
            return MenuBarGlance(tone: .ready, text: prefix(r) + "ready", spoken: "\(spokenName(r)): a fresh window is ready")
        }
        guard let s = soonest, let reset = s.resetsAt else { return nil }
        let countdown = prefix(s) + Fmt.short(reset.timeIntervalSince(now))
        let warn = signedOut && s.id == "claude"
        let lead = (warn ? "Claude Code is signed out. " : "") + spokenName(s) + ": "
        let until = "\(words(reset.timeIntervalSince(now))) until the reset"
        // The forecast is Claude's, and only counts when it lands before this window's reset. Then what's left and
        // when it runs out matter more than the reset countdown, and a countdown next to a clock time ("4:42 · out
        // 9:29") read as two clock times; so it's "86% · out 9:29", and the reset time is a click away in the menu.
        if s.id == "claude", let out = runsOutAt, out > now, out < reset {
            let first = s.usedPercent.map { "\(Int(max(0, 100 - $0).rounded()))%" } ?? countdown
            let left = s.usedPercent.map { "\(Int(max(0, 100 - $0).rounded())) percent left, but" } ?? "\(until), but"
            return MenuBarGlance(tone: .runningOut, text: "\(first) · out \(shortClock.string(from: out))", warning: warn,
                                 spoken: lead + "\(left) at this pace it runs out at \(Fmt.clock.string(from: out)), before the reset")
        }
        guard let used = s.usedPercent else {
            // No usage reading: the countdown alone, rather than a percentage that would really be the clock.
            return MenuBarGlance(tone: .normal, text: countdown, warning: warn, spoken: lead + until)
        }
        let left = max(0, 100 - used)
        let low = left <= lowPercent
        return MenuBarGlance(tone: low ? .low : .normal, text: "\(countdown) · \(Int(left.rounded()))%", warning: warn,
                             spoken: lead + "\(until), \(Int(left.rounded())) percent left" + (low ? ", almost empty" : ""))
    }

    /// "Claude" or "Claude Team", without the dot that VoiceOver would read as "dot".
    private static func spokenName(_ s: WindowStatus) -> String {
        s.name.replacingOccurrences(of: " · ", with: " ")
    }

    /// "2 hours 46 minutes", "1 hour", "12 minutes", "less than a minute".
    static func words(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60)), h = m / 60, r = m % 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if h == 0 { return r == 0 ? "less than a minute" : unit(r, "minute") }
        return r == 0 ? unit(h, "hour") : "\(unit(h, "hour")) \(unit(r, "minute"))"
    }

    /// "6:40" without AM/PM: the run-out time is always within the next five hours, and the pill stays narrow.
    /// On a 24-hour Mac "21:29", since "9:29" there reads as morning.
    private static let shortClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = Fmt.uses24Hour ? "HH:mm" : "h:mm"; return f
    }()

    /// Claude needs no letter (it's what Reset is mostly for); other tools get theirs so it's clear whose window it is.
    private static func prefix(_ s: WindowStatus) -> String {
        if s.id == "claude" { return "" }
        // A second Claude account is named by its plan ("Claude · Pro" → "Pro"); "C" would read as Codex.
        if s.id.hasPrefix("claude-"), let label = s.name.components(separatedBy: " · ").last { return label + " " }
        // Cursor and Codex both start with C.
        if s.id == "cursor" { return "Cu " }
        return "\(s.name.prefix(1)) "
    }
}

/// The pill itself, drawn as an image: menu bar labels are plain text unless they're an image, and the image
/// must not be a template or macOS would paint it in one colour.
enum MenuBarPill {
    static func colors(_ tone: MenuBarGlance.Tone) -> (fill: Color, ink: Color) {
        switch tone {
        case .normal: return (Color(red: 1, green: 0.62, blue: 0.26), .black)
        case .low, .runningOut: return (Color(red: 1, green: 0.3, blue: 0.28), .white)
        case .ready: return (Color(red: 0.3, green: 0.85, blue: 0.42), .black)
        case .blocked: return (.clear, .primary)
        }
    }

    /// The last pill drawn. The menu bar label is rebuilt every second (the clock ticks), but the pill's text only
    /// changes about once a minute; drawing a fresh image each second kept the graphics memory climbing.
    @MainActor private static var last: (glance: MenuBarGlance, scale: CGFloat, image: NSImage)?

    @MainActor static func image(_ g: MenuBarGlance) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let last, last.glance == g, last.scale == scale { return last.image }
        guard let img = draw(g, scale: scale) else { return nil }
        last = (g, scale, img)
        return img
    }

    /// Drawn with AppKit, as a vector image the menu bar renders when it needs it. SwiftUI's ImageRenderer left
    /// GPU-backed memory behind for every pill it drew; even once a minute that added up to 260 MB over a day.
    @MainActor private static func draw(_ g: MenuBarGlance, scale: CGFloat) -> NSImage? {
        let (fillColor, inkColor) = colors(g.tone)
        let fill = NSColor(fillColor), ink = g.tone == .blocked ? NSColor.labelColor : NSColor(inkColor)
        let twoLines = g.detail != nil
        let paddingX: CGFloat = twoLines ? 6 : 7, height: CGFloat = twoLines ? 21 : 17, radius: CGFloat = twoLines ? 6 : 8.5

        func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: ink.withAlphaComponent(alpha)])
        }
        let lines: [NSAttributedString] = twoLines
            // Softer than the session line, except on red, where white needs all the contrast it has.
            ? [attributed(g.text, size: 9, weight: .bold), attributed(g.detail ?? "", size: 9, weight: .semibold, alpha: inkColor == .white ? 1 : 0.75)]
            : [attributed(g.text, size: 12, weight: .semibold)]
        let textWidth = lines.map { ceil($0.size().width) }.max() ?? 0
        // Tinted over its own shape, so the "!" stays cut out; a palette colour filled the whole triangle.
        let icon: NSImage? = g.warning
            ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .bold))
                .map { symbol in
                    NSImage(size: symbol.size, flipped: false) { r in
                        symbol.draw(in: r)
                        ink.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                }
            : nil
        let iconWidth = icon.map { ceil($0.size.width) + 3 } ?? 0
        let size = NSSize(width: paddingX * 2 + iconWidth + textWidth, height: height)

        let img = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            var x = paddingX
            if let icon {
                icon.draw(in: NSRect(x: x, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                x += iconWidth
            }
            // Lines stacked from the top, centred together as a block, one point tighter than their natural spacing.
            let heights = lines.map { $0.size().height }
            let block = heights.reduce(0, +) - CGFloat(lines.count - 1)
            var y = (rect.height + block) / 2
            for (line, h) in zip(lines, heights) {
                y -= h
                line.draw(at: NSPoint(x: x, y: y))
                y += 1
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
