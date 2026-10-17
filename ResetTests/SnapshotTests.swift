import XCTest
import SwiftUI
@testable import Reset

/// Draws key views with fixed numbers and compares them pixel by pixel with reference images, so layout
/// problems (an arc through the countdown, text cut off, dots stacked on one spot) fail a test instead of
/// waiting to be spotted by eye. References live in Fixtures/snapshots and are read from the test bundle.
///
/// `./scripts/snapshots.sh --record` rewrites them (RESET_RECORD_SNAPSHOTS=1 writes to the temporary folder and
/// the script copies them in). A failure saves the actual image and a diff (changed pixels in red) to
/// $TMPDIR/reset-snapshots/failed. Rendering differs a little between macOS versions, so references are recorded
/// on the machine that runs the suite; the tolerance absorbs anti-aliasing noise, not layout changes.
@MainActor
final class SnapshotTests: XCTestCase {
    private static let refs = Bundle(for: SnapshotTests.self).resourceURL!.appendingPathComponent("Fixtures/snapshots")
    private static let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reset-snapshots")
    private var recording: Bool { ProcessInfo.processInfo.environment["RESET_RECORD_SNAPSHOTS"] == "1" }

    private let now = Date(timeIntervalSince1970: 1_772_442_000)

    private func claude(_ state: WindowStatus.State, used: Double?, source: String = "Live from your Claude account") -> WindowStatus {
        WindowStatus(id: "claude", name: "Claude", state: state, usedPercent: used, isEstimate: false, source: source,
                     secondary: nil, canAutoStart: true)
    }

    // MARK: Dashboard hero

    func testHeroAtThreeWidths() throws {
        // 560 is about the hero's width at the dashboard's narrowest window, where the arc once overlapped the digits.
        let s = claude(.active(resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)), used: 38)
        let budget = Budget(task: "API rate limiter", maxPercent: 70, downshiftModel: "haiku", setAt: now)
        for w in [560.0, 700, 900] {
            try check(HeroCard(status: s, now: now, subtitle: s.source, budget: budget, budgetUsed: 38), "hero-\(Int(w))", width: w)
        }
    }

    func testHeroStates() throws {
        let running = claude(.active(resetsAt: now.addingTimeInterval(4 * 3600)), used: 14)
        try check(HeroCard(status: running, now: now, subtitle: running.source, runsOutAt: now.addingTimeInterval(3600)),
                  "hero-running-out", width: 700)
        let ready = claude(.ready, used: 0)
        try check(HeroCard(status: ready, now: now, subtitle: ready.source), "hero-ready", width: 700)
        let estimated = claude(.active(resetsAt: now.addingTimeInterval(3 * 3600)), used: nil, source: "Estimated from your activity")
        let over = Budget(task: "Refactor auth", maxPercent: 50, downshiftModel: nil, setAt: now)
        try check(HeroCard(status: estimated, now: now, subtitle: "Estimated from your activity · Claude Code signed out",
                           signedOut: true, budget: over, budgetUsed: 64), "hero-signed-out-over-budget", width: 700)
    }

    func testSidebarArcs() throws {
        // At the sidebar's 22×13 the hero-sized "now" dot once covered the whole arc.
        let arcs = HStack(spacing: 12) {
            ForEach([0.0, 0.07, 0.5, 0.95], id: \.self) { p in
                WindowArc(progress: p, color: Theme.color(for: "claude"), lineWidth: 1.6).frame(width: 22, height: 13)
            }
        }.padding(6).background(Color.black)
        try check(arcs, "sidebar-arcs")
    }

    // MARK: Menu bar pill

    func testMenuBarPills() throws {
        let cases: [(String, MenuBarGlance)] = [
            ("pill-normal", MenuBarGlance(tone: .normal, text: "2:46 · 42%")),
            ("pill-low", MenuBarGlance(tone: .low, text: "0:24 · 9%")),
            ("pill-running-out", MenuBarGlance(tone: .runningOut, text: "86% · out 9:29")),
            ("pill-ready", MenuBarGlance(tone: .ready, text: "ready")),
            ("pill-signed-out", MenuBarGlance(tone: .normal, text: "2:46", warning: true)),
            ("pill-both", MenuBarGlance(tone: .normal, text: "2:46 · 42%", detail: "wk 3d · 60%")),
            ("pill-both-low", MenuBarGlance(tone: .low, text: "1:00 · 90%", detail: "wk 18h · 9%")),
        ]
        for (name, g) in cases {
            let img = try XCTUnwrap(MenuBarPill.image(g))
            try check(Image(nsImage: img).fixedSize(), name)
        }
    }

    // MARK: Looks

    func testEveryLook() throws {
        let d = CardData(id: "claude", name: "Claude", color: Theme.color(for: "claude"),
                         windowStart: now.addingTimeInterval(-2 * 3600 - 20 * 60), resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60),
                         ready: false, used: 58)
        for look in Look.allCases {
            try check(LookCard(look: look, d: d, now: now).frame(width: 340, height: 128), "look-\(look.rawValue)")
        }
    }

    // MARK: Compare or record

    private func check(_ view: some View, _ name: String, width: Double? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        // GitHub's Macs run another macOS, so the references can't match there (see the note at the top).
        if ProcessInfo.processInfo.environment["RESET_SKIP_SNAPSHOTS"] == "1" {
            throw XCTSkip("Snapshots only compare on the Mac that recorded them")
        }
        let sized = AnyView(view.frame(width: width.map { CGFloat($0) }).environment(\.colorScheme, .dark))
        let r = ImageRenderer(content: sized)
        r.scale = 2
        let actual = try XCTUnwrap(r.cgImage, "\(name) didn't render", file: file, line: line)
        let png = try XCTUnwrap(Self.png(actual), file: file, line: line)
        let fm = FileManager.default
        if recording {
            let dir = Self.out.appendingPathComponent("recorded")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            return
        }
        guard let refData = try? Data(contentsOf: Self.refs.appendingPathComponent(name + ".png")),
              let ref = NSBitmapImageRep(data: refData)?.cgImage else {
            XCTFail("No reference for \(name). Run ./scripts/snapshots.sh --record.", file: file, line: line)
            return
        }
        let result = Self.compare(actual, ref)
        guard !result.matches else { return }
        let failed = Self.out.appendingPathComponent("failed")
        try fm.createDirectory(at: failed, withIntermediateDirectories: true)
        try png.write(to: failed.appendingPathComponent(name + ".png"))
        if let diff = result.diff, let d = Self.png(diff) { try d.write(to: failed.appendingPathComponent(name + "-diff.png")) }
        XCTFail("""
            Snapshot \(name) changed: \(result.reason).
            Actual: \(failed.appendingPathComponent(name + ".png").path)
            If the change is intended, run ./scripts/snapshots.sh --record and commit the new reference.
            """, file: file, line: line)
    }

    /// A pixel counts as changed when any channel differs by more than `channelTolerance`; the snapshot fails
    /// when more than `pixelTolerance` of pixels changed. Enough for anti-aliasing noise, far below a moved element.
    static let channelTolerance = 32, pixelTolerance = 0.002

    struct Comparison { var matches: Bool; var reason: String; var diff: CGImage? }

    static func compare(_ a: CGImage, _ b: CGImage) -> Comparison {
        guard a.width == b.width, a.height == b.height else {
            return Comparison(matches: false, reason: "size \(a.width)×\(a.height) instead of \(b.width)×\(b.height)", diff: nil)
        }
        let w = a.width, h = a.height
        guard let pa = rgba(a), let pb = rgba(b) else { return Comparison(matches: false, reason: "couldn't read pixels", diff: nil) }
        var diffPixels = [UInt8](repeating: 0, count: w * h * 4)
        var changed = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let delta = (0..<4).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max() ?? 0
            if delta > channelTolerance {
                changed += 1
                diffPixels[i] = 255; diffPixels[i + 3] = 255
            } else {
                diffPixels[i] = pa[i] / 4; diffPixels[i + 1] = pa[i + 1] / 4; diffPixels[i + 2] = pa[i + 2] / 4; diffPixels[i + 3] = 255
            }
        }
        let share = Double(changed) / Double(w * h)
        let diff = image(diffPixels, width: w, height: h)
        return Comparison(matches: share <= pixelTolerance,
                          reason: String(format: "%.2f%% of pixels changed (allowed %.2f%%)", share * 100, pixelTolerance * 100), diff: diff)
    }

    private static func rgba(_ img: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        guard let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    private static func image(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        var px = px
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func png(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    // MARK: The comparison itself

    func testComparisonCatchesAMovedElementButNotNoise() throws {
        func draw(_ x: Int, noise: Bool) -> CGImage {
            var px = [UInt8](repeating: 0, count: 100 * 100 * 4)
            for i in stride(from: 0, to: px.count, by: 4) { px[i + 3] = 255; if noise && i % 40 == 0 { px[i] = 20 } }
            for y in 40..<60 { for xx in x..<(x + 20) { let i = (y * 100 + xx) * 4; px[i] = 255; px[i + 1] = 255; px[i + 2] = 255 } }
            return Self.image(px, width: 100, height: 100)!
        }
        XCTAssertTrue(Self.compare(draw(20, noise: false), draw(20, noise: true)).matches, "faint noise passes")
        XCTAssertFalse(Self.compare(draw(20, noise: false), draw(30, noise: false)).matches, "a 10-pixel move fails")
        XCTAssertFalse(Self.compare(draw(20, noise: false), Self.image([UInt8](repeating: 0, count: 50 * 50 * 4), width: 50, height: 50)!).matches,
                       "a size change fails")
    }
}
