import SwiftUI

struct SidebarNavigationCanvas: View {
    let upperItems: [NavigationItem]
    let lowerItems: [NavigationItem]
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let shelfBeingRenamed: NavigationShelfID?
    let dragActions: SidebarNavigationDragActions
    let renameShelf: (NavigationShelfID, String) -> Void
    let cancelShelfCreation: (NavigationShelfID) -> Void
    let openShelf: (NavigationShelf) -> Void
    let select: (NavigationSelection) -> Void

    var body: some View {
        GeometryReader { geometry in
            SidebarCanvasDropHost(
                upperItemCount: upperItems.count,
                lowerItemCount: lowerItems.count,
                dragActions: dragActions) {
                    List {
                        SidebarNavigationItems(
                            items: upperItems,
                            zone: .upper,
                            registry: registry,
                            status: status,
                            compact: compact,
                            collapsed: collapsed,
                            selection: selection,
                            renamingShelfID: shelfBeingRenamed,
                            dragActions: dragActions,
                            renameShelf: renameShelf,
                            cancelShelfCreation: cancelShelfCreation,
                            openShelf: openShelf,
                            select: select)
                    }
                    .listStyle(.sidebar)
                    .animation(.easeInOut(duration: 0.16), value: upperItems)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        SidebarPinnedStack(
                            items: lowerItems,
                            registry: registry,
                            status: status,
                            compact: compact,
                            collapsed: collapsed,
                            selection: selection,
                            renamingShelfID: shelfBeingRenamed,
                            dragActions: dragActions,
                            renameShelf: renameShelf,
                            cancelShelfCreation: cancelShelfCreation,
                            openShelf: openShelf,
                            select: select)
                    }
                }
                .frame(width: geometry.size.width,
                       height: geometry.size.height)
        }
    }
}

private struct SidebarPinnedStack: View {
    let items: [NavigationItem]
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let renamingShelfID: NavigationShelfID?
    let dragActions: SidebarNavigationDragActions
    let renameShelf: (NavigationShelfID, String) -> Void
    let cancelShelfCreation: (NavigationShelfID) -> Void
    let openShelf: (NavigationShelf) -> Void
    let select: (NavigationSelection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            SidebarNavigationItems(
                items: items,
                zone: .lower,
                registry: registry,
                status: status,
                compact: compact,
                collapsed: collapsed,
                selection: selection,
                renamingShelfID: renamingShelfID,
                dragActions: dragActions,
                renameShelf: renameShelf,
                cancelShelfCreation: cancelShelfCreation,
                openShelf: openShelf,
                select: select)
                .padding(.horizontal, collapsed ? 4 : 8)
                .padding(.vertical, 5)
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.16), value: items)
    }
}

struct SidebarNavigationDragActions {
    let canDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let previewDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let performDrop: (NavigationDraggedItem, NavigationDropTarget) -> Bool
    let dragEnded: (NavigationDraggedItem) -> Void
}

struct SidebarNavigationItems: View {
    let items: [NavigationItem]
    let zone: NavigationZone
    let registry: ModuleRegistry
    let status: GuestStatus
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    var renamingShelfID: NavigationShelfID? = nil
    let dragActions: SidebarNavigationDragActions
    var renameShelf: (NavigationShelfID, String) -> Void = { _, _ in }
    var cancelShelfCreation: (NavigationShelfID) -> Void = { _ in }
    var openShelf: ((NavigationShelf) -> Void)? = nil
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
                renamingShelfID: renamingShelfID,
                dragActions: dragActions,
                renameShelf: renameShelf,
                cancelShelfCreation: cancelShelfCreation,
                openShelf: openShelf,
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
    let renamingShelfID: NavigationShelfID?
    let dragActions: SidebarNavigationDragActions
    let renameShelf: (NavigationShelfID, String) -> Void
    let cancelShelfCreation: (NavigationShelfID) -> Void
    let openShelf: ((NavigationShelf) -> Void)?
    let select: (NavigationSelection) -> Void

    var body: some View {
        SidebarNavigationItemView(
            item: item,
            registry: registry,
            status: status,
            compact: compact,
            collapsed: collapsed,
            selection: selection,
            renamingShelfID: renamingShelfID,
            dragActions: dragActions,
            renameShelf: renameShelf,
            cancelShelfCreation: cancelShelfCreation,
            openShelf: openShelf,
            select: select)
            .overlay(alignment: .top) {
                SidebarNavigationDropSlot(
                    target: .zone(zone, index: index),
                    dragActions: dragActions)
                    .offset(y: -10)
            }
            .overlay(alignment: .bottom) {
                if isLast {
                    SidebarNavigationDropSlot(
                        target: .zone(zone, index: index + 1),
                        dragActions: dragActions)
                        .offset(y: 10)
                }
            }
    }
}

private struct SidebarNavigationDropSlot: View {
    let target: NavigationDropTarget
    let dragActions: SidebarNavigationDragActions

    var body: some View {
        Color.clear
            .frame(height: 20)
            .overlay(SidebarNativeDragSurface(
                payload: nil,
                target: target,
                canDrop: dragActions.canDrop,
                previewDrop: dragActions.previewDrop,
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
    let renamingShelfID: NavigationShelfID?
    let dragActions: SidebarNavigationDragActions
    let renameShelf: (NavigationShelfID, String) -> Void
    let cancelShelfCreation: (NavigationShelfID) -> Void
    let openShelf: ((NavigationShelf) -> Void)?
    let select: (NavigationSelection) -> Void
    @State private var isHovering = false

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
                    isSelected: selection.destination == .module(moduleID),
                    isHovering: isHovering) {
                        select(moduleSelection)
                    }
                    .overlay(SidebarNativeDragSurface(
                        payload: .module(moduleID),
                        target: .module(moduleID),
                        canDrop: dragActions.canDrop,
                        previewDrop: dragActions.previewDrop,
                        performDrop: dragActions.performDrop,
                        dragEnded: dragActions.dragEnded,
                        activate: {
                            select(moduleSelection)
                        },
                        hoverChanged: { isHovering = $0 }))
            }
        case .shelf(let shelf):
            SidebarShelfRow(
                shelf: shelf,
                status: status,
                registry: registry,
                compact: compact,
                collapsed: collapsed,
                selection: selection,
                isRenaming: renamingShelfID == shelf.id,
                dragActions: dragActions,
                renameShelf: renameShelf,
                cancelShelfCreation: cancelShelfCreation,
                openShelf: openShelf,
                select: select)
        }
    }
}

private struct SidebarLooseModuleRow: View {
    let module: ModuleDescriptor
    let compact: Bool
    let collapsed: Bool
    let isSelected: Bool
    let isHovering: Bool
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
        .foregroundStyle(isSelected
                         ? Color(nsColor: .alternateSelectedControlTextColor)
                         : Color.primary)
        .background(SidebarNavigationRowBackground(
            kind: .module,
            isSelected: isSelected,
            isHovering: isHovering))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(module.title)
        .help(collapsed || compact ? module.summary : "")
    }

}

private struct SidebarShelfRow: View {
    let shelf: NavigationShelf
    let status: GuestStatus
    let registry: ModuleRegistry
    let compact: Bool
    let collapsed: Bool
    let selection: NavigationSelection
    let isRenaming: Bool
    let dragActions: SidebarNavigationDragActions
    let renameShelf: (NavigationShelfID, String) -> Void
    let cancelShelfCreation: (NavigationShelfID) -> Void
    let openShelf: ((NavigationShelf) -> Void)?
    let select: (NavigationSelection) -> Void
    @State private var isHovering = false

    var body: some View {
        let shelfSelection = NavigationSelection.selectingHero(of: shelf)
        let isSelected = selection.containingShelfID == shelf.id
        Group {
            if isRenaming && !collapsed {
                SidebarShelfTitleEditor(
                    shelf: shelf,
                    symbol: symbol,
                    title: title,
                    moduleCount: shelf.moduleIDs.count,
                    isSelected: isSelected,
                    commit: renameShelf,
                    cancel: cancelShelfCreation)
            } else {
                Button { activate(shelfSelection) } label: {
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                if !compact {
                                    Text(moduleList)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            SidebarShelfCount(count: shelf.moduleIDs.count)
                            if shelf.id == .network {
                                ConnectionStatusDot(status: status)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, compact ? 7 : 9)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(isSelected
                         ? Color(nsColor: .alternateSelectedControlTextColor)
                         : Color.primary)
        .background(SidebarNavigationRowBackground(
            kind: .shelf,
            isSelected: isSelected,
            isHovering: isHovering))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(
            selection.containingShelfID == shelf.id ? [.isSelected] : [])
        .accessibilityLabel(title)
        .help(title)
        .overlay {
            if !isRenaming {
                SidebarNativeDragSurface(
                    payload: .shelf(shelf.id),
                    target: .shelf(shelf.id, beforeModuleID: nil),
                    canDrop: dragActions.canDrop,
                    previewDrop: dragActions.previewDrop,
                    performDrop: dragActions.performDrop,
                    dragEnded: dragActions.dragEnded,
                    activate: { activate(shelfSelection) },
                    springLoad: { activate(shelfSelection) },
                    hoverChanged: { isHovering = $0 })
            }
        }
    }

    private func activate(_ fallback: NavigationSelection) {
        if let openShelf { openShelf(shelf) } else { select(fallback) }
    }

    private var title: String {
        switch shelf.id {
        case .machine: status.machineShelfTitle
        case .screen: "Screen"
        case .files: "Files"
        case .debug: "Debug"
        case .network: "Connections"
        case .user: shelf.title ?? "Shelf"
        }
    }

    private var symbol: String {
        switch shelf.id {
        case .machine: "desktopcomputer"
        case .screen: "rectangle.on.rectangle"
        case .files: "folder"
        case .debug: "ladybug"
        case .network: "network"
        case .user: "square.stack.3d.up"
        }
    }

    private var moduleList: String {
        shelf.moduleIDs.compactMap { registry.module(id: $0)?.title }
            .joined(separator: ", ")
    }
}

private struct SidebarShelfTitleEditor: View {
    let shelf: NavigationShelf
    let symbol: String
    let title: String
    let moduleCount: Int
    let isSelected: Bool
    let commit: (NavigationShelfID, String) -> Void
    let cancel: (NavigationShelfID) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool
    @State private var committed = false

    init(shelf: NavigationShelf, symbol: String, title: String,
         moduleCount: Int, isSelected: Bool,
         commit: @escaping (NavigationShelfID, String) -> Void,
         cancel: @escaping (NavigationShelfID) -> Void) {
        self.shelf = shelf
        self.symbol = symbol
        self.title = title
        self.moduleCount = moduleCount
        self.isSelected = isSelected
        self.commit = commit
        self.cancel = cancel
        _draft = State(initialValue: title)
    }

    var body: some View {
        HStack(spacing: 10) {
            SidebarNavigationIcon(symbol: symbol, isSelected: isSelected)
            TextField("Shelf name", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { finish() }
                .onExitCommand { cancelCreation() }
            SidebarShelfCount(count: moduleCount)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onAppear { focused = true }
        .onChange(of: focused) { isFocused in
            if !isFocused { finish() }
        }
    }

    private func finish() {
        guard !committed else { return }
        committed = true
        commit(shelf.id, draft)
    }

    private func cancelCreation() {
        guard !committed else { return }
        committed = true
        cancel(shelf.id)
    }
}

private struct SidebarShelfCount: View {
    let count: Int

    var body: some View {
        Text(String(count))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .accessibilityLabel("\(count) modules")
    }
}

private struct SidebarNavigationIcon: View {
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isSelected
                             ? Color(nsColor: .alternateSelectedControlTextColor)
                             : Color.secondary)
            .frame(width: 22, height: 22)
    }
}

private struct SidebarNavigationRowBackground: View {
    enum Kind {
        case module
        case shelf
    }

    let kind: Kind
    let isSelected: Bool
    let isHovering: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            if kind == .shelf && !isSelected {
                Color.clear.nowGlassShelf()
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)

            if kind == .shelf && !isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected { return selectionColor }
        if isHovering {
            return Color(nsColor: .selectedContentBackgroundColor)
                .opacity(kind == .shelf ? 0.14 : 0.10)
        }
        return .clear
    }

    private var selectionColor: Color {
        if controlActiveState == .inactive {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return Color(nsColor: .selectedContentBackgroundColor)
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
