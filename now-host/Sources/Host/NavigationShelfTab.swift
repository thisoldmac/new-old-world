import Foundation

/// The shelf's navigation belongs to the detail pane. A shelf is one sidebar
/// destination; these tabs choose which real module (or the machine Overview)
/// that destination renders without inventing persisted module identifiers.
struct NavigationShelfTab: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case overview(NavigationShelfID)
        case module(String)
    }

    let id: ID
    let title: String
    let symbol: String
    let tier: ModuleTier
    let selection: NavigationSelection
    let moduleID: String?

    @MainActor
    static func tabs(for shelf: NavigationShelf,
                     registry: ModuleRegistry) -> [NavigationShelfTab] {
        var tabs: [NavigationShelfTab] = []
        if shelf.id == .machine {
            tabs.append(NavigationShelfTab(
                id: .overview(.machine),
                title: "Overview",
                symbol: "rectangle.grid.2x2",
                tier: .core,
                selection: NavigationSelection.selectingHero(of: shelf),
                moduleID: nil))
        }
        tabs.append(contentsOf: shelf.moduleIDs.compactMap { moduleID in
            guard let module = registry.module(id: moduleID) else { return nil }
            return NavigationShelfTab(
                id: .module(moduleID),
                title: module.title,
                symbol: module.symbol,
                tier: module.tier,
                selection: NavigationSelection(
                    destination: .module(moduleID),
                    containingShelfID: shelf.id),
                moduleID: moduleID)
        })
        return tabs
    }

    /// What re-clicking an already-open shelf's icon should reveal: its
    /// first tab, never wherever this window session last left it — that
    /// is `NavigationShelfSessionState`'s job for *reopening* a shelf, but
    /// clicking the shelf you're already on is "go home", not "stay put".
    @MainActor
    static func reactivationSelection(
        for shelf: NavigationShelf,
        registry: ModuleRegistry
    ) -> NavigationSelection? {
        tabs(for: shelf, registry: registry).first?.selection
    }

    /// A shelf row's click handler has three possible outcomes depending on
    /// whether it's already the open shelf and whether a session-restoring
    /// `openShelf` handler is even wired up (it isn't in every presentation
    /// — see `SidebarShelfRow`'s callers). Extracted as pure decision logic
    /// so the "go home, don't restore the remembered tab" fix (H5) is
    /// testable without rendering the row.
    enum ShelfActivationOutcome: Equatable {
        case goHome(NavigationSelection)
        case reopen
        case select
    }

    @MainActor
    static func activationAction(
        for shelf: NavigationShelf,
        isAlreadySelected: Bool,
        registry: ModuleRegistry,
        canReopen: Bool
    ) -> ShelfActivationOutcome {
        if isAlreadySelected,
           let home = reactivationSelection(for: shelf, registry: registry) {
            return .goHome(home)
        }
        return canReopen ? .reopen : .select
    }
}

/// The shelf icon menu exposes real modules only. The shelf hero is navigation
/// chrome, so it can be selected from the shelf but never dragged as a module.
struct NavigationShelfMenuEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let selection: NavigationSelection
    let payload: NavigationDraggedItem

    @MainActor
    static func entries(for shelf: NavigationShelf,
                        registry: ModuleRegistry) -> [Self] {
        shelf.moduleIDs.compactMap { moduleID in
            guard let module = registry.module(id: moduleID) else { return nil }
            return Self(
                id: moduleID,
                title: module.title,
                symbol: module.symbol,
                selection: NavigationSelection(
                    destination: .module(moduleID),
                    containingShelfID: shelf.id),
                payload: .module(moduleID))
        }
    }
}

/// The shelf icon menu exposes real modules only. The shelf hero is navigation
/// chrome, so it can be selected from the shelf but never dragged as a module.
struct NavigationShelfMenuEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let selection: NavigationSelection
    let payload: NavigationDraggedItem

    @MainActor
    static func entries(for shelf: NavigationShelf,
                        registry: ModuleRegistry) -> [Self] {
        shelf.moduleIDs.compactMap { moduleID in
            guard let module = registry.module(id: moduleID) else { return nil }
            return Self(
                id: moduleID,
                title: module.title,
                symbol: module.symbol,
                selection: NavigationSelection(
                    destination: .module(moduleID),
                    containingShelfID: shelf.id),
                payload: .module(moduleID))
        }
    }
}
