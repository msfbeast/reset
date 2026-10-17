import SwiftUI
import UserNotifications

/// Settings in four tabs, so the everyday choices aren't buried among technical ones: General (live usage,
/// tools, alerts), Automation (auto-start, stay awake), Appearance (look, mascots), and Advanced (commands,
/// custom tools, Claude Code integration, diagnostics). A beginner never needs Advanced.
struct SettingsView: View {
    @Bindable var store: Store
    @State private var newName = ""
    @State private var newHours = 5.0
    @State private var topicDraft = ""
    @State private var statusLineState = ClaudeIntegration.State.missing
    @State private var mcpState = ClaudeIntegration.State.missing
    @State private var integrationMessage: String?
    @State private var confirmReplaceStatusLine = false
    @State private var installingMCP = false
    @State private var showingUpdateNotes = false
    @State private var testResult: String?
    /// Whether macOS lets Reset show notifications; nil until checked.
    @State private var notificationsAllowed: Bool?
    /// Remembered between openings; `-settingsTab advanced` on the command line opens a given tab (for renders).
    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage("menuBarStyle") private var menuBarStyle = "pill"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            automation.tabItem { Label("Automation", systemImage: "bolt") }.tag("automation")
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag("advanced")
        }
        .frame(width: 540, height: 680)
        .onDisappear {
            // A topic typed but never saved was lost when Settings closed.
            if topicDraft != store.ntfyTopic, !topicDraft.isEmpty, Alerts.endpoint(server: store.ntfyServer, topic: topicDraft) != nil {
                store.ntfyTopic = topicDraft
            }
        }
        .onAppear {
            topicDraft = store.ntfyTopic
            // Denied (or later switched off in System Settings), every Alert box here still looked on and nothing came.
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                DispatchQueue.main.async { notificationsAllowed = ok }
            }
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            // Only shown when something is wrong; a healthy check is one quiet line under Advanced.
            if [.problems, .noRows].contains(store.usage.format.verdict) {
                Section {
                    Label {
                        Text(store.usage.format.summary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Button(store.updater.checking ? "Checking…" : "Check for a Reset update") { store.updater.check() }
                            .disabled(store.updater.checking)
                        Link("Report it on GitHub", destination: URL(string: ResetInfo.repoURL + "/issues")!)
                    }
                } header: {
                    Text("Claude Code log format")
                } footer: {
                    Text("Reset reads Claude Code's local logs, and a Claude Code update can change how they're written. Nothing is sent anywhere by this check.")
                        .foregroundStyle(.secondary)
                }
            }

            // First, because every Claude number is a guess without it.
            Section {
                Toggle("Live usage from your Claude account", isOn: $store.liveClaudeEnabled)
                if store.liveClaudeEnabled {
                    Text(liveText).font(.caption).foregroundStyle(liveIsProblem ? Color.orange : Color.secondary)
                }
            } header: {
                Text("Claude accuracy")
            } footer: {
                Text("Turn this on for exact usage and reset times, updated every 2 minutes while you're using Claude Code and every 5 minutes otherwise. Without it, Reset estimates from your Claude Code activity and labels its numbers \"estimated\". It reads Claude Code's sign-in from your Keychain (macOS may ask once) and sends it only to api.anthropic.com. Usage numbers only, never chats.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(toolList, id: \.0) { id, name in toolRow(id: id, name: name) }
            } header: {
                Text("Your tools")
            } footer: {
                Text("Switch on the tools you use. Alert: a notification when its window resets.").foregroundStyle(.secondary)
            }

            Section {
                if notificationsAllowed == false {
                    HStack {
                        Label("Notifications are off for Reset", systemImage: "bell.slash").foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            let id = Bundle.main.bundleIdentifier ?? "in.trak.reset"
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Picker("Heads-up before reset", selection: $store.leadMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: {
                Text("Mac alerts")
            }

            Section {
                // On with no topic sent nothing at all; a typed topic is saved first, an empty one keeps it off.
                Toggle("Send reset alerts to my phone", isOn: Binding(get: { store.phoneEnabled }, set: { on in
                    if on, store.ntfyTopic.isEmpty {
                        guard !topicDraft.isEmpty, Alerts.endpoint(server: store.ntfyServer, topic: topicDraft) != nil else {
                            testResult = "Add a topic first"; return
                        }
                        store.ntfyTopic = topicDraft
                    }
                    store.phoneEnabled = on
                }))
                HStack {
                    TextField("Topic", text: $topicDraft, prompt: Text("a long random name only you know"))
                        .onSubmit { store.ntfyTopic = topicDraft }
                    Button("Save") { store.ntfyTopic = topicDraft }
                        .disabled(topicDraft == store.ntfyTopic || Alerts.endpoint(server: store.ntfyServer, topic: topicDraft) == nil)
                }
                HStack {
                    Button("Send test") {
                        testResult = "Sending…"
                        store.sendTestPush { r in
                            testResult = r
                            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if testResult == r { testResult = nil } }
                        }
                    }
                    .disabled(store.ntfyTopic.isEmpty)
                    if let r = testResult {
                        Text(r).font(.caption).foregroundStyle(r.hasPrefix("Sent") ? Color.green : r == "Sending…" ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if Alerts.endpoint(server: store.ntfyServer, topic: topicDraft) == nil && !topicDraft.isEmpty {
                        Text("Letters, numbers, - and _ only").font(.caption).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Phone alerts")
            } footer: {
                Text("Install the free ntfy app on your phone and subscribe to the same topic. Alerts arrive even while this Mac is asleep. Anyone who knows the topic name can read it, so pick something unguessable. To break through Do Not Disturb, allow high-priority alerts for it in the ntfy app. A different ntfy server is under Advanced.")
                    .foregroundStyle(.secondary)
            }

            if store.usage.accounts.count > 1 {
                Section {
                    ForEach(store.usage.accounts, id: \.id) { a in
                        HStack {
                            Text(a.id == "claude" ? "Signed in to Claude Code" : "Other account").foregroundStyle(.secondary)
                            Spacer()
                            TextField("", text: accountName(a.id), prompt: Text(a.name.components(separatedBy: " · ").last ?? ""))
                                .frame(width: 160).multilineTextAlignment(.trailing)
                                .onSubmit { store.refresh() }
                        }
                    }
                } header: {
                    Text("Claude accounts")
                } footer: {
                    Text("Name them, for example Work and Personal. Reset tells accounts apart by their Claude organization and never sees their email addresses.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                // Also here, not only behind the dashboard's Edit plan: the setup guide says everything is in Settings.
                let accounts = store.usage.accounts.count > 1 ? store.usage.accounts.map { ($0.id, $0.name) } : [("claude", "Claude")]
                ForEach(accounts, id: \.0) { id, name in
                    HStack {
                        Text(accounts.count > 1 ? name : "Claude plan")
                        Spacer()
                        Text("$")
                        TextField("", value: Binding(get: { store.usage.planMonthly(for: id) }, set: { store.usage.setPlanMonthly($0, for: id) }),
                                  format: .number, prompt: Text("20"))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        Text("/ month").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What you pay")
            } footer: {
                Text("Only used on this Mac, for the value multiple on the dashboard (API value of your usage against what you pay).")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                Toggle("Check for updates automatically", isOn: Binding(get: { store.updater.automatic }, set: { store.updater.automatic = $0 }))
                HStack {
                    Text(updateText).foregroundStyle(store.updater.available == nil ? Color.secondary : Color.green)
                    Spacer()
                    if let u = store.updater.available {
                        Button("What's new") { showingUpdateNotes = true }
                            .popover(isPresented: $showingUpdateNotes, arrowEdge: .bottom) { UpdateNotes(release: u) }
                        Button("Skip") { store.updater.skip(u) }.help("Don't offer \(u.version) again")
                        Button(Updater.builtFromSource ? "How to update" : "Download \(u.version)") { UpdateNotes.act(on: u) }
                    } else {
                        Button(store.updater.checking ? "Checking…" : "Check now") { store.updater.check() }.disabled(store.updater.checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private let builtIns = [("claude", "Claude"), ("codex", "Codex"), ("gemini", "Gemini CLI"), ("antigravity", "Antigravity")]

    /// The built-in tools, with any other Claude account right after Claude, named as it appears elsewhere.
    private var toolList: [(String, String)] {
        let accounts = store.statuses.filter { $0.id.hasPrefix("claude-") }.map { ($0.id, $0.name) }
        let main = store.statuses.first { $0.id == "claude" }?.name ?? "Claude"
        return [("claude", main)] + accounts + builtIns.dropFirst()
    }

    private func toolRow(id: String, name: String) -> some View {
        let status = store.statuses.first { $0.id == id }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(name, isOn: binding(id, \.enabled))
                Spacer()
                Toggle("Alert", isOn: binding(id, \.alert)).toggleStyle(.checkbox)
            }
            if let status {
                Text(store.estimateNote(for: status).map { "\(status.source) · \($0)" } ?? status.source)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Automation

    private var automation: some View {
        Form {
            Section {
                ForEach(builtIns.filter { id, _ in canAutoStart(id) }, id: \.0) { id, name in autoStartRow(id: id, name: name) }
            } header: {
                Text("Auto-start")
            } footer: {
                Text("When a window Reset was watching runs out, it sends one short message two minutes later so the next window starts right away, even before you're back. Turning this on doesn't run it now. Skipped while a weekly limit is exhausted. Uses a little of your quota each time. The command it runs is under Advanced.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep this Mac awake", selection: Binding(get: { store.keepAwake.mode }, set: { store.keepAwake.mode = $0 })) {
                    ForEach(KeepAwake.Mode.allCases) { Text($0.label).tag($0) }
                }
                if store.keepAwake.mode != .off {
                    Text(store.keepAwake.isHolding ? "Keeping the Mac awake now." : "Not holding right now: the Mac is on battery.")
                        .font(.caption).foregroundStyle(store.keepAwake.isHolding ? Color.green : Color.secondary)
                }
            } header: {
                Text("Stay awake")
            } footer: {
                Text("Auto-start and on-time alerts need the Mac awake. This stops idle sleep only: the display still turns off as usual. Closing the lid still sleeps the Mac unless it's plugged in with an external display. Each auto-start also keeps the Mac awake for the few seconds it runs, on battery too. Phone alerts arrive either way.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func canAutoStart(_ id: String) -> Bool {
        store.statuses.first { $0.id == id }?.canAutoStart ?? (id != "gemini")
    }

    private func autoStartRow(id: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(name, isOn: binding(id, \.autoStart))
                .disabled(!store.prefs(for: id).enabled)
            if !store.prefs(for: id).enabled {
                Text("Switch \(name) on under General first.").font(.caption).foregroundStyle(.secondary)
            } else if let last = store.kickLog.last(where: { $0.id == id }) {
                HStack {
                    Text("Last run \(Fmt.when(last.time)): \(last.summary)")
                        .font(.caption).foregroundStyle(last.ok ? Color.secondary : Color.orange)
                    if id == "claude", store.autoStartNeedsSignIn {
                        Spacer()
                        Button(store.signingIn ? "Waiting for browser…" : "Sign in") { store.fixClaudeSignIn() }
                            .controlSize(.small).disabled(store.signingIn)
                    }
                }
            }
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        @Bindable var m = store.mascots
        return Form {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                    ForEach(Look.allCases) { look in
                        Button { store.look = look } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                LookCard(look: look, d: sampleCard, now: store.now)
                                    .frame(width: 340, height: 128)
                                    .scaleEffect(0.62, anchor: .topLeading)
                                    .frame(width: 211, height: 80, alignment: .topLeading)
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(store.look == look ? Color.accentColor : .clear, lineWidth: 2.5))
                                Text(look.name).font(.system(size: 12, weight: store.look == look ? .semibold : .regular))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Look")
            } footer: {
                Text("How each provider is drawn in the menu.").foregroundStyle(.secondary)
            }

            Section {
                Picker("Menu bar", selection: $menuBarStyle) {
                    Text("Colored pill").tag("pill")
                    Text("Text").tag("text")
                }
                Picker("Limits", selection: $store.limitsShown) {
                    ForEach(MenuBarGlance.Limits.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Colored pill: the countdown and what's left, orange as usual, red when the window is nearly empty or your pace runs out before the reset, green when a fresh window is waiting. Text: just the countdown.\n\nLimits: Weekly shows the weekly limit in the pill and the menu's rows instead of the session window, Both shows it underneath. Only where Reset can read a weekly limit; for Claude, that needs live usage.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show mascots", isOn: $m.enabled)
                Picker("Where they live", selection: $m.placement) {
                    ForEach(Placement.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!store.mascots.enabled)
                HStack {
                    Text("Size")
                    Slider(value: $m.size, in: 56...140, step: 4)
                }
                .disabled(!store.mascots.enabled)
                ForEach(MascotArt.providers.filter { id in store.statuses.contains { $0.id == id } }, id: \.self) { id in
                    Toggle(store.statuses.first { $0.id == id }?.name ?? id, isOn: Binding(
                        get: { !store.mascots.hidden.contains(id) },
                        set: { v in if v { store.mascots.hidden.remove(id) } else { store.mascots.hidden.insert(id) } }))
                        .toggleStyle(.checkbox)
                }
            } header: {
                Text("Mascots")
            } footer: {
                Text("Each mascot's mood and health bar follow how much of its window is left. Drag one to move it, right-click to change where they live. Mascots only show for tools switched on under General.\n\nThe mascots are unofficial fan art based on the Claude, OpenAI, Gemini and Antigravity logos. Those names and logos belong to Anthropic, OpenAI and Google, who have nothing to do with Reset.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advanced: some View {
        Form {
            Section {
                ForEach(builtIns.filter { id, _ in canAutoStart(id) }, id: \.0) { id, name in
                    TextField(name, text: Binding(get: { store.commands[id] ?? "" }, set: { store.commands[id] = $0 }))
                        .font(.system(size: 11, design: .monospaced))
                }
            } header: {
                Text("Auto-start commands")
            } footer: {
                Text("Run in a login shell when auto-start or Start now fires. The defaults send one word to the cheapest model without loading tools or MCP servers, so runs are quick.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("ntfy server", text: $store.ntfyServer)
            } header: {
                Text("Phone alert server")
            } footer: {
                Text("ntfy.sh unless you run your own.").foregroundStyle(.secondary)
            }

            Section {
                ForEach(store.custom) { c in
                    HStack {
                        Text(c.name)
                        Text("\(c.windowHours, specifier: "%g")h window").foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Alert", isOn: binding("custom-" + c.id, \.alert)).toggleStyle(.checkbox)
                        Button(role: .destructive) { store.custom.removeAll { $0.id == c.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name, e.g. ChatGPT", text: $newName)
                    Stepper("\(newHours, specifier: "%g")h", value: $newHours, in: 0.5...168, step: 0.5)
                        .frame(width: 110)
                    Button("Add") {
                        store.custom.append(CustomProvider(name: newName.trimmingCharacters(in: .whitespaces), windowHours: newHours))
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Other tools")
            } footer: {
                Text("For tools Reset cannot read on its own. Press Started now in the menu when you begin, and Reset counts down the window.")
                    .foregroundStyle(.secondary)
            }

            Section {
                integrationRow("Status line", "Your window, what's left and today's spend at the bottom of Claude Code",
                               state: statusLineState,
                               snippet: statusLineSnippet,
                               otherNote: "Claude Code shows another status line", busy: false) {
                    if case .other = statusLineState { confirmReplaceStatusLine = true } else { installStatusLine() }
                }
                integrationRow("MCP server", "Lets Claude check its own window and set pacing budgets",
                               state: mcpState,
                               snippet: "claude mcp add --scope user reset -- \"\(ClaudeIntegration.mcpPath)\"",
                               otherNote: "Set up for a copy of Reset somewhere else", busy: installingMCP) {
                    installingMCP = true
                    ClaudeIntegration.installMCP { error in
                        installingMCP = false
                        integrationMessage = error.map { "MCP server: \($0)" } ?? "MCP server added. It's available in new Claude Code sessions."
                        refreshIntegration()
                    }
                }
                if let m = integrationMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Claude Code integration")
            }
            .onAppear { refreshIntegration() }
            .confirmationDialog("Replace Claude Code's status line?", isPresented: $confirmReplaceStatusLine) {
                Button("Replace") { installStatusLine() }
            } message: {
                Text("Claude Code already runs another status line. Reset saves your settings as settings.json.before-reset first.")
            }

            Section {
                HStack {
                    Text("Setup guide")
                    Spacer()
                    Button("Run setup again") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "welcome")
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Something wrong?")
                        Text("Opens a GitHub issue with versions and on/off states filled in, never usage numbers, project names or your phone topic. You see it all before sending.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Report a problem…") { if let u = store.problemReportURL() { NSWorkspace.shared.open(u) } }
                }
                Text(store.usage.format.summary).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Activity") {
                    if store.log.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(Array(store.log.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11, design: .monospaced)) }
                }
            } header: {
                Text("Diagnostics")
            }

            Section("About") {
                HStack {
                    Text("Reset \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Link("Source on GitHub", destination: URL(string: ResetInfo.repoURL)!)
                }
                Text("Free and open source under the MIT license. Everything Reset reads stays on this Mac; it only sends something out for the optional live Claude usage check (to Anthropic), phone alerts (to your ntfy server) and update checks (to GitHub). Not affiliated with Anthropic, OpenAI or Google.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The status line setting as a line of JSON, for adding by hand.
    private var statusLineSnippet: String {
        let command = ClaudeIntegration.statusLineCommand.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"statusLine\": {\"type\": \"command\", \"command\": \"\(command)\"}"
    }

    /// A name given to a Claude account, saved as it's typed and applied on the next scan.
    private func accountName(_ id: String) -> Binding<String> {
        Binding(get: { ClaudeSource.customNames[id] ?? "" }, set: { v in
            var names = ClaudeSource.customNames
            names[id] = v.isEmpty ? nil : v
            UserDefaults.standard.set(names, forKey: "accountNames")
        })
    }

    private func refreshIntegration() {
        statusLineState = ClaudeIntegration.statusLineState()
        mcpState = ClaudeIntegration.mcpState()
    }

    private func installStatusLine() {
        do {
            try ClaudeIntegration.installStatusLine()
            integrationMessage = "Status line added. Claude Code picks it up in its next session."
        } catch {
            integrationMessage = "Status line: \(error.localizedDescription)"
        }
        refreshIntegration()
    }

    /// One Claude Code integration: whether it's set up, a button that sets it up, and the snippet to do it by hand.
    @State private var copiedSnippet: String?

    private func integrationRow(_ title: String, _ detail: String, state: ClaudeIntegration.State, snippet: String,
                                otherNote: String, busy: Bool, install: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                switch state {
                case .installed:
                    Label("Set up", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                case .missing:
                    Button(busy ? "Adding…" : "Add for me", action: install).controlSize(.small).disabled(busy)
                case .other:
                    Button(busy ? "Adding…" : "Use Reset's", action: install).controlSize(.small).disabled(busy)
                case .outdated:
                    Button("Update", action: install).controlSize(.small)
                }
                Button(copiedSnippet == snippet ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copiedSnippet = snippet
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedSnippet == snippet { copiedSnippet = nil } }
                }
                .controlSize(.small)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if case .other = state { Text(otherNote).font(.caption).foregroundStyle(.orange) }
            if state == .outdated {
                Text("An older version of Reset's line, which keeps showing the last countdown after Reset quits. Update fixes that.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if state != .installed {
                Text(snippet).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            }
        }
    }

    // MARK: Helpers

    private var updateText: String {
        if let u = store.updater.available { return "Reset \(u.version) is available" }
        if let e = store.updater.lastError { return e }
        if let d = store.updater.lastChecked { return "Up to date, checked \(Fmt.clock.string(from: d))" }
        return "Version \(Updater.current)"
    }

    private var sampleCard: CardData {
        if let c = store.statuses.first(where: { $0.id == "claude" }) { return store.cardData(for: c) }
        return CardData(id: "claude", name: "Claude", color: Theme.color(for: "claude"), resetsAt: Date().addingTimeInterval(6000), ready: false, used: 58)
    }

    private var liveText: String {
        switch store.liveClaude.state {
        case .off, .loading: return "Connecting…"
        case .ok(let d): return "Live · updated \(Fmt.clock.string(from: d))"
        case .problem(let why): return why
        }
    }
    private var liveIsProblem: Bool { if case .problem = store.liveClaude.state { return true }; return false }

    private func binding(_ id: String, _ key: WritableKeyPath<ProviderPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { store.prefs(for: id)[keyPath: key] },
                set: { v in store.setPrefs(id) { $0[keyPath: key] = v } })
    }
}
