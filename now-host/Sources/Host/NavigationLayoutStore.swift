import Foundation

/// Read-only compatibility for the flat sidebar order used before shelves.
/// New writes go exclusively through `NavigationLayoutStore`.
enum LegacySidebarOrder {
    static func normalised(_ stored: [String],
                           against known: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for storedID in stored {
            let id = known.contains(storedID)
                ? storedID
                : ModuleRegistry.renamedIDs[storedID].flatMap {
                    known.contains($0) ? $0 : nil
                }
            guard let id, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in known where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}

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
            guard stored.version <= NavigationLayout.currentVersion else {
                // A newer app owns this payload. Let this process use a safe
                // layout without destroying state it does not understand.
                return NavigationLayout.standard(for: registry)
            }
            let loaded = stored.migratedToCurrentVersion()
                .sanitised(for: registry)
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
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? decoder.decode(NavigationLayout.self, from: data),
           stored.version > NavigationLayout.currentVersion {
            return repaired
        }
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
