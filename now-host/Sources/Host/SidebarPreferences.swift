import Foundation
import Combine

enum SidebarPreferenceKeys {
    static let compact = "sidebarCompact"
    static let collapsed = "sidebarCollapsed"
    static let legacyOrder = "sidebarOrder"
}

/// The sidebar's persisted layout and presentation preferences.
@MainActor
final class SidebarPreferences: ObservableObject {
    /// The versioned navigation arrangement is the sole ordering source.
    @Published private(set) var layout: NavigationLayout
    @Published private(set) var shelfBeingRenamed: NavigationShelfID?

    /// One line per row instead of a title and a summary.
    @Published var compact: Bool {
        didSet { defaults.set(compact, forKey: SidebarPreferenceKeys.compact) }
    }

    /// Folded down to icons. Separate from `compact` rather than a third
    /// value of it, so unfolding gives back the density that was chosen.
    @Published var collapsed: Bool {
        didSet { defaults.set(collapsed, forKey: SidebarPreferenceKeys.collapsed) }
    }

    private let defaults: UserDefaults
    private let layoutStore: NavigationLayoutStore
    private var pendingShelfCreation: PendingShelfCreation?
    init(defaults: UserDefaults = ProductIdentity.defaults, registry: ModuleRegistry) {
        self.defaults = defaults
        layoutStore = NavigationLayoutStore(defaults: defaults,
                                            registry: registry)
        layout = layoutStore.load()
        shelfBeingRenamed = nil
        compact = defaults.bool(forKey: SidebarPreferenceKeys.compact)
        collapsed = defaults.bool(forKey: SidebarPreferenceKeys.collapsed)
    }

    func replaceLayout(_ proposed: NavigationLayout) {
        let previous = layout
        let existingUserShelves = layout.userShelfIDs
        let canonical = layoutStore.save(proposed)
        guard canonical != layout else { return }
        layout = canonical
        let createdShelfID = canonical.userShelfIDs
            .subtracting(existingUserShelves)
            .sorted { $0.rawValue < $1.rawValue }
            .first
        shelfBeingRenamed = createdShelfID
        if let createdShelfID {
            pendingShelfCreation = PendingShelfCreation(
                shelfID: createdShelfID, previousLayout: previous)
        }
    }

    func renameShelf(id: NavigationShelfID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            shelfBeingRenamed = nil
            pendingShelfCreation = nil
            return
        }
        var changed = layout
        for zone in NavigationZone.allCases {
            var items = changed.items(in: zone)
            guard let index = items.firstIndex(where: {
                guard case .shelf(let shelf) = $0 else { return false }
                return shelf.id == id
            }), case .shelf(var shelf) = items[index], case .user = shelf.id
            else { continue }
            shelf.title = trimmed
            items[index] = .shelf(shelf)
            changed.setItems(items, in: zone)
            layout = layoutStore.save(changed)
            shelfBeingRenamed = nil
            pendingShelfCreation = nil
            return
        }
        shelfBeingRenamed = nil
        pendingShelfCreation = nil
    }

    func cancelShelfCreation(id: NavigationShelfID) {
        guard let pendingShelfCreation,
              pendingShelfCreation.shelfID == id else { return }
        layout = layoutStore.save(pendingShelfCreation.previousLayout)
        shelfBeingRenamed = nil
        self.pendingShelfCreation = nil
    }

}

private struct PendingShelfCreation {
    let shelfID: NavigationShelfID
    let previousLayout: NavigationLayout
}

private extension NavigationLayout {
    var userShelfIDs: Set<NavigationShelfID> {
        Set(NavigationZone.allCases.flatMap { items(in: $0) }.compactMap {
            guard case .shelf(let shelf) = $0,
                  case .user = shelf.id else { return nil }
            return shelf.id
        })
    }
}
