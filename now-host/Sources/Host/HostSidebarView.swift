import SwiftUI

struct HostSidebarView: View {
    let registry: ModuleRegistry
    @ObservedObject var sidebar: SidebarPreferences
    let layout: NavigationLayout
    @ObservedObject var monitor: GuestStatusMonitor
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let openShelf: (NavigationShelf) -> Void
    let select: (NavigationSelection) -> Void
    @State private var drawerPresented = false

    var body: some View {
        SidebarNavigationCanvas(
            upperItems: layout.upper,
            lowerItems: layout.lower,
            registry: registry,
            status: monitor.status,
            compact: sidebar.compact,
            collapsed: sidebar.collapsed,
            selection: selection,
            shelfBeingRenamed: sidebar.shelfBeingRenamed,
            dragActions: dragActions,
            renameShelf: sidebar.renameShelf,
            cancelShelfCreation: sidebar.cancelShelfCreation,
            openShelf: openShelf,
            select: select)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModuleDrawerView(
                items: layout.drawer,
                registry: registry,
                status: monitor.status,
                compact: sidebar.compact,
                collapsed: sidebar.collapsed,
                selection: selection,
                isPresented: $drawerPresented,
                dragActions: dragActions,
                openShelf: openShelf,
                select: select)
                .nowGlassBar()
        }
        .navigationTitle("Modules")
        .modifier(SidebarWidth(collapsed: sidebar.collapsed))
        .contextMenu {
            SidebarDisplayMenu(sidebar: sidebar, registry: registry)
        }
        .onAppear {
            monitor.refresh()
            revealDrawerSelection()
        }
        .onChange(of: selection.destination) { _ in
            revealDrawerSelection()
        }
    }

    private func revealDrawerSelection() {
        if selection.requiresDrawerPresentation(in: layout) {
            drawerPresented = true
        }
    }
}

private struct SidebarDisplayMenu: View {
    @ObservedObject var sidebar: SidebarPreferences
    let registry: ModuleRegistry

    var body: some View {
        Picker("Rows", selection: $sidebar.compact) {
            Text("Full").tag(false)
            Text("Compact").tag(true)
        }
        .pickerStyle(.inline)
        Divider()
        Button(sidebar.collapsed ? "Show Module Names" : "Collapse to Icons") {
            sidebar.collapsed.toggle()
        }
        Button("Reset Layout") {
            sidebar.replaceLayout(.standard(for: registry))
        }
    }
}

private struct SidebarWidth: ViewModifier {
    let collapsed: Bool

    func body(content: Content) -> some View {
        if collapsed {
            /* The full-size unified titlebar places AppKit's traffic lights
               over the sidebar material. SwiftUI already expanded the old
               64-point request to roughly 96 points, where the split divider
               still clipped the zoom button. 120 points clears the native
               control cluster without leaving an oversized icon rail. */
            content.navigationSplitViewColumnWidth(120)
        } else {
            content.navigationSplitViewColumnWidth(min: 230, ideal: 265,
                                                   max: 320)
        }
    }
}

struct GuestSelectionMenu: View {
    @ObservedObject var listener: GuestListener
    let status: GuestStatus
    let collapsed: Bool
    let select: (GuestKey) -> Void
    let add: () -> Void

    var body: some View {
        Menu {
            if listener.guests.isEmpty {
                Text("No Guests Attached")
            } else {
                ForEach(listener.guests) { guest in
                    Button {
                        select(guest.key)
                    } label: {
                        if guest.isActive {
                            Label(guest.label, systemImage: "checkmark")
                        } else {
                            Text(guest.label)
                        }
                    }
                    .disabled(guest.isActive)
                }
            }
            Divider()
            Button("Add Guest…", action: add)
        } label: {
            if collapsed {
                GuestSelectionCompactLabel(status: status)
            } else {
                GuestSelectionLabel(name: activeLabel, status: status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help("Choose the guest every host module is attached to")
        .accessibilityLabel(
            Text("Selected guest: \(activeLabel)",
                 comment:
                    "Label for the toolbar menu that chooses the classic Mac controlled by this window."))
        .accessibilityValue(Text(status.menuLine))
    }

    private var activeLabel: String {
        listener.guests.first(where: \.isActive)?.label
            ?? "No Guest Attached"
    }
}

private struct GuestSelectionLabel: View {
    let name: String
    let status: GuestStatus

    var body: some View {
        HStack(spacing: 7) {
            GuestConnectionStatusDot(status: status)
            Text(name)
                .lineLimit(1)
        }
    }
}

private struct GuestSelectionCompactLabel: View {
    let status: GuestStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "desktopcomputer")
                .frame(width: 18, height: 18)
            GuestConnectionStatusDot(status: status)
                .background(Circle().fill(.background))
                .offset(x: 2, y: 2)
        }
    }
}

private struct GuestConnectionStatusDot: View {
    let status: GuestStatus

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.14),
                                      lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch status {
        case .notListening:
            Color(nsColor: .secondaryLabelColor)
        case .waiting:
            .orange
        case .connected:
            status.isQuiet ? .orange : .green
        case .failed:
            .red
        }
    }
}

extension GuestStatus {
    var machineShelfTitle: String {
        if case .connected(let name, _) = self { return name }
        return "No Mac Connected"
    }
}
