import Foundation

enum NavigationZone: String, Codable, CaseIterable, Sendable {
    case upper
    case lower
    case drawer
}

enum NavigationShelfID: Hashable, Sendable {
    case machine
    case screen
    case files
    case network
    case user(UUID)

    static let machineRawValue = "shelf.machine"
    static let screenRawValue = "shelf.screen"
    static let filesRawValue = "shelf.files"
    static let networkRawValue = "shelf.network"
    private static let userPrefix = "shelf.user."

    var rawValue: String {
        switch self {
        case .machine: Self.machineRawValue
        case .screen: Self.screenRawValue
        case .files: Self.filesRawValue
        case .network: Self.networkRawValue
        case .user(let id): Self.userPrefix + id.uuidString.lowercased()
        }
    }

    var isPermanent: Bool {
        self == .machine || self == .network
    }

    var canEnterDrawer: Bool {
        self != .machine
    }
}

extension NavigationShelfID: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.machineRawValue: self = .machine
        case Self.screenRawValue: self = .screen
        case Self.filesRawValue: self = .files
        case Self.networkRawValue: self = .network
        default:
            guard raw.hasPrefix(Self.userPrefix),
                  let id = UUID(uuidString: String(raw.dropFirst(Self.userPrefix.count)))
            else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown navigation shelf id \(raw)")
            }
            self = .user(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum NavigationShelfHero: Equatable, Sendable {
    case overview
    case module(String)
}

struct NavigationShelf: Codable, Equatable, Sendable, Identifiable {
    let id: NavigationShelfID
    var title: String?
    var moduleIDs: [String]

    init(id: NavigationShelfID, title: String? = nil, moduleIDs: [String]) {
        self.id = id
        self.title = title
        self.moduleIDs = moduleIDs
    }

    var hero: NavigationShelfHero? {
        switch id {
        case .machine: .overview
        case .screen: .module("screen")
        case .files: .module("files")
        case .network: .module("settings")
        case .user: moduleIDs.first.map(NavigationShelfHero.module)
        }
    }
}

enum NavigationItem: Equatable, Sendable, Identifiable {
    case module(String)
    case shelf(NavigationShelf)

    var id: String {
        switch self {
        case .module(let id): "module.\(id)"
        case .shelf(let shelf): shelf.id.rawValue
        }
    }

    var moduleIDs: [String] {
        switch self {
        case .module(let id): [id]
        case .shelf(let shelf): shelf.moduleIDs
        }
    }
}

extension NavigationItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case moduleID
        case shelf
    }

    private enum Kind: String, Codable {
        case module
        case shelf
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .module:
            self = .module(try container.decode(String.self, forKey: .moduleID))
        case .shelf:
            self = .shelf(try container.decode(NavigationShelf.self,
                                               forKey: .shelf))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .module(let id):
            try container.encode(Kind.module, forKey: .kind)
            try container.encode(id, forKey: .moduleID)
        case .shelf(let shelf):
            try container.encode(Kind.shelf, forKey: .kind)
            try container.encode(shelf, forKey: .shelf)
        }
    }
}

/// The serializable navigation contract. It stores identities and composition,
/// never registry descriptors or derived presentation such as drawer counts.
struct NavigationLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var upper: [NavigationItem]
    var lower: [NavigationItem]
    var drawer: [NavigationItem]

    init(version: Int = Self.currentVersion,
         upper: [NavigationItem],
         lower: [NavigationItem],
         drawer: [NavigationItem]) {
        self.version = version
        self.upper = upper
        self.lower = lower
        self.drawer = drawer
    }

    var allModuleIDs: [String] {
        NavigationZone.allCases.flatMap { items(in: $0).flatMap(\.moduleIDs) }
    }

    var drawerModuleCount: Int {
        drawer.reduce(0) { $0 + $1.moduleIDs.count }
    }

    func items(in zone: NavigationZone) -> [NavigationItem] {
        switch zone {
        case .upper: upper
        case .lower: lower
        case .drawer: drawer
        }
    }

    func shelf(id: NavigationShelfID) -> NavigationShelf? {
        NavigationZone.allCases
            .flatMap { items(in: $0) }
            .compactMap {
                guard case .shelf(let shelf) = $0, shelf.id == id else {
                    return nil
                }
                return shelf
            }
            .first
    }

    func zone(of shelfID: NavigationShelfID) -> NavigationZone? {
        NavigationZone.allCases.first { zone in
            items(in: zone).contains {
                guard case .shelf(let shelf) = $0 else { return false }
                return shelf.id == shelfID
            }
        }
    }

    static func standard(for registry: ModuleRegistry) -> NavigationLayout {
        let known = Set(registry.modules.map(\.id))
        func present(_ ids: [String]) -> [String] {
            ids.filter(known.contains)
        }

        var layout = NavigationLayout(
            upper: [
                .shelf(NavigationShelf(
                    id: .machine,
                    moduleIDs: present(["census", "software", "processes",
                                        "diagnostics"]))),
                .shelf(NavigationShelf(
                    id: .screen,
                    moduleIDs: present(["screen", "mirror", "continuity"]))),
                .shelf(NavigationShelf(
                    id: .files,
                    moduleIDs: present(["files", "icloud"]))),
                .module("chat"),
                .module("development"),
            ],
            lower: [
                .shelf(NavigationShelf(
                    id: .network,
                    moduleIDs: present(["settings", "networking", "mcp", "web"]))),
                .module("console"),
                .module("logs"),
            ],
            drawer: [])

        layout.upper = layout.upper.compactMap { item in
            switch item {
            case .module(let id): known.contains(id) ? item : nil
            case .shelf: item
            }
        }
        let placed = Set(layout.allModuleIDs)
        layout.upper.append(contentsOf: registry.modules
            .map(\.id)
            .filter { !placed.contains($0) }
            .map(NavigationItem.module))
        return layout
    }

    static func migratingLegacyOrder(_ stored: [String],
                                     registry: ModuleRegistry) -> NavigationLayout {
        var layout = standard(for: registry)
        let known = registry.modules.map(\.id)
        var seen = Set<String>()
        var order: [String] = []
        for storedID in stored {
            let id = known.contains(storedID)
                ? storedID
                : ModuleRegistry.renamedIDs[storedID].flatMap {
                    known.contains($0) ? $0 : nil
                }
            guard let id, seen.insert(id).inserted else { continue }
            order.append(id)
        }
        order.append(contentsOf: known.filter { seen.insert($0).inserted })
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map {
            ($0.element, $0.offset)
        })
        let indexed = layout.upper.enumerated().map { (offset: $0.offset,
                                                       item: $0.element) }
        layout.upper = indexed.sorted { lhs, rhs in
            let left = lhs.item.moduleIDs.compactMap { rank[$0] }.min() ?? Int.max
            let right = rhs.item.moduleIDs.compactMap { rank[$0] }.min() ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.item)
        return layout
    }

    /// Repairs stored state into a total partition of the live registry.
    func sanitised(for registry: ModuleRegistry) -> NavigationLayout {
        let known = Set(registry.modules.map(\.id))
        var seenModules = Set<String>()
        var seenShelves = Set<NavigationShelfID>()
        var output = NavigationLayout(upper: [], lower: [], drawer: [])

        func resolved(_ stored: String) -> String? {
            if known.contains(stored) { return stored }
            guard let renamed = ModuleRegistry.renamedIDs[stored],
                  known.contains(renamed) else { return nil }
            return renamed
        }

        for zone in NavigationZone.allCases {
            for item in items(in: zone) {
                switch item {
                case .module(let stored):
                    guard let id = resolved(stored),
                          seenModules.insert(id).inserted else { continue }
                    output.append(.module(id), to: zone)
                case .shelf(var shelf):
                    guard seenShelves.insert(shelf.id).inserted else { continue }
                    shelf.moduleIDs = shelf.moduleIDs.compactMap { stored in
                        guard let id = resolved(stored),
                              seenModules.insert(id).inserted else { return nil }
                        return id
                    }
                    if case .user = shelf.id, shelf.moduleIDs.count < 2 {
                        if let id = shelf.moduleIDs.first {
                            output.append(.module(id), to: zone)
                        }
                        continue
                    }
                    let repairedZone: NavigationZone =
                        shelf.id.canEnterDrawer ? zone : (zone == .drawer ? .upper : zone)
                    output.append(.shelf(shelf), to: repairedZone)
                }
            }
        }

        // No usable module identity means the payload cannot express an
        // arrangement. Recover the accepted layout rather than preserving an
        // empty shell and appending every module as an arbitrary loose row.
        if seenModules.isEmpty {
            return Self.standard(for: registry)
        }

        output.ensurePermanentShelf(.machine, in: .upper, seen: &seenShelves)
        output.ensurePermanentShelf(.network, in: .lower, seen: &seenShelves)

        for id in registry.modules.map(\.id) where !seenModules.contains(id) {
            if id == "continuity" {
                output.adoptContinuity()
            } else if let shelfID = Self.defaultShelf(for: id),
                      output.append(id, toShelf: shelfID) {
                // The shelf is where this known family adopts new members.
            } else {
                output.upper.append(.module(id))
            }
            seenModules.insert(id)
        }

        output.enforceSpecialHeroes(known: known)
        output.decomposeSmallUserShelves()
        output.version = Self.currentVersion
        return output
    }

    private static func defaultShelf(for moduleID: String) -> NavigationShelfID? {
        switch moduleID {
        case "census", "software", "processes", "diagnostics": .machine
        case "screen", "mirror", "continuity": .screen
        case "files", "icloud": .files
        case "settings", "networking", "mcp", "web": .network
        default: nil
        }
    }

    private mutating func append(_ item: NavigationItem, to zone: NavigationZone) {
        switch zone {
        case .upper: upper.append(item)
        case .lower: lower.append(item)
        case .drawer: drawer.append(item)
        }
    }

    private mutating func ensurePermanentShelf(
        _ id: NavigationShelfID,
        in zone: NavigationZone,
        seen: inout Set<NavigationShelfID>
    ) {
        guard seen.insert(id).inserted else { return }
        append(.shelf(NavigationShelf(id: id, moduleIDs: [])), to: zone)
    }

    @discardableResult
    private mutating func append(_ moduleID: String,
                                 toShelf id: NavigationShelfID) -> Bool {
        for zone in NavigationZone.allCases {
            var items = items(in: zone)
            guard let index = items.firstIndex(where: {
                guard case .shelf(let shelf) = $0 else { return false }
                return shelf.id == id
            }) else { continue }
            guard case .shelf(var shelf) = items[index] else { continue }
            shelf.moduleIDs.append(moduleID)
            items[index] = .shelf(shelf)
            setItems(items, in: zone)
            return true
        }
        return false
    }

    private mutating func adoptContinuity() {
        if append("continuity", toShelf: .screen) { return }

        removeModule("screen")
        upper.append(.shelf(NavigationShelf(id: .screen,
            moduleIDs: ["screen", "continuity"])))
    }

    private mutating func enforceSpecialHeroes(known: Set<String>) {
        for (shelfID, heroID) in [(NavigationShelfID.screen, "screen"),
                                  (.files, "files"),
                                  (.network, "settings")] where known.contains(heroID) {
            guard shelf(id: shelfID) != nil else { continue }
            removeModule(heroID)
            _ = prepend(heroID, toShelf: shelfID)
        }
    }

    private mutating func prepend(_ moduleID: String,
                                  toShelf id: NavigationShelfID) -> Bool {
        for zone in NavigationZone.allCases {
            var items = items(in: zone)
            guard let index = items.firstIndex(where: {
                guard case .shelf(let shelf) = $0 else { return false }
                return shelf.id == id
            }) else { continue }
            guard case .shelf(var shelf) = items[index] else { continue }
            shelf.moduleIDs.insert(moduleID, at: 0)
            items[index] = .shelf(shelf)
            setItems(items, in: zone)
            return true
        }
        return false
    }

    private mutating func removeModule(_ moduleID: String) {
        for zone in NavigationZone.allCases {
            var changed = false
            let items = items(in: zone).compactMap { item -> NavigationItem? in
                switch item {
                case .module(let id) where id == moduleID:
                    changed = true
                    return nil
                case .shelf(var shelf) where shelf.moduleIDs.contains(moduleID):
                    shelf.moduleIDs.removeAll { $0 == moduleID }
                    changed = true
                    return .shelf(shelf)
                default:
                    return item
                }
            }
            if changed { setItems(items, in: zone) }
        }
    }

    private mutating func decomposeSmallUserShelves() {
        for zone in NavigationZone.allCases {
            let items = items(in: zone).compactMap { item -> NavigationItem? in
                guard case .shelf(let shelf) = item,
                      case .user = shelf.id,
                      shelf.moduleIDs.count < 2 else { return item }
                return shelf.moduleIDs.first.map(NavigationItem.module)
            }
            setItems(items, in: zone)
        }
    }

    private mutating func setItems(_ items: [NavigationItem],
                                   in zone: NavigationZone) {
        switch zone {
        case .upper: upper = items
        case .lower: lower = items
        case .drawer: drawer = items
        }
    }
}
