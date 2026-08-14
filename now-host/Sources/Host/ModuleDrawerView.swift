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
    @State private var isHovering = false

    private var summary: NavigationDrawerSummary {
        NavigationDrawerSummary(items: items)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if collapsed {
                    Image(systemName: "archivebox")
                } else {
                    Label("Drawer", systemImage: "archivebox")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                if summary.moduleCount > 0 {
                    Text(String(summary.moduleCount))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .accessibilityLabel(
                            "\(summary.moduleCount) modules in drawer")
                }
                if summary.containsNetworkShelf {
                    DrawerConnectionStatusDot(status: status)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28,
                   alignment: collapsed ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering
                      ? Color(nsColor: .selectedContentBackgroundColor)
                          .opacity(0.10)
                      : .clear))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Modules Drawer")
        .overlay(SidebarNativeDragSurface(
            payload: nil,
            target: .zone(.drawer, index: items.endIndex),
            canDrop: dragActions.canDrop,
            previewDrop: dragActions.previewDrop,
            performDrop: dragActions.performDrop,
            activate: { isPresented.toggle() },
            springLoad: { isPresented = true },
            hoverChanged: { isHovering = $0 }))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            drawerContents
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
