import SwiftUI

struct HostSidebarView: View {
    let registry: ModuleRegistry
    @ObservedObject var sidebar: SidebarPreferences
    @ObservedObject var listener: GuestListener
    @ObservedObject var monitor: GuestStatusMonitor
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let selectGuest: (GuestKey) -> Void
    let select: (NavigationSelection) -> Void
    @State private var drawerPresented = false

    var body: some View {
        List {
            SidebarNavigationItems(
                items: sidebar.layout.upper,
                zone: .upper,
                registry: registry,
                status: monitor.status,
                compact: sidebar.compact,
                collapsed: sidebar.collapsed,
                selection: selection,
                dragActions: dragActions,
                select: select)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HostSidebarHeader(
                listener: listener,
                collapsed: sidebar.collapsed,
                toggleCollapsed: { sidebar.collapsed.toggle() },
                selectGuest: selectGuest,
                showConnections: {
                    select(NavigationSelection.selecting(
                        moduleID: "settings", in: sidebar.layout))
                })
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarUtilityArea(
                items: sidebar.layout.lower,
                drawerItems: sidebar.layout.drawer,
                registry: registry,
                status: monitor.status,
                compact: sidebar.compact,
                collapsed: sidebar.collapsed,
                selection: selection,
                drawerPresented: $drawerPresented,
                dragActions: dragActions,
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
        if selection.requiresDrawerPresentation(in: sidebar.layout) {
            drawerPresented = true
        }
    }
}

private struct HostSidebarHeader: View {
    @ObservedObject var listener: GuestListener
    let collapsed: Bool
    let toggleCollapsed: () -> Void
    let selectGuest: (GuestKey) -> Void
    let showConnections: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Button(action: toggleCollapsed) {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(collapsed
                      ? "Show module names"
                      : "Collapse the sidebar to icons")
                .accessibilityLabel(collapsed
                                    ? "Show module names"
                                    : "Collapse sidebar to icons")
                Spacer(minLength: 0)
            }
            SidebarGuestMenu(
                listener: listener,
                collapsed: collapsed,
                select: selectGuest,
                add: showConnections)
        }
        .padding(.horizontal, collapsed ? 8 : 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .nowGlassBar()
    }
}

private struct SidebarUtilityArea: View {
    let items: [NavigationItem]
    let drawerItems: [NavigationItem]
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    @Binding var drawerPresented: Bool
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            SidebarNavigationItems(
                items: items,
                zone: .lower,
                registry: registry,
                status: status,
                compact: true,
                collapsed: collapsed,
                selection: selection,
                dragActions: dragActions,
                select: select)
                .padding(.horizontal, collapsed ? 4 : 8)
                .padding(.top, 4)

            ModuleDrawerView(
                items: drawerItems,
                registry: registry,
                status: status,
                compact: compact,
                collapsed: collapsed,
                selection: selection,
                isPresented: $drawerPresented,
                dragActions: dragActions,
                select: select)
        }
    }
}

struct SidebarNavigationDragActions {
    let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
}

struct SidebarNavigationItems: View {
    let items: [NavigationItem]
    let zone: NavigationZone
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            SidebarNavigationListRow(
                index: index,
                isLast: index == items.index(before: items.endIndex),
                item: item,
                zone: zone,
                registry: registry,
                status: status,
                compact: compact,
                collapsed: collapsed,
                selection: selection,
                dragActions: dragActions,
                select: select)
                .listRowInsets(EdgeInsets(top: 3, leading: 7,
                                          bottom: 3, trailing: 7))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if items.isEmpty {
            SidebarNavigationDropSlot(
                target: .zone(zone, index: 0),
                dragActions: dragActions)
        }
    }
}

private struct SidebarNavigationListRow: View {
    let index: Int
    let isLast: Bool
    let item: NavigationItem
    let zone: NavigationZone
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        SidebarNavigationItemView(
            item: item,
            registry: registry,
            status: status,
            compact: compact,
            collapsed: collapsed,
            selection: selection,
            dragActions: dragActions,
            select: select)
            .overlay(alignment: .top) {
                SidebarNavigationDropSlot(
                    target: .zone(zone, index: index),
                    dragActions: dragActions)
                    .offset(y: -5)
            }
            .overlay(alignment: .bottom) {
                if isLast {
                    SidebarNavigationDropSlot(
                        target: .zone(zone, index: index + 1),
                        dragActions: dragActions)
                        .offset(y: 5)
                }
            }
    }
}

private struct SidebarNavigationDropSlot: View {
    let target: NavigationDropTarget
    let dragActions: SidebarNavigationDragActions

    var body: some View {
        Color.clear
            .frame(height: 10)
            .overlay(SidebarNativeDragSurface(
                payload: nil,
                target: target,
                canDrop: dragActions.canDrop,
                performDrop: dragActions.performDrop))
    }
}

private struct SidebarNavigationItemView: View {
    let item: NavigationItem
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        switch item {
        case .module(let moduleID):
            if let module = registry.module(id: moduleID) {
                let moduleSelection = NavigationSelection
                    .selectingLooseModule(moduleID)
                SidebarLooseModuleRow(
                    module: module,
                    compact: compact,
                    collapsed: collapsed,
                    isSelected: selection.destination == .module(moduleID)) {
                        select(moduleSelection)
                    }
                    .overlay(SidebarNativeDragSurface(
                        payload: .module(moduleID),
                        target: .module(moduleID),
                        canDrop: dragActions.canDrop,
                        performDrop: dragActions.performDrop,
                        activate: {
                            select(moduleSelection)
                        }))
            }
        case .shelf(let shelf):
            SidebarShelfRow(
                shelf: shelf,
                status: status,
                collapsed: collapsed,
                selection: selection,
                dragActions: dragActions,
                select: select)
        }
    }
}

private struct SidebarLooseModuleRow: View {
    let module: ModuleDescriptor
    let compact: Bool
    let collapsed: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            if collapsed {
                SidebarNavigationIcon(symbol: module.symbol,
                                      isSelected: isSelected)
                    .frame(maxWidth: .infinity, minHeight: 32)
            } else {
                HStack(spacing: 10) {
                    SidebarNavigationIcon(symbol: module.symbol,
                                          isSelected: isSelected)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                        if !compact {
                            Text(module.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, compact ? 7 : 9)
            }
        }
        .buttonStyle(.plain)
        .background(SidebarNavigationRowBackground(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(module.title)
        .help(collapsed || compact ? module.summary : "")
    }

}

private struct SidebarShelfRow: View {
    let shelf: NavigationShelf
    let status: GuestStatus
    let collapsed: Bool
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        let shelfSelection = NavigationSelection.selectingHero(of: shelf)
        let isSelected = selection.containingShelfID == shelf.id
        Button { select(shelfSelection) } label: {
            if collapsed {
                ZStack(alignment: .topTrailing) {
                    SidebarNavigationIcon(symbol: symbol,
                                          isSelected: isSelected)
                        .frame(maxWidth: .infinity, minHeight: 32)
                    if shelf.id == .network {
                        ConnectionStatusDot(status: status)
                            .scaleEffect(0.72)
                            .offset(x: 4, y: -3)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    SidebarNavigationIcon(symbol: symbol,
                                          isSelected: isSelected)
                    Text(title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if shelf.id == .network {
                        ConnectionStatusDot(status: status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .buttonStyle(.plain)
        .background(SidebarNavigationRowBackground(isSelected: isSelected))
        .accessibilityAddTraits(
            selection.containingShelfID == shelf.id ? [.isSelected] : [])
        .accessibilityLabel(title)
        .help(title)
        .overlay(SidebarNativeDragSurface(
            payload: .shelf(shelf.id),
            target: .shelf(shelf.id, beforeModuleID: nil),
            canDrop: dragActions.canDrop,
            performDrop: dragActions.performDrop,
            activate: { select(shelfSelection) }))
    }

    private var title: String {
        switch shelf.id {
        case .machine: status.machineShelfTitle
        case .screen: "Screen"
        case .files: "Files"
        case .network: "Connections"
        case .user: shelf.title ?? "Shelf"
        }
    }

    private var symbol: String {
        switch shelf.id {
        case .machine: "desktopcomputer"
        case .screen: "rectangle.on.rectangle"
        case .files: "folder"
        case .network: "network"
        case .user: "square.stack.3d.up"
        }
    }
}

private struct SidebarNavigationIcon: View {
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 22, height: 22)
    }
}

private struct SidebarNavigationRowBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected
                  ? Color.accentColor.opacity(0.17)
                  : Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.055),
                                  lineWidth: 0.5)
            }
    }
}

private struct ConnectionStatusDot: View {
    let status: GuestStatus

    var body: some View {
        Image(systemName: indicator.symbol)
            .font(.caption2)
            .foregroundStyle(indicator.tint)
            .help(status.menuLine)
    }

    private var indicator: (symbol: String, tint: Color) {
        switch status {
        case .notListening: ("circle", .secondary)
        case .waiting: ("circle.dotted", .orange)
        case .connected: ("circle.fill", status.isQuiet ? .orange : .green)
        case .failed: ("exclamationmark.triangle", .red)
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

struct SidebarGuestMenu: View {
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
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text(activeLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 26,
                       alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .menuStyle(.borderlessButton)
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
