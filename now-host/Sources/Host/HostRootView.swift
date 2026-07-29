import SwiftUI

struct HostRootView: View {
    let registry: ModuleRegistry
    @ObservedObject var state: HostAppState

    var body: some View {
        NavigationSplitView {
            List(registry.listModules, selection: listSelection) { module in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                        Text(module.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: module.symbol)
                }
                .tag(module.id)
                .padding(.vertical, 4)
            }
            .navigationTitle("Modules")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            // An inset rather than a VStack around the List, so the footer
            // sits inside the sidebar's material instead of on top of it.
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            GuestPicker(listener: state.listener) { key in
                state.selectGuest(key)
            }
            if !registry.footerModules.isEmpty {
                SidebarFooter(modules: registry.footerModules,
                              monitor: state.guestStatus,
                              selectedID: state.selectedModuleID) { id in
                    state.selectedModuleID = id
                }
            }
        }
    }

    /// The List only knows about the modules it draws; a footer selection
    /// reads as no selection to it, so it does not leave a second row
    /// highlighted behind the one a person actually picked.
    private var listSelection: Binding<String?> {
        Binding {
            registry.footerModules.contains { $0.id == state.selectedModuleID }
                ? nil : state.selectedModuleID
        } set: { picked in
            if let picked { state.selectedModuleID = picked }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedModuleID {
        case "screenshots":
            ScreenshotsModuleView(model: state.screenshots)
        case "files":
            FilesModuleView(model: state.files)
        case "processes":
            ProcessesModuleView(model: state.processes)
        case "console":
            ConsoleModuleView(model: state.console, listener: state.listener)
        case "census":
            CensusModuleView(model: state.census)
        case "software":
            SoftwareModuleView(model: state.software)
        case "logs":
            LogsModuleView(model: state.logs, log: state.logs.log)
        case "settings":
            SettingsModuleView(settings: state.settings,
                               listener: state.listener,
                               onStart: { state.startListening() },
                               onStop: { state.stopListening() })
        default:
            VStack(spacing: 10) {
                Image(systemName: "questionmark.app")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Module Unavailable")
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Which Mac the window is driving, when there is a choice.
///
/// A pop-up button, which is `Picker` under `.menu` — the stock AppKit
/// control for "one of a short list", drawn by the system rather than
/// rebuilt out of rows here. The alternative, a second list of machines
/// above the modules, would have said the same thing in more pixels and
/// invented a selection idiom the rest of the OS does not use.
///
/// **It appears only when there are two.** With one machine connected the
/// popup would offer a choice that is not a choice, and the footer's status
/// line already names it; with none there is nothing to name. The row is
/// therefore evidence in itself: seeing it means a second Mac is on the
/// wire, which is the fact a person most needs when a command lands
/// somewhere surprising.
struct GuestPicker: View {
    @ObservedObject var listener: GuestListener
    let select: (GuestKey) -> Void

    var body: some View {
        if listener.guests.count > 1 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Driving", selection: selection) {
                        ForEach(listener.guests) { guest in
                            /* Handle, then what the machine calls itself.
                               Two Macs may report the same name — that is
                               the case the old identity could not serve at
                               all — so the row a person clicks must carry
                               the thing that tells them apart. */
                            Text(guest.label).tag(GuestKey?.some(guest.key))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .help("Every command, module and capture request goes to "
                      + "the Mac chosen here. The others stay connected.")
            }
        }
    }

    /// Reads the roster rather than a stored choice: the active guest is
    /// the listener's fact, and a picker holding its own copy would go on
    /// showing a machine that had disconnected.
    private var selection: Binding<GuestKey?> {
        Binding {
            listener.guests.first(where: \.isActive)?.key
        } set: { picked in
            if let picked { select(picked) }
        }
    }
}

/// Holds the one subscription the footer needs, so the rows below stay pure
/// values — cheap to render anywhere, including a snapshot test.
struct SidebarFooter: View {
    let modules: [ModuleDescriptor]
    @ObservedObject var monitor: GuestStatusMonitor
    let selectedID: String
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 2) {
                ForEach(modules) { module in
                    FooterModuleRow(module: module,
                                    status: monitor.status,
                                    isSelected: selectedID == module.id) {
                        select(module.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear { monitor.refresh() }
    }
}

/// A footer row reads as status first: the title, then whatever the wire is
/// doing right now, then a dot in the same colours the modules use for it.
struct FooterModuleRow: View {
    let module: ModuleDescriptor
    let status: GuestStatus
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: module.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                // Only the link's own row carries the live status dot.
                if module.showsLinkStatus {
                    Image(systemName: indicator.symbol)
                        .font(.caption2)
                        .foregroundStyle(indicator.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // The caption is abbreviated to fit; the tooltip is the full line.
        .help(module.showsLinkStatus ? status.menuLine : module.summary)
    }

    /// The link's row reads as status; any other footer module reads as
    /// what it is.
    private var subtitle: String {
        module.showsLinkStatus ? status.sidebarLine : module.summary
    }

    /// The same dot vocabulary the modules use in their own headers.
    private var indicator: (symbol: String, tint: Color) {
        switch status {
        case .notListening:
            return ("circle", .secondary)
        case .waiting:
            return ("circle.dotted", .orange)
        case .connected:
            return ("circle.fill", status.isQuiet ? .orange : .green)
        case .failed:
            return ("exclamationmark.triangle", .red)
        }
    }
}
