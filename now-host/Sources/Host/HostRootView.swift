import SwiftUI

struct HostRootView: View {
    let registry: ModuleRegistry
    @ObservedObject var state: HostAppState
    @ObservedObject var sidebar: SidebarPreferences
    @State private var selectedHeroShelfID: NavigationShelfID?
    @State private var shelfSession = NavigationShelfSessionState()
    @State private var dragPreview: NavigationDragPreview?

    init(registry: ModuleRegistry,
         state: HostAppState,
         sidebar: SidebarPreferences) {
        self.registry = registry
        self.state = state
        self.sidebar = sidebar
        _selectedHeroShelfID = State(initialValue: nil)
        _shelfSession = State(initialValue: NavigationShelfSessionState())
        _dragPreview = State(initialValue: nil)
    }

    var body: some View {
        NavigationSplitView {
            HostSidebarView(
                registry: registry,
                sidebar: sidebar,
                layout: presentationLayout,
                listener: state.listener,
                monitor: state.guestStatus,
                selection: selection,
                dragActions: dragActions,
                selectGuest: { state.selectGuest($0) },
                openShelf: openShelf,
                select: select)
        } detail: {
            HostDetailView(
                selection: selection,
                registry: registry,
                layout: presentationLayout,
                state: state,
                monitor: state.guestStatus,
                dragActions: dragActions,
                select: select)
                // A module may wrap at any size, but may not ask the window
                // to grow to an unbounded ideal width.
                .frame(minWidth: 480, idealWidth: 820,
                       maxWidth: .infinity, maxHeight: .infinity)
        }
        // View-menu commands write the long-standing module preference.
        // Clear a transient hero so even selecting the same module again
        // reveals its containing shelf and tab.
        .onReceive(state.$selectedModuleID) { _ in
            selectedHeroShelfID = nil
            shelfSession.remember(NavigationSelection.selecting(
                moduleID: state.selectedModuleID,
                in: sidebar.layout))
        }
    }

    private var presentationLayout: NavigationLayout {
        dragPreview?.layout ?? sidebar.layout
    }

    private var selection: NavigationSelection {
        if let selectedHeroShelfID,
           let shelf = presentationLayout.shelf(id: selectedHeroShelfID) {
            return NavigationSelection.selectingHero(of: shelf)
        }
        return NavigationSelection.selecting(
            moduleID: state.selectedModuleID,
            in: presentationLayout)
    }

    private func select(_ newSelection: NavigationSelection) {
        shelfSession.remember(newSelection)
        switch newSelection.destination {
        case .module(let moduleID):
            selectModule(moduleID)
        case .shelfHero(let shelfID):
            selectedHeroShelfID = shelfID
        }
    }

    private func openShelf(_ shelf: NavigationShelf) {
        select(shelfSession.selection(forOpening: shelf))
    }

    private func selectModule(_ moduleID: String) {
        guard registry.module(id: moduleID) != nil else { return }
        selectedHeroShelfID = nil
        state.selectedModuleID = moduleID
    }

    private var dragActions: SidebarNavigationDragActions {
        SidebarNavigationDragActions(
            canDrop: { payload, target in
                NavigationDragCoordinator.command(
                    for: payload, droppingOn: target,
                    in: sidebar.layout) != nil
            },
            previewDrop: { payload, target in
                guard let preview = NavigationDragPreview(
                    dragged: payload, target: target,
                    baseline: sidebar.layout) else { return false }
                guard preview != dragPreview else { return true }
                withAnimation(.easeInOut(duration: 0.16)) {
                    dragPreview = preview
                }
                return true
            },
            performDrop: { payload, target in
                guard let command = NavigationDragCoordinator.command(
                    for: payload, droppingOn: target,
                    in: sidebar.layout),
                      let changed = try? sidebar.layout.applying(command)
                else { return false }
                withAnimation(.easeInOut(duration: 0.16)) {
                    sidebar.replaceLayout(changed)
                    dragPreview = nil
                }
                return true
            },
            dragEnded: { payload in
                guard dragPreview?.dragged == payload else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    dragPreview = nil
                }
            })
    }
}

/// Shelves and availability policy wrap the existing module runtime; they do
/// not duplicate the registry's rendering switch or take ownership from a
/// module definition.
private struct HostDetailView: View {
    let selection: NavigationSelection
    let registry: ModuleRegistry
    let layout: NavigationLayout
    @ObservedObject var state: HostAppState
    @ObservedObject var monitor: GuestStatusMonitor
    let dragActions: SidebarNavigationDragActions
    let select: (NavigationSelection) -> Void

    @ViewBuilder
    var body: some View {
        if let shelfID = selection.containingShelfID,
           let shelf = layout.shelf(id: shelfID) {
            ShelfDetailView(
                shelf: shelf,
                tabs: NavigationShelfTab.tabs(for: shelf, registry: registry),
                selection: selection,
                dragActions: dragActions,
                select: select) {
                    destinationContent(selection.destination)
                }
        } else {
            destinationContent(selection.destination)
        }
    }

    @ViewBuilder
    private func destinationContent(_ destination: NavigationDestination) -> some View {
        switch destination {
        case .shelfHero(.machine):
            MachineOverviewView(
                monitor: state.guestStatus,
                modules: machineModules,
                selectModule: selectModule)
        case .shelfHero:
            unavailable
        case .module(let moduleID):
            module(moduleID)
        }
    }

    private func selectModule(_ moduleID: String) {
        select(NavigationSelection.selecting(moduleID: moduleID, in: layout))
    }

    private func module(_ moduleID: String) -> some View {
        let presentation = ModuleAvailabilityPresentation.resolve(
            moduleID: moduleID,
            status: monitor.status)
        return ModuleAvailabilityShell(
            presentation: presentation,
            moduleTitle: registry.module(id: moduleID)?.title ?? "This Module",
            status: monitor.status,
            showConnections: { selectModule("settings") },
            startListening: { state.startListening() }) {
                state.moduleView(registry: registry, id: moduleID)
            }
    }

    private var machineModules: [ModuleDescriptor] {
        layout.shelf(id: .machine)?.moduleIDs
            .compactMap(registry.module(id:)) ?? []
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.app")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Module Unavailable")
                .font(.title2.weight(.semibold))
        }
        .padding(28)
        .nowGlassPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
