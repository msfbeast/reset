import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The 1200 × 675 card for X: one giant number, a few headline stats, the build heatmap and the mascot.
struct ShareCardView: View {
    struct Model {
        var title: String
        var hero: String
        var heroUnit: String
        var line: AttributedString
        var stats: [(String, String)]
        var heatmap: [[Double]]
        var mascot: NSImage?
    }
    let m: Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x050505)
            RadialGradient(colors: [Color(hex: 0xFF7A1F).opacity(0.6), Color(hex: 0xFF4A1F).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.28, y: 0.62), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: 0x5B8CFF).opacity(0.35), .clear],
                           center: UnitPoint(x: 0.95, y: 0.0), startRadius: 0, endRadius: 420)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(m.title).font(.system(size: 26)).foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                    Text("reset").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                Spacer().frame(height: 54)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.hero).font(.system(size: 230, weight: .light).monospacedDigit()).foregroundStyle(.white)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(m.heroUnit).font(.system(size: 80, weight: .light)).foregroundStyle(Color.white.opacity(0.55))
                }
                .frame(height: 230)
                Text(m.line).font(.system(size: 30)).padding(.top, 14)
                Spacer()
                HStack(alignment: .bottom, spacing: 34) {
                    ForEach(m.stats.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.stats[i].1).font(.system(size: 46, weight: .light).monospacedDigit()).foregroundStyle(.white)
                            Text(m.stats[i].0).font(.system(size: 17)).foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Heatmap(grid: m.heatmap).frame(width: 400, height: 112)
                }
            }
            .padding(.horizontal, 64).padding(.vertical, 56)
            if let img = m.mascot {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 300)
                    .shadow(color: Color(hex: 0xFF8A2A).opacity(0.5), radius: 40)
                    .offset(x: 840, y: 150)
            }
        }
        .frame(width: 1200, height: 675)
        .environment(\.colorScheme, .dark)
    }
}

/// The "where it went" card: how much of the period re-did work it didn't have to, and what caused it.
struct WasteCardView: View {
    struct Model {
        var title: String
        var hero: String
        var line: String
        var cause: String
        var segments: [(name: String, usd: Double, color: Color)]
    }
    let m: Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x050505)
            RadialGradient(colors: [Color(hex: 0xFF7A1F).opacity(0.5), .clear], center: UnitPoint(x: 0.2, y: 0.7), startRadius: 0, endRadius: 560)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(m.title).font(.system(size: 26)).foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                    Text("reset").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                Spacer().frame(height: 40)
                Text(m.hero).font(.system(size: 210, weight: .light).monospacedDigit()).foregroundStyle(.white)
                    .minimumScaleFactor(0.5).lineLimit(1).frame(height: 210)
                Text(m.line).font(.system(size: 36)).foregroundStyle(.white).padding(.top, 8)
                Text(m.cause).font(.system(size: 26)).foregroundStyle(Color.white.opacity(0.6)).padding(.top, 6)
                Spacer()
                let total = max(0.01, m.segments.reduce(0) { $0 + $1.usd })
                GeometryReader { g in
                    HStack(spacing: 4) {
                        ForEach(m.segments.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 6).fill(m.segments[i].color)
                                .frame(width: max(6, (g.size.width - 8) * m.segments[i].usd / total))
                        }
                    }
                }
                .frame(height: 22)
                HStack(spacing: 28) {
                    ForEach(m.segments.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Circle().fill(m.segments[i].color).frame(width: 12, height: 12)
                            Text(m.segments[i].name).font(.system(size: 19)).foregroundStyle(Color.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Text("found by Reset · msfbeast.github.io/reset").font(.system(size: 19)).foregroundStyle(Color.white.opacity(0.5))
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 64).padding(.vertical, 56)
        }
        .frame(width: 1200, height: 675)
        .environment(\.colorScheme, .dark)
    }
}

/// Builds the card from current usage, previews it, and copies, saves or shares the PNG.
struct ShareSheet: View {
    @Bindable var usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var showMascot = true
    /// Which card: the value of the period, or where its usage went.
    @State private var showWaste = false
    @State private var copied = false

    private var model: ShareCardView.Model { Self.model(usage, mascot: showMascot) }

    static func model(_ usage: UsageStore, mascot showMascot: Bool) -> ShareCardView.Model {
        let title: String
        switch usage.range {
        case .today: title = "My AI day · " + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        case .week: title = "My AI week"
        // The last 30 days, not the calendar month its name was printed with.
        case .month: title = "My last 30 days with AI"
        case .all: title = usage.firstCall.map { "My AI since \($0.formatted(.dateTime.month(.wide).day()))" } ?? "My AI so far"
        }
        var line = AttributedString()
        func part(_ s: String, _ bright: Bool) { var a = AttributedString(s); a.foregroundColor = bright ? .white : Color.white.opacity(0.6); line += a }
        let hero: String, unit: String
        if let mult = usage.valueMultiple {
            hero = String(format: mult >= 100 ? "%.0f" : "%.1f", mult); unit = "×"
            part(Dash.money(usage.totalCost), true); part(" of API value on a ", false)
            part(Dash.money(usage.effectivePlan), true); part(" Claude plan", false)
        } else {
            hero = Dash.money(usage.totalCost); unit = ""
            part("of Claude usage at API prices", false)
        }
        let mix = usage.tokenMix
        let hit = mix.total > 0 ? Double(mix.cacheRead) / Double(max(1, mix.cacheRead + mix.cacheWrite + mix.input)) : 0
        var byModel: [String: Double] = [:]
        for c in usage.inRange { byModel[c.model, default: 0] += c.cost }
        let top = byModel.max { $0.value < $1.value }?.key ?? ""
        let topName = top.contains("opus") ? "Opus" : top.contains("sonnet") ? "Sonnet" : top.contains("haiku") ? "Haiku" : top.contains("fable") ? "Fable" : "--"
        let windows = usage.windows(days: max(1, Int(usage.rangeDays.rounded(.up))), scoped: true).count
        return .init(title: title, hero: hero, heroUnit: unit, line: line,
                     stats: [("tokens", Dash.tokens(mix.total)), ("windows", "\(windows)"),
                             ("cache hit", String(format: "%.0f%%", hit * 100)), ("top model", topName)],
                     heatmap: usage.scopedHeatmap,
                     mascot: showMascot ? MascotArt.image("claude", .fresh) : nil)
    }

    @MainActor private func render() -> NSImage? {
        guard showWaste else { return Self.render(model) }
        let r = ImageRenderer(content: WasteCardView(m: Self.wasteModel(usage)))
        r.scale = 2
        return r.nsImage
    }

    /// A share of usage on a subscription (dollars aren't what was paid), dollars at API rates otherwise.
    static func wasteModel(_ usage: UsageStore) -> WasteCardView.Model {
        let r = usage.waste
        // A plan price set means a subscription: a share of usage, not dollars that weren't paid.
        let onPlan = usage.totalPlanMonthly > 0
        let period: String = {
            switch usage.range {
            case .today: return "today"
            case .week: return "this week"
            case .month: return "in the last 30 days"
            case .all: return usage.firstCall.map { "since \($0.formatted(.dateTime.month(.wide).day()))" } ?? "so far"
            }
        }()
        let breaks = r.bucket(.breaks).usd
        return .init(title: "My Claude Code, \(period)",
                     hero: onPlan ? "\(Int((r.share * 100).rounded()))%" : "$" + Int(r.total.rounded()).formatted(),
                     line: onPlan ? "of my usage re-did work it didn't need to" : "spent re-doing work it didn't need to",
                     cause: breaks >= r.total / 2 ? "Mostly re-reading long sessions after a break" : "Context rebuilt mid-session, and tools failing in a row",
                     segments: [("Breaks", breaks, Color(hex: 0xFF8A2A)), ("Busts", r.bucket(.busts).usd, Color(hex: 0x9B7BFF)),
                                ("Loops", r.bucket(.loops).usd, Color(hex: 0xFF5C3A))])
    }

    @MainActor static func render(_ m: ShareCardView.Model) -> NSImage? {
        let r = ImageRenderer(content: ShareCardView(m: m))
        r.scale = 2
        return r.nsImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Share card").font(.system(size: 15, weight: .medium))
                Spacer()
                Picker("", selection: $usage.range) {
                    ForEach(UsageRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300)
            }
            Group {
                if showWaste { WasteCardView(m: Self.wasteModel(usage)) } else { ShareCardView(m: model) }
            }
                .scaleEffect(0.6, anchor: .topLeading)
                .frame(width: 720, height: 405, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                Picker("", selection: $showWaste) {
                    Text("Value").tag(false)
                    Text("Where it went").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 220)
                if !showWaste { Toggle("Mascot", isOn: $showMascot) }
                Spacer()
                Button(copied ? "Copied" : "Copy image") {
                    guard let img = render() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                    copied = true
                }
                Button("Save PNG…") {
                    guard let img = render(), let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.png]
                    panel.nameFieldStringValue = "reset-\(usage.range.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")).png"
                    if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
                }
                ShareButton(make: render)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 756)
        .onChange(of: showMascot) { _, _ in copied = false }
        .onChange(of: showWaste) { _, _ in copied = false }
        .onChange(of: usage.range) { _, _ in copied = false }
    }
}

/// macOS share menu (Messages, AirDrop, Notes, and any installed sharing extensions).
struct ShareButton: NSViewRepresentable {
    let make: @MainActor () -> NSImage?
    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        b.bezelStyle = .rounded
        return b
    }
    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.make = make }
    func makeCoordinator() -> Coordinator { Coordinator(make: make) }
    final class Coordinator: NSObject {
        var make: @MainActor () -> NSImage?
        init(make: @escaping @MainActor () -> NSImage?) { self.make = make }
        @MainActor @objc func share(_ sender: NSButton) {
            guard let img = make() else { return }
            NSSharingServicePicker(items: [img]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
