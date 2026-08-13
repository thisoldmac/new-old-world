import SwiftUI

struct HostRootView: View {
    let registry: ModuleRegistry
    @ObservedObject var state: HostAppState
    @ObservedObject var sidebar: SidebarPreferences
    @State private var selectedHeroShelfID: NavigationShelfID?

    init(registry: ModuleRegistry,
         state: HostAppState,
         sidebar: SidebarPreferences) {
        self.registry = registry
        self.state = state
        self.sidebar = sidebar
        _selectedHeroShelfID = State(initialValue: nil)
    }

    var body: some View {
        NavigationSplitView {
            HostSidebarView(
                registry: registry,
                sidebar: sidebar,
                listener: state.listener,
                monitor: state.guestStatus,
                selection: selection,
                selectGuest: { state.selectGuest($0) },
                select: select)
        } detail: {
            HostDetailView(
                destination: selection.destination,
                registry: registry,
                layout: sidebar.layout,
                state: state,
                selectModule: selectModule)
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
        }
    }

    private var selection: NavigationSelection {
        if let selectedHeroShelfID,
           let shelf = sidebar.layout.shelf(id: selectedHeroShelfID) {
            return NavigationSelection.selectingHero(of: shelf)
        }
        return NavigationSelection.restoring(
            moduleID: state.selectedModuleID,
            in: sidebar.layout)
    }

    private func select(_ newSelection: NavigationSelection) {
        switch newSelection.destination {
        case .module(let moduleID):
            selectModule(moduleID)
        case .shelfHero(let shelfID):
            selectedHeroShelfID = shelfID
        }
    }

    private func selectModule(_ moduleID: String) {
        guard registry.module(id: moduleID) != nil else { return }
        selectedHeroShelfID = nil
        state.selectedModuleID = moduleID
    }
}

/// Shelves route into the existing module runtime rather than duplicating
/// the registry's rendering switch. The machine overview is the one true
/// shelf-owned detail surface; every module keeps its established owner.
private struct HostDetailView: View {
    let destination: NavigationDestination
    let registry: ModuleRegistry
    let layout: NavigationLayout
    @ObservedObject var state: HostAppState
    let selectModule: (String) -> Void

    var body: some View {
        switch destination {
        case .shelfHero(.machine):
            MachineOverviewView(
                monitor: state.guestStatus,
                modules: machineModules,
                selectModule: selectModule)
        case .shelfHero:
            unavailable
        case .module(let moduleID):
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
