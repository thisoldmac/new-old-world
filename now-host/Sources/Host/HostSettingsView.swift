import SwiftUI

/// The pill-tab Settings surface. Appearance is the only tab that predates
/// this restructure; every other tab holds a preference MOVED here out of
/// a module view (or, for "New Connections", out of a literal constant —
/// see `ContinuityConnectionDefaults`). Each tab reaches the live model it
/// edits rather than a copy: Sidebar and Logs share the same instances the
/// rest of the app draws from (`sidebar`, `state.logs`), and MCP/Web reach
/// through `state.moduleRuntime(for:as:)` — the same accessor
/// `configureMCPTransports` already uses — so an edit here is visible in
/// the module immediately rather than only after a relaunch.
struct HostSettingsView: View {
    @ObservedObject var preferences: AppearancePreferences
    @ObservedObject var navigation: HostSettingsNavigation
    @ObservedObject var sidebar: SidebarPreferences
    @ObservedObject var state: HostAppState
    let registry: ModuleRegistry
    @StateObject private var continuityDefaults: ContinuityConnectionDefaultsModel
    @StateObject private var chatWorkspace = ChatWorkspaceSettingsModel()

    init(preferences: AppearancePreferences,
         navigation: HostSettingsNavigation,
         sidebar: SidebarPreferences,
         state: HostAppState,
         registry: ModuleRegistry,
         defaults: UserDefaults) {
        self.preferences = preferences
        self.navigation = navigation
        self.sidebar = sidebar
        self.state = state
        self.registry = registry
        _continuityDefaults = StateObject(wrappedValue:
            ContinuityConnectionDefaultsModel(defaults: defaults))
    }

    var body: some View {
        VStack(spacing: 0) {
            HostSettingsTabPill(selected: $navigation.selectedTab)
                .padding(.top, 14)
                .padding(.horizontal, 14)
            Divider()
                .padding(.top, 10)
            ScrollView {
                tab
                    .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .environment(\.nowLiquidGlassPreference, preferences.liquidGlass)
    }

    @ViewBuilder
    private var tab: some View {
        switch navigation.selectedTab {
        case .appearance:
            AppearanceSettingsSection(preferences: preferences)
        case .sidebar:
            SidebarSettingsSection(sidebar: sidebar, registry: registry)
        case .chat:
            ChatWorkspaceSettingsSection(model: chatWorkspace)
        case .mcp:
            if let model = state.moduleRuntime(
                for: MCPHostModule.definition.descriptor.id,
                as: MCPHostModuleRuntime.self)?.transportSettings {
                MCPSettingsSection(model: model)
            } else {
                SettingsUnavailableSection(
                    title: "MCP", reason: "MCP is unavailable.")
            }
        case .web:
            if let model = state.moduleRuntime(
                for: WebHostModule.definition.descriptor.id,
                as: WebHostModuleRuntime.self)?.model {
                WebSettingsSection(model: model)
            } else {
                SettingsUnavailableSection(
                    title: "Web", reason: "Web is unavailable.")
            }
        case .logs:
            LogsSettingsSection(model: state.logs)
        case .newConnections:
            NewConnectionDefaultsSection(model: continuityDefaults)
        }
    }
}

/// The pill switcher, reused from `FilesHostModePill`
/// (`FilesWorkspaceShell.swift`) — the working precedent U10 named for this
/// exact shape. Unlike that one there is no compact/icon-only mode: the
/// Settings window is not squeezed by a resizable split, so its own
/// `contentMinSize` is the only width constraint a tab label needs to clear.
private struct HostSettingsTabPill: View {
    @Binding var selected: HostSettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HostSettingsTab.allCases) { tab in
                Button { selected = tab } label: {
                    Text(tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: FilesStyle.controlHeight)
                        .contentShape(FilesStyle.controlShape)
                }
                .buttonStyle(.plain)
                .background {
                    FilesStyle.controlShape
                        .fill(selected == tab
                              ? Color.accentColor.opacity(0.22)
                              : Color.clear)
                }
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
                .accessibilityLabel(Text(tab.title))
            }
        }
        .padding(3)
        .nowGlassPanel(cornerRadius: FilesStyle.controlHeight)
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .clipShape(Capsule())
    }
}

// MARK: - Appearance

private struct AppearanceSettingsSection: View {
    @ObservedObject var preferences: AppearancePreferences

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                LiquidGlassSettings(preferences: preferences)
                GlassPreview()
            }
        }
        .formStyle(.grouped)
    }
}

private struct LiquidGlassSettings: View {
    @ObservedObject var preferences: AppearancePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Liquid Glass")
                Spacer()
                Text(preferences.liquidGlass.amount,
                     format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: glassAmount, in: 0...1)
                .accessibilityLabel("Liquid Glass")
                .accessibilityValue(Text(
                    preferences.liquidGlass.amount,
                    format: .percent.precision(.fractionLength(0))))
            HStack {
                Text("Off")
                Spacer()
                Text("Clear")
                Spacer()
                Text("Regular")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var glassAmount: Binding<Double> {
        Binding {
            preferences.liquidGlass.amount
        } set: { value in
            preferences.liquidGlass = LiquidGlassPreference(amount: value)
        }
    }
}

private struct GlassPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Window chrome")
                    .fontWeight(.medium)
                Text("Accessibility settings may replace glass with material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .nowGlassPanel(cornerRadius: 12)
    }
}

// MARK: - Sidebar

/// Moved from `HostSidebarView`'s right-click context menu (`SidebarDisplayMenu`,
/// removed there): the same "how the app itself looks" category as
/// Appearance, per U10's table, and a chrome preference is not really a
/// module's to hold. `sidebar` is the app delegate's own instance, so
/// changing "Rows" here redraws the real sidebar immediately.
private struct SidebarSettingsSection: View {
    @ObservedObject var sidebar: SidebarPreferences
    let registry: ModuleRegistry

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Rows", selection: $sidebar.compact) {
                    Text("Full").tag(false)
                    Text("Compact").tag(true)
                }
                Toggle("Collapse to Icons", isOn: $sidebar.collapsed)
                Button("Reset Layout") {
                    sidebar.replaceLayout(.standard(for: registry))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - MCP

/// Moved out of `MCPModuleView`'s two transport cards: launch-time policy,
/// checked rarely and never mid-session, so it does not need to live beside
/// the running/stopped state it no longer controls. The port field and
/// everything about what an agent has done stay in the module — this tab
/// is only the two switches App.swift reads at launch.
private struct MCPSettingsSection: View {
    @ObservedObject var model: MCPTransportSettingsModel

    var body: some View {
        Form {
            Section("MCP") {
                Toggle("Start Standard Input automatically",
                       isOn: $model.stdioStartsAutomatically)
                Toggle("Start HTTP automatically",
                       isOn: $model.httpStartsAutomatically)
                Text("Applies at next launch. Current transport state, "
                     + "socket and port are on the MCP page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Web

/// Moved out of `WebModuleView`'s "Page Compatibility" group box and its
/// service card's start-automatically toggle: rendering/compat mode is
/// set-once-and-forget, and the "(unsafe)" toggle in particular is exactly
/// the kind of buried control Settings exists to surface (U10 §2). The
/// relay's live status and Start/Stop buttons stay in the module.
private struct WebSettingsSection: View {
    @ObservedObject var model: WebBridgeModel

    var body: some View {
        Form {
            Section("Page Compatibility") {
                Picker("Browser", selection: $model.profile) {
                    ForEach(WebBrowserProfile.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Default view", selection: $model.lens) {
                    ForEach(WebRenderingLens.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Fetch engine", selection: $model.engine) {
                    ForEach(WebFetchEngine.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Toggle("Use known-site handlers",
                       isOn: $model.handlersEnabled)
                TextField("AI model folder or planner executable (optional)",
                          text: $model.aiPlannerExecutable)
                Text("A model folder uses the optional MLX adapter. "
                     + "Compatible Page is the fallback; AI may "
                     + "reorder original blocks, but cannot write links "
                     + "or text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Allow private and local web destinations (unsafe)",
                       isOn: $model.allowPrivateDestinations)
            }
            Section("Service") {
                Toggle("Start automatically", isOn: $model.startsAutomatically)
                Text("Applies at next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logs

/// Moved out of `LogsModuleView`'s header switches: a disk-writing
/// preference, unlike `Invert`, which stays beside the scrollback it
/// repaints. `model` is `state.logs` — the one eager, app-owned instance —
/// so this is the exact same switch the module page reads, not a copy.
private struct LogsSettingsSection: View {
    @ObservedObject var model: LogsModel

    var body: some View {
        Form {
            Section("Logs") {
                Toggle("Log to disk", isOn: Binding(
                    get: { model.persistsToDisk },
                    set: { model.setPersistsToDisk($0) }))
                Text("Written beside this Mac's event log. The file's "
                     + "path appears on the Logs page once enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Defaults for new connections

/// **What a Mac gets on first connect, before it has any settings of its
/// own.** The per-machine values themselves stay entirely in-module, on
/// the Continuity page — this tab holds only the seed a never-before-seen
/// machine falls back to (`ContinuityConnectionDefaults`).
///
/// Mirror's own per-machine defaults (`MirrorPlanePolicyStore`, behind the
/// Finder-emulation "Development controls" on the Mirror page) are
/// deliberately NOT here: that surface is explicitly still evolving and
/// stays in-module and messy for now, a decision this tab respects rather
/// than quietly overriding by giving it a polished home.
private struct NewConnectionDefaultsSection: View {
    @ObservedObject var model: ContinuityConnectionDefaultsModel

    var body: some View {
        Form {
            Section("Continuity") {
                Text("Defaults for a Mac that has never connected. After "
                     + "a first connection, per-machine settings on the "
                     + "Continuity page take over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Update rate", selection: $model.rate) {
                    Text("15 Hz").tag(15)
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                }
                Toggle("Reconnect after interruption",
                       isOn: $model.autoReconnect)
                Stepper(value: $model.reconnectDelay, in: 0.1...5.0,
                       step: 0.1) {
                    Text("Reconnect delay: "
                         + String(format: "%.1fs", model.reconnectDelay))
                }
                .disabled(!model.autoReconnect)
                Toggle("Send keyboard input to guest",
                       isOn: $model.keyboardForwarding)
                Picker("Return all controls", selection: $model.escapeShortcut) {
                    ForEach(ContinuityEscapeShortcut.allCases) { shortcut in
                        Text(shortcut.label).tag(shortcut)
                    }
                }
                ForEach(ContinuityOptionCatalog.all) { option in
                    Toggle(option.label, isOn: model.optionBinding(option))
                        .help(option.detail)
                }
            }
            Section("Mirror") {
                Text("Mirror's Finder-emulation controls remain per-Mac "
                     + "only, on the Mirror page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Chat

/// The workspace lane's one control surface.
///
/// It reads as heavier than the tabs around it on purpose. Every other
/// preference in this window changes how New Old World behaves; this one
/// hands a model a folder on this Mac and, at the upper tier, the ability
/// to run commands in it. The sentences are the grant, not decoration —
/// somebody who turns this on should have read what it is.
private struct ChatWorkspaceSettingsSection: View {
    @ObservedObject var model: ChatWorkspaceSettingsModel

    var body: some View {
        Form {
            Section("Chat Workspace") {
                Text("Chat reaches only the connected classic machine, "
                     + "through tools this app owns and logs. A workspace "
                     + "adds file and command tools for the Claude runtime "
                     + "in ONE folder on this Mac, so a chat can read, "
                     + "build and test source — including New Old World's "
                     + "own. Those tools are governed by the mode below "
                     + "and that folder's policy, not by this app's "
                     + "per-tool consent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isOn {
                    /* Visible only after an explicit Turn Off: building
                       is on out of the box (the owner's 2026-08-19
                       decision), so this row is the way back, not a
                       setup step. */
                    HStack {
                        Text("Building is turned off. Turn it back on and "
                             + "Claude builds software for the classic "
                             + "machine in New Old World's own workspace "
                             + "on this Mac.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Turn On") { model.allowDefaultWorkspace() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(folderLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(model.isOn ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { choose() }
                    if model.isOn {
                        Button("Turn Off") { model.choose(nil) }
                    }
                }
                if case .unusable(let reason) = model.state {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("The chat may", selection: $model.permission) {
                    ForEach(ChatWorkspaceLane.Permission.allCases,
                            id: \.rawValue) { permission in
                        Text(permission.label).tag(permission)
                    }
                }
                .disabled(!model.isOn)
                Toggle("Also give it New Old World's own tools",
                       isOn: $model.attachesNOWTools)
                    .disabled(!model.isOn)
                    .help("The runtime reaches the connected machine "
                          + "through this app's MCP face, so the same turn "
                          + "can change source and drive the machine.")
                Text("Running commands covers builds, tests and deploys, "
                     + "and it is the tier where a mistake is no longer "
                     + "just a diff. Models chosen from other providers "
                     + "are unaffected by this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Instructions") {
                Text("Standing instructions, added to every conversation "
                     + "whichever model answers — tone, priorities, house "
                     + "rules. They cannot widen what a turn may touch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $model.instructions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72, maxHeight: 160)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
    }

    private var folderLabel: String {
        switch model.state {
        case .ready(let lane): return lane.root.path
        case .unusable: return "unavailable"
        case .off: return "none — chat is machine-only"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder a chat may read, edit and build in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.choose(url)
    }
}

// MARK: - Unavailable

private struct SettingsUnavailableSection: View {
    let title: String
    let reason: String

    var body: some View {
        Form {
            Section(title) {
                Text(reason).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
