import SwiftUI

/// One shelf page: its member modules are top-centred pill tabs and the
/// selected module owns everything beneath them.
struct ShelfDetailView<Content: View>: View {
    let shelf: NavigationShelf
    let tabs: [NavigationShelfTab]
    let selection: NavigationSelection
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ShelfPillTabBar(
                shelfID: shelf.id,
                tabs: tabs,
                selectedDestination: selection.destination,
                dragActions: dragActions,
                select: select)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ShelfPillTabBar: View {
    let shelfID: NavigationShelfID
    let tabs: [NavigationShelfTab]
    let selectedDestination: NavigationDestination
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Spacer(minLength: 12)
                ShelfPillRow(
                    shelfID: shelfID,
                    tabs: tabs,
                    selectedDestination: selectedDestination,
                    dragActions: dragActions,
                    select: select)
                Spacer(minLength: 12)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                ShelfPillRow(
                    shelfID: shelfID,
                    tabs: tabs,
                    selectedDestination: selectedDestination,
                    dragActions: dragActions,
                    select: select)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct ShelfPillRow: View {
    let shelfID: NavigationShelfID
    let tabs: [NavigationShelfTab]
    let selectedDestination: NavigationDestination
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs) { tab in
                ShelfPillItem(
                    shelfID: shelfID,
                    tab: tab,
                    isSelected: tab.selection.destination
                        == selectedDestination,
                    dragActions: dragActions,
                    select: { select(tab.selection) })
            }
            ShelfPillDropSlot(
                target: .shelf(shelfID, beforeModuleID: nil),
                dragActions: dragActions)
        }
        .padding(3)
        .background(.bar, in: Capsule())
        .animation(.easeInOut(duration: 0.16), value: tabs)
    }
}

private struct ShelfPillItem: View {
    let shelfID: NavigationShelfID
    let tab: NavigationShelfTab
    let isSelected: Bool
    let dragActions: SidebarNavigationDragActions
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        ShelfPillButton(
            tab: tab,
            isSelected: isSelected,
            isHovering: isHovering,
            select: select)
            .overlay {
                if let moduleID = tab.moduleID {
                    SidebarNativeDragSurface(
                        payload: .module(moduleID),
                        target: .shelf(shelfID,
                                       beforeModuleID: moduleID),
                        canDrop: dragActions.canDrop,
                        previewDrop: dragActions.previewDrop,
                        performDrop: dragActions.performDrop,
                        dragEnded: dragActions.dragEnded,
                        activate: select,
                        hoverChanged: { isHovering = $0 })
                }
            }
    }
}

private struct ShelfPillDropSlot: View {
    let target: NavigationDropTarget
    let dragActions: SidebarNavigationDragActions

    var body: some View {
        Color.clear
            .frame(width: 10, height: 30)
            .overlay(SidebarNativeDragSurface(
                payload: nil,
                target: target,
                canDrop: dragActions.canDrop,
                previewDrop: dragActions.previewDrop,
                performDrop: dragActions.performDrop))
    }
}

private struct ShelfPillButton: View {
    let tab: NavigationShelfTab
    let isSelected: Bool
    let isHovering: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Label(tab.title, systemImage: tab.symbol)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(backgroundColor))
        .foregroundStyle(isSelected
                         ? Color(nsColor: .alternateSelectedControlTextColor)
                         : Color.primary)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        if isHovering {
            return Color(nsColor: .selectedContentBackgroundColor)
                .opacity(0.12)
        }
        return .clear
    }
}
