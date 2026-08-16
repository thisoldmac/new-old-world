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
                Text("Accessibility settings can replace glass with material.")
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
                Text("Applies the next time New Old World launches. The "
                     + "MCP page shows whether each transport is running "
                     + "now and its socket or port.")
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
                     + "Compatible Page is always the fallback; AI may "
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
                Text("Applies the next time New Old World launches.")
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
                Text("Written beside this Mac's own event log. The Logs "
                     + "page shows the file's path once this is on.")
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
                Text("A Mac that has never connected before starts with "
                     + "these values. Once it has connected, its own "
                     + "settings live on the Continuity page and these no "
                     + "longer apply to it.")
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
                Text("Mirror's Finder-emulation controls are still "
                     + "evolving and remain per-Mac only, on the Mirror "
                     + "page — they are not part of this restructure yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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
