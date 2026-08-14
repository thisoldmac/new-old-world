import SwiftUI

struct ModuleDrawerView: View {
    let items: [NavigationItem]
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    @Binding var isPresented: Bool
    let dragActions: SidebarNavigationDragActions
    var openShelf: ((NavigationShelf) -> Void)? = nil
    let select: (NavigationSelection) -> Void

    private var summary: NavigationDrawerSummary {
        NavigationDrawerSummary(items: items)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                    if !collapsed {
                        Text("Drawer")
                            .font(.caption.weight(.medium))
                    }
                    if summary.moduleCount > 0 {
                        Text(String(summary.moduleCount))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 16)
                            .background(Capsule().fill(Color.accentColor))
                            .accessibilityLabel(
                                "\(summary.moduleCount) modules in drawer")
                    }
                    if summary.containsNetworkShelf {
                        DrawerConnectionStatusDot(status: status)
                    }
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Modules Drawer")
            .overlay(SidebarNativeDragSurface(
                payload: nil,
                target: .zone(.drawer, index: items.endIndex),
                canDrop: dragActions.canDrop,
                previewDrop: dragActions.previewDrop,
                performDrop: dragActions.performDrop,
                activate: { isPresented.toggle() },
                springLoad: { isPresented = true }))
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                drawerContents
            }
        }
        .padding(.horizontal, collapsed ? 6 : 10)
        .padding(.vertical, 5)
    }

    private var drawerContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Modules Drawer", systemImage: "archivebox")
                    .font(.headline)
                Spacer()
                if summary.containsNetworkShelf {
                    DrawerConnectionStatusDot(status: status)
                }
            }

            if items.isEmpty {
                Text("Drag modules here to put them away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        SidebarNavigationItems(
                            items: items,
                            zone: .drawer,
                            registry: registry,
                            status: status,
                            compact: compact,
                            collapsed: false,
                            selection: selection,
                            dragActions: dragActions,
                            openShelf: openShelf,
                            select: select)
                    }
                    .padding(4)
                    .animation(.easeInOut(duration: 0.16), value: items)
                }
                .frame(minHeight: 100, maxHeight: 420)
            }
        }
        .padding(12)
        .frame(width: 280)
        .nowGlassPanel()
    }
}

private struct DrawerConnectionStatusDot: View {
    let status: GuestStatus

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .help(status.menuLine)
            .accessibilityLabel("Connections: \(status.menuLine)")
    }

    private var tint: Color {
        switch status {
        case .notListening: .secondary
        case .waiting: .orange
        case .connected: status.isQuiet ? .orange : .green
        case .failed: .red
        }
    }
}
