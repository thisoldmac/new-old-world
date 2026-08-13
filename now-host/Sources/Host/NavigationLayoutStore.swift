import Foundation

struct NavigationLayoutStore {
    static let layoutKey = "navigationLayout"

    private let defaults: UserDefaults
    private let registry: ModuleRegistry
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = ProductIdentity.defaults,
         registry: ModuleRegistry) {
        self.defaults = defaults
        self.registry = registry
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> NavigationLayout {
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? decoder.decode(NavigationLayout.self, from: data) {
            guard stored.version == NavigationLayout.currentVersion else {
                // A newer app owns this payload. Let this process use a safe
                // layout without destroying state it does not understand.
                return NavigationLayout.standard(for: registry)
            }
            let loaded = stored.sanitised(for: registry)
            persist(loaded, replacing: data)
            return loaded
        }

        let loaded: NavigationLayout
        if let legacy = defaults.stringArray(
            forKey: SidebarPreferenceKeys.legacyOrder) {
            loaded = NavigationLayout
                .migratingLegacyOrder(legacy, registry: registry)
                .sanitised(for: registry)
        } else {
            loaded = NavigationLayout.standard(for: registry)
        }
        persist(loaded)
        return loaded
    }

    @discardableResult
    func save(_ layout: NavigationLayout) -> NavigationLayout {
        let repaired = layout.sanitised(for: registry)
        persist(repaired)
        return repaired
    }

    private func persist(_ canonical: NavigationLayout,
                         replacing existing: Data? = nil) {
        guard let data = try? encoder.encode(canonical),
              data != (existing ?? defaults.data(forKey: Self.layoutKey)) else {
            return
        }
        defaults.set(data, forKey: Self.layoutKey)
    }
}
