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
                ShelfPillButton(
                    tab: tab,
                    isSelected: tab.selection.destination
                        == selectedDestination,
                    select: { select(tab.selection) })
                    .overlay(tabDragSurface(tab))
            }
            ShelfPillDropSlot(
                target: .shelf(shelfID, beforeModuleID: nil),
                dragActions: dragActions)
        }
        .padding(4)
        .nowGlassPanel(cornerRadius: 18)
        .animation(.easeInOut(duration: 0.16), value: tabs)
    }

    @ViewBuilder
    private func tabDragSurface(_ tab: NavigationShelfTab) -> some View {
        if let moduleID = tab.moduleID {
            SidebarNativeDragSurface(
                payload: .module(moduleID),
                target: .shelf(shelfID, beforeModuleID: moduleID),
                canDrop: dragActions.canDrop,
                previewDrop: dragActions.previewDrop,
                performDrop: dragActions.performDrop,
                dragEnded: dragActions.dragEnded,
                activate: { select(tab.selection) })
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
            Capsule().fill(Color.accentColor.opacity(isSelected ? 0.22 : 0)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
