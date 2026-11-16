import SwiftUI
import UserNotifications

@main
struct ResetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            // Not wrapped in WhileVisible: the menu is small, and it's the one window that must never come up empty.
            MenuView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Reset", id: "dashboard") {
            WhileVisible { DashboardView(store: store, usage: store.usage) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 900)

        Window("Welcome to Reset", id: "welcome") {
            WelcomeWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Reset Settings", id: "settings") {
            WhileVisible { SettingsView(store: store) }
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        label
            .onChange(of: store.openRequest) { _, w in
                guard let w else { return }
                store.openRequest = nil
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: w)
            }
            .task {
                // `open -a Reset --args -openDashboard YES`, and the first launch after install, show the dashboard.
                // `-openSettings YES` opens Settings, for checking it (with `-simulateLogFormat`, the format warning);
                // `-renderSettings /path.png` also saves a picture of it, taken by Reset itself.
                let d = UserDefaults.standard
                if Demo.isOn || AppDelegate.underTest { return }
                if !d.bool(forKey: "onboarded") || d.bool(forKey: "openWelcome") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "welcome")
                } else if d.bool(forKey: "openSettings") || d.string(forKey: "renderSettings") != nil {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                    if let path = d.string(forKey: "renderSettings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            // A window's own view can be drawn into an image without Screen Recording permission.
                            guard let v = NSApp.windows.first(where: { $0.title == "Reset Settings" })?.contentView,
                                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                    }
                } else if d.bool(forKey: "openDashboard") || !d.bool(forKey: "dashboardSeen") {
                    d.set(true, forKey: "dashboardSeen")
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                    // Test hook: `-cycleWindows /path.json` closes the dashboard, reopens it and closes it again, writing whether each window's content is loaded after every step (see WhileVisible).
                    if let path = d.string(forKey: "cycleWindows") {
                        var steps: [[String: Any]] = []
                        func record(_ step: String) {
                            let windows = NSApp.windows.map { ["title": $0.title, "open": $0.isVisible, "seen": $0.occlusionState.contains(.visible),
                                                               "class": String(describing: type(of: $0)), "size": "\(Int($0.frame.width))x\(Int($0.frame.height))"] as [String: Any] }
                            steps.append(["step": step, "loaded": WindowVisibilityView.loaded, "windows": windows])
                            try? JSONSerialization.data(withJSONObject: steps, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
                        }
                        func at(_ t: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work) }
                        at(18) { record("dashboard open"); NSApp.windows.first { $0.title == "Reset" }?.close() }
                        at(38) { record("dashboard closed 20s"); NSApp.activate(ignoringOtherApps: true); openWindow(id: "dashboard") }
                        at(48) { record("dashboard reopened 10s"); NSApp.windows.first { $0.title == "Reset" }?.close() }
                        at(66) { record("dashboard closed again 18s") }
                    }
                }
            }
    }

    /// "pill" (default) or "text", from Settings → Appearance.
    @AppStorage("menuBarStyle") private var style = "pill"

    @ViewBuilder private var label: some View {
        if style == "pill", let g = store.glance {
            if g.tone == .blocked {
                // Nothing to act on during a weekly limit, so no colour: a moon and when it lifts, in the bar's own ink.
                Text("\(Image(systemName: "moon.zzz.fill")) \(g.text)").monospacedDigit()
            } else if let img = MenuBarPill.image(g) {
                Image(nsImage: img).accessibilityLabel(g.spoken)
            } else {
                Text(g.text).monospacedDigit()
            }
        } else if let r = store.readyForBar {
            Text("\(r.name.prefix(1)) ready")
        } else if let s = store.soonest, let at = s.resetsAt {
            if store.liveNeedsSignIn && s.id == "claude" {
                Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(s.name.prefix(1)) \(Fmt.short(at.timeIntervalSince(store.now)))").monospacedDigit()
            } else {
                Text("\(s.name.prefix(1)) \(Fmt.short(at.timeIntervalSince(store.now)))").monospacedDigit()
            }
        } else {
            Image(systemName: "hourglass")
        }
    }
}

/// Hosts the first-run setup and hands over to the dashboard when it's done.
struct WelcomeWindow: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        OnboardingView(store: store) {
            UserDefaults.standard.set(true, forKey: "onboarded")
            UserDefaults.standard.set(true, forKey: "dashboardSeen")
            openWindow(id: "dashboard")
            dismissWindow(id: "welcome")
        }
    }
}

extension Store {
    static let shared = Store()
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The unit tests run inside a copy of the app. Started for real, that copy polled Anthropic's usage endpoint,
    /// wrote the status line and heartbeat, and on quit told the real Reset's status line it wasn't running.
    static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.underTest else { return }
        UNUserNotificationCenter.current().delegate = self
        Store.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.underTest else { return }
        Store.shared.markQuit()
    }

    // A click on a banner opens the dashboard; its buttons sign in or start the window.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? "claude"
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            let store = Store.shared
            switch action {
            case Alerts.Action.signIn: store.fixClaudeSignIn()
            case Alerts.Action.start: store.startFromWidget(id, from: "a notification")
            default: store.openRequest = "dashboard"
            }
        }
        completionHandler()
    }

    // Show banners even when Reset's menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
