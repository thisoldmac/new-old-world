import Foundation

struct NavigationLayoutStore {
    static let layoutKey = "navigationLayout"
    static let legacyOrderKey = "sidebarOrder"

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
        let loaded: NavigationLayout
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? decoder.decode(NavigationLayout.self, from: data) {
            loaded = stored.sanitised(for: registry)
        } else if let legacy = defaults.stringArray(forKey: Self.legacyOrderKey) {
            loaded = NavigationLayout
                .migratingLegacyOrder(legacy, registry: registry)
                .sanitised(for: registry)
        } else {
            loaded = NavigationLayout.standard(for: registry)
        }
        save(loaded)
        return loaded
    }

    func save(_ layout: NavigationLayout) {
        let repaired = layout.sanitised(for: registry)
        guard let data = try? encoder.encode(repaired) else { return }
        defaults.set(data, forKey: Self.layoutKey)
    }
}
