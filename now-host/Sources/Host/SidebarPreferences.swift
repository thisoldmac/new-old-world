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
    init(defaults: UserDefaults = ProductIdentity.defaults, registry: ModuleRegistry) {
        self.defaults = defaults
        layoutStore = NavigationLayoutStore(defaults: defaults,
                                            registry: registry)
        layout = layoutStore.load()
        compact = defaults.bool(forKey: SidebarPreferenceKeys.compact)
        collapsed = defaults.bool(forKey: SidebarPreferenceKeys.collapsed)
    }

    func replaceLayout(_ proposed: NavigationLayout) {
        let canonical = layoutStore.save(proposed)
        guard canonical != layout else { return }
        layout = canonical
    }

}
