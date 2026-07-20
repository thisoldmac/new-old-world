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
        if !registry.footerModules.isEmpty {
            SidebarFooter(modules: registry.footerModules,
                          monitor: state.guestStatus,
                          selectedID: state.selectedModuleID) { id in
                state.selectedModuleID = id
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
        case "console":
            ConsoleModuleView(model: state.console, listener: state.listener)
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
                    Text(status.sidebarLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: indicator.symbol)
                    .font(.caption2)
                    .foregroundStyle(indicator.tint)
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
        .help(status.menuLine)
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
