import SwiftUI

/// One provider's status, drawn many ways. Shared by the app (menu, settings gallery) and the widget extension.
enum Look: String, CaseIterable, Identifiable, Codable {
    case glow, paper, board, pass, sky, complication, holo, mono
    var id: String { rawValue }
    var name: String {
        switch self {
        case .glow: return "Glow"
        case .paper: return "Paper"
        case .board: return "Departure board"
        case .pass: return "Boarding pass"
        case .sky: return "Sky"
        case .complication: return "Complication"
        case .holo: return "Holo"
        case .mono: return "Mono"
        }
    }
}

struct CardData {
    var id: String
    var name: String
    var color: Color
    var windowStart: Date?
    var resetsAt: Date?
    var ready: Bool
    var blockedUntil: Date?
    /// Percent of the window used, if known.
    var used: Double?
    var mascot: Image?
    var windowLength: TimeInterval = 5 * 3600
    /// Why the numbers are a guess, or nil when they're solid (see UsageAccuracy).
    var estimate: String? = nil

    /// Usage is known only from a reading; without one, `left` falls back to the clock.
    var usageKnown: Bool { used != nil }

    /// "42% left" from usage, or "~70% of time left" when only the clock is known, so time is never
    /// passed off as usage.
    func leftPhrase(at now: Date) -> String {
        guard let l = left(at: now) else { return "--" }
        let pct = Int((l * 100).rounded())
        if usageKnown || isReady(at: now) || (blockedUntil.map { $0 > now } ?? false) { return "\(pct)% left" }
        return "~\(pct)% of time left"
    }

    /// The small word under a big percentage: "left", or "time left" when it's the clock.
    func leftWord(at now: Date) -> String {
        usageKnown || isReady(at: now) ? "left" : "time left"
    }

    /// 0...1 left: by usage when known, else by time.
    func left(at now: Date) -> Double? {
        if let b = blockedUntil, b > now { return 0 }
        if ready || (resetsAt.map { $0 <= now } ?? false) { return 1 }
        if let u = used { return max(0, 1 - u / 100) }
        if let r = resetsAt { return min(1, max(0, r.timeIntervalSince(now) / windowLength)) }
        return nil
    }

    func isReady(at now: Date) -> Bool { ready || (resetsAt.map { $0 <= now } ?? false) }

    /// Fraction of the window's time elapsed, for arcs and flight paths.
    func elapsed(at now: Date) -> Double {
        guard let r = resetsAt, r > now else { return isReady(at: now) ? 0 : 1 }
        return 1 - min(1, r.timeIntervalSince(now) / windowLength)
    }

    var target: Date? { blockedUntil.flatMap { $0 > Date() ? $0 : nil } ?? resetsAt }
}

/// Widgets cannot tick a clock themselves, so they use timer text; the app formats its own.
private struct LiveTimerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var lookUsesTimerText: Bool {
        get { self[LiveTimerKey.self] }
        set { self[LiveTimerKey.self] = newValue }
    }
}

struct CountdownText: View {
    let d: CardData
    let now: Date
    var readyText = "ready"
    /// Widget timer text always fills its width; this says where the digits sit inside it.
    var align: TextAlignment = .leading
    @Environment(\.lookUsesTimerText) private var timerText

    var body: some View {
        if d.isReady(at: now) && (d.blockedUntil.map { $0 <= now } ?? true) {
            Text(readyText)
        } else if let t = d.target, t > now {
            if timerText { Text(timerInterval: now...t, countsDown: true, showsHours: true).multilineTextAlignment(align) }
            else { Text(Self.hm(t.timeIntervalSince(now))) }
        } else {
            Text("--")
        }
    }

    static func hm(_ s: TimeInterval) -> String {
        let s = max(0, Int(s)), h = s / 3600, m = (s % 3600) / 60
        // A month-long window (Cursor) or a weekly limit: "127:30" read as a clock.
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h):\(String(format: "%02d", m))" : "0:\(String(format: "%02d", m))"
    }
}

struct LookCard: View {
    let look: Look
    let d: CardData
    let now: Date

    var body: some View {
        Group {
            switch look {
            case .glow: GlowLook(d: d, now: now)
            case .paper: PaperLook(d: d, now: now)
            case .board: BoardLook(d: d, now: now)
            case .pass: PassLook(d: d, now: now)
            case .sky: SkyLook(d: d, now: now)
            case .complication: ComplicationLook(d: d, now: now)
            case .holo: HoloLook(d: d, now: now)
            case .mono: MonoLook(d: d, now: now)
            }
        }
        .frame(minWidth: 300, idealWidth: 340, minHeight: 128, idealHeight: 128)
    }
}

private func clock(_ d: Date?) -> String {
    guard let d else { return "--" }
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm"); return f.string(from: d)
}

/// The bare percentage for big numbers; "~" marks it as time-based when there's no usage reading.
private func pctLeft(_ d: CardData, _ now: Date) -> String {
    guard let l = d.left(at: now) else { return "--" }
    return (d.usageKnown || d.isReady(at: now) ? "" : "~") + "\(Int((l * 100).rounded()))%"
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: Glow

struct GlowLook: View {
    let d: CardData; let now: Date
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(rgb: 0x111111)
            RadialGradient(colors: [d.color.opacity(0.55), d.color.opacity(0.12), .clear], center: UnitPoint(x: 0.25, y: 0.9), startRadius: 0, endRadius: 200)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    CountdownText(d: d, now: now).font(.system(size: 48, weight: .light).monospacedDigit()).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(d.isReady(at: now) ? "fresh window waiting" : "resets \(clock(d.target)) · \(d.leftPhrase(at: now))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if let m = d.mascot { m.resizable().aspectRatio(contentMode: .fit).frame(width: 84, height: 84) }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.07)))
    }
}

// MARK: Paper

struct PaperLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let left = d.left(at: now) ?? 1
        ZStack {
            Color.white
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(d.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    Spacer()
                    Text(d.isReady(at: now) ? "Ready" : "Resets \(clock(d.target))").font(.system(size: 12)).foregroundStyle(.black.opacity(0.5))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    CountdownText(d: d, now: now, readyText: "Fresh").font(.system(size: 38, weight: .semibold).monospacedDigit()).foregroundStyle(.black)
                    Text(d.isReady(at: now) ? "" : d.leftWord(at: now)).font(.system(size: 14)).foregroundStyle(.black.opacity(0.45))
                    Spacer()
                    Text(pctLeft(d, now)).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.black.opacity(0.7))
                }
                // Striped bar, like a storage widget: solid for what is left, hatched for what is spent.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.06))
                        Stripes(color: d.color).frame(width: g.size.width * left).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .frame(height: 22)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

struct Stripes: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + 5, y: 0)); p.addLine(to: CGPoint(x: x + 5, y: size.height)); p.closeSubpath()
                ctx.fill(p, with: .color(.white.opacity(0.25)))
                x += 12
            }
        }
    }
}

// MARK: Departure board

struct BoardLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let text: String = {
            if d.isReady(at: now) { return "READY" }
            guard let t = d.target else { return "--:--" }
            return CountdownText.hm(t.timeIntervalSince(now)).count == 4 ? "0" + CountdownText.hm(t.timeIntervalSince(now)) : CountdownText.hm(t.timeIntervalSince(now))
        }()
        ZStack {
            Color(rgb: 0xF4F4F2)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Next window").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    Spacer()
                    Text(d.name.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(.black.opacity(0.5))
                }
                HStack(spacing: 6) {
                    Text("now").font(.system(size: 11)).foregroundStyle(.black.opacity(0.45))
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
                    Image(systemName: "airplane").font(.system(size: 10)).foregroundStyle(.black.opacity(0.6))
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
                    Text(clock(d.target)).font(.system(size: 11)).foregroundStyle(.black.opacity(0.45))
                }
                DotMatrix(text: text, on: Color(rgb: 0x3D3BD9), off: Color.black.opacity(0.07)).frame(height: 54)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

/// A 5×7 dot font for digits, colon, dash and READY.
struct DotMatrix: View {
    let text: String
    let on: Color
    let off: Color

    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ":": ["0", "0", "1", "0", "1", "0", "0"],
        "-": ["000", "000", "000", "111", "000", "000", "000"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    ]

    var body: some View {
        Canvas { ctx, size in
            let chars = Array(text)
            let widths = chars.map { (Self.glyphs[$0]?.first?.count ?? 3) }
            let cols = widths.reduce(0, +) + max(0, chars.count - 1)
            let cell = min(size.height / 7, size.width / CGFloat(cols))
            var x = (size.width - CGFloat(cols) * cell) / 2
            for (i, ch) in chars.enumerated() {
                let g = Self.glyphs[ch] ?? Array(repeating: String(repeating: "0", count: widths[i]), count: 7)
                for (r, row) in g.enumerated() {
                    for (c, bit) in row.enumerated() {
                        let rect = CGRect(x: x + CGFloat(c) * cell + cell * 0.12, y: CGFloat(r) * cell + cell * 0.12, width: cell * 0.76, height: cell * 0.76)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: cell * 0.12), with: .color(bit == "1" ? on : off))
                    }
                }
                x += CGFloat(widths[i] + 1) * cell
            }
        }
    }
}

// MARK: Boarding pass

struct PassLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let p = d.elapsed(at: now)
        ZStack {
            Color(rgb: 0x0B0B0C)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("STARTED \(d.windowStart.map { clock($0) } ?? "--")").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text("RESETS \(clock(d.target))").font(.system(size: 10, weight: .semibold)).tracking(1)
                }
                .foregroundStyle(.white.opacity(0.55))
                HStack(alignment: .center, spacing: 10) {
                    Text("NOW").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                            Capsule().fill(d.color).frame(width: g.size.width * p, height: 4)
                            Image(systemName: "airplane").font(.system(size: 14)).foregroundStyle(.white)
                                .offset(x: max(0, g.size.width * p - 8))
                        }
                        .frame(maxHeight: .infinity)
                    }
                    Text("NEW").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                }
                .frame(height: 36)
                HStack {
                    Text(d.name.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(d.isReady(at: now) ? "BOARDING" : "ON TIME").font(.system(size: 11, weight: .bold)).foregroundStyle(d.color)
                    Spacer()
                    CountdownText(d: d, now: now, readyText: "0:00", align: .trailing).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .frame(width: 66, alignment: .trailing)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: Sky

struct SkyLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let left = d.left(at: now) ?? 1
        // Fresh is day, half used is golden evening, exhausted is night.
        let colors: [Color] = left > 0.6 ? [Color(rgb: 0x5BA3E8), Color(rgb: 0xBFE0FA)]
            : left > 0.25 ? [Color(rgb: 0x6B4E8C), Color(rgb: 0xF39A4B)]
            : [Color(rgb: 0x05070D), Color(rgb: 0x1C2233)]
        let dark = left <= 0.6
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let t = 1 - left
                // Keep the whole arc, and the sun at its peak, inside the card.
                let r = min(w * 0.42, h * 0.78), cy = h * 1.02
                Path { p in p.addArc(center: CGPoint(x: w / 2, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false) }
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                let a = Double.pi * (1 - t)
                let sx = w / 2 + cos(a) * r, sy = cy - sin(a) * r
                Circle().fill(left > 0.25 ? Color(rgb: 0xFFE7A8) : Color(rgb: 0xE8ECF5))
                    .frame(width: 16, height: 16)
                    .shadow(color: .white.opacity(0.8), radius: left > 0.25 ? 12 : 4)
                    .position(x: sx, y: sy)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(left > 0.6 ? "Day" : left > 0.25 ? "Evening" : "Night").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(d.leftPhrase(at: now)).font(.system(size: 12).monospacedDigit())
                }
                Text(d.name).font(.system(size: 11)).opacity(0.7)
                Spacer()
                CountdownText(d: d, now: now).font(.system(size: 34, weight: .light).monospacedDigit())
            }
            .foregroundStyle(dark ? Color.white : Color(rgb: 0x10304F))
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: Complication

struct ComplicationLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let left = d.left(at: now) ?? 1
        ZStack {
            Color(rgb: 0xF2F2F0)
            HStack(spacing: 18) {
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 2
                        let ticks = 40, start = -220.0, sweep = 260.0
                        for i in 0..<ticks {
                            let f = Double(i) / Double(ticks - 1)
                            let ang = (start + sweep * f) * .pi / 180
                            let lit = f <= left
                            var p = Path()
                            p.move(to: CGPoint(x: c.x + cos(ang) * (r - 9), y: c.y + sin(ang) * (r - 9)))
                            p.addLine(to: CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r))
                            ctx.stroke(p, with: .color(lit ? Color(rgb: 0xF59E0B) : .black.opacity(0.12)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                    }
                    VStack(spacing: 0) {
                        Text(pctLeft(d, now)).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(.black)
                        Text(d.leftWord(at: now)).font(.system(size: 10)).foregroundStyle(.black.opacity(0.5))
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(rgb: 0xD97706))
                    CountdownText(d: d, now: now).font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(.black)
                    Text(d.isReady(at: now) ? "fresh window" : "until reset at \(clock(d.target))").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                }
                Spacer()
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

// MARK: Holo

struct HoloLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let rarity: String = {
            guard let l = d.left(at: now) else { return "COMMON" }
            return l > 0.8 ? "LEGENDARY" : l > 0.5 ? "RARE" : l > 0.2 ? "UNCOMMON" : "COMMON"
        }()
        ZStack {
            AngularGradient(colors: [Color(rgb: 0xFF9AD5), Color(rgb: 0x9AD7FF), Color(rgb: 0xB8FFCE), Color(rgb: 0xFFF29A), Color(rgb: 0xFF9AD5)], center: .center)
            RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color(rgb: 0x101018)).padding(5)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [d.color.opacity(0.45), d.color.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    if let m = d.mascot { m.resizable().aspectRatio(contentMode: .fit).padding(6) }
                }
                .frame(width: 96)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(d.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Text(rarity).font(.system(size: 8, weight: .heavy)).tracking(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(LinearGradient(colors: [Color(rgb: 0xFF9AD5), Color(rgb: 0x9AD7FF)], startPoint: .leading, endPoint: .trailing)))
                            .foregroundStyle(Color(rgb: 0x101018))
                    }
                    HStack(spacing: 14) {
                        holoStat("HP", pctLeft(d, now))
                        holoStat("RESET", clock(d.target))
                    }
                    CountdownText(d: d, now: now).font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                }
                .padding(.vertical, 4)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private func holoStat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.45))
            Text(v).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
    }
}

// MARK: Mono

struct MonoLook: View {
    let d: CardData; let now: Date
    var body: some View {
        let left = d.left(at: now)
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Circle().fill(d.color).frame(width: 6, height: 6)
                    Text(d.name.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    Spacer()
                    Text("RESETS \(clock(d.target))").font(.system(size: 9, weight: .medium)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 10)
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                Spacer()
                HStack(alignment: .lastTextBaseline) {
                    CountdownText(d: d, now: now, readyText: "READY").font(.system(size: 40, weight: .ultraLight, design: .monospaced)).foregroundStyle(.white)
                    Spacer()
                    Text(left.map { "\(Int(($0 * 100).rounded()))%" } ?? "--").font(.system(size: 13, weight: .light, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.14))
                        Rectangle().fill(d.color).frame(width: g.size.width * (left ?? 0))
                    }
                }
                .frame(height: 2)
                .padding(.top, 6)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.18)))
    }
}
