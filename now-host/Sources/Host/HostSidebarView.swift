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
            content.navigationSplitViewColumnWidth(64)
        } else {
            content.navigationSplitViewColumnWidth(min: 230, ideal: 265,
                                                   max: 320)
        }
    }
}

struct GuestSelectionMenu: View {
    @ObservedObject var listener: GuestListener
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
                Image(systemName: "desktopcomputer")
                    .frame(width: 18, height: 18)
            } else {
                Label {
                    Text(activeLabel)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help("Choose the guest every host module is attached to")
    }

    private var activeLabel: String {
        listener.guests.first(where: \.isActive)?.label
            ?? "No Guest Attached"
    }
}

extension GuestStatus {
    var machineShelfTitle: String {
        if case .connected(let name, _) = self { return name }
        return "No Mac Connected"
    }
}
