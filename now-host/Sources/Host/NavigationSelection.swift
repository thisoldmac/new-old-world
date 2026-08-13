import Foundation

/// A sidebar destination is either a real module or a shelf-owned hero.
///
/// Module identifiers remain the persisted compatibility contract. Shelf
/// heroes are window-local navigation: the machine Overview is not a module
/// and must never leak a pseudo identifier into module preferences or menus.
enum NavigationDestination: Hashable, Sendable {
    case module(String)
    case shelfHero(NavigationShelfID)
}

struct NavigationSelection: Equatable, Sendable {
    let destination: NavigationDestination
    let containingShelfID: NavigationShelfID?

    static func selecting(moduleID: String,
                          in layout: NavigationLayout) -> NavigationSelection {
        NavigationSelection(
            destination: .module(moduleID),
            containingShelfID: containingShelf(for: moduleID, in: layout))
    }

    static func selectingLooseModule(_ moduleID: String) -> NavigationSelection {
        NavigationSelection(destination: .module(moduleID),
                            containingShelfID: nil)
    }

    static func selectingHero(of shelf: NavigationShelf) -> NavigationSelection {
        let destination: NavigationDestination
        switch shelf.hero {
        case .overview:
            destination = .shelfHero(shelf.id)
        case .module(let moduleID):
            destination = .module(moduleID)
        case nil:
            destination = .shelfHero(shelf.id)
        }
        return NavigationSelection(destination: destination,
                                   containingShelfID: shelf.id)
    }

    func requiresDrawerPresentation(in layout: NavigationLayout) -> Bool {
        guard case .module(let moduleID) = destination else { return false }
        return layout.zone(containing: moduleID) == .drawer
    }

    private static func containingShelf(
        for moduleID: String,
        in layout: NavigationLayout
    ) -> NavigationShelfID? {
        for zone in NavigationZone.allCases {
            for item in layout.items(in: zone) {
                guard case .shelf(let shelf) = item,
                      shelf.moduleIDs.contains(moduleID) else { continue }
                return shelf.id
            }
        }
        return nil
    }
}
