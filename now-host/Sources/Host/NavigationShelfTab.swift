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
}
