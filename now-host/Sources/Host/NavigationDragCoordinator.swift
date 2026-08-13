import Foundation

enum NavigationDraggedItem: Codable, Equatable, Sendable {
    case module(String)
    case shelf(NavigationShelfID)

    var pasteboardValue: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(pasteboardValue: String) {
        guard let data = pasteboardValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }
}

enum NavigationDropTarget: Equatable, Sendable {
    case zone(NavigationZone, index: Int)
    case module(String)
    case shelf(NavigationShelfID, beforeModuleID: String?)
}

enum NavigationLayoutCommand: Equatable, Sendable {
    case move(NavigationDraggedItem, to: NavigationZone, index: Int)
    case combine(moduleID: String, with: String, shelfID: UUID)
    case insert(moduleID: String, into: NavigationShelfID,
                beforeModuleID: String?)
}

enum NavigationLayoutCommandError: Error, Equatable {
    case missingSource
    case missingTarget
    case invalidTarget
    case duplicateShelf
}

/// Turns a native drag payload and hit-tested target into a pure layout
/// command. Hover and spring-loading feedback never call this command's
/// mutation path; only AppKit's `performDragOperation` does.
struct NavigationDragCoordinator {
    static func command(
        for dragged: NavigationDraggedItem,
        droppingOn target: NavigationDropTarget,
        in layout: NavigationLayout,
        makeShelfID: () -> UUID = UUID.init
    ) -> NavigationLayoutCommand? {
        guard layout.contains(dragged) else { return nil }

        switch target {
        case .zone(let zone, let index):
            guard (0...layout.items(in: zone).count).contains(index) else {
                return nil
            }
            if case .shelf(let shelfID) = dragged,
               zone == .drawer, !shelfID.canEnterDrawer {
                return nil
            }
            return .move(dragged, to: zone, index: index)

        case .module(let targetID):
            guard case .module(let sourceID) = dragged,
                  sourceID != targetID,
                  layout.containsLooseModule(targetID) else { return nil }
            let shelfID = makeShelfID()
            guard layout.shelf(id: .user(shelfID)) == nil else { return nil }
            return .combine(moduleID: sourceID, with: targetID,
                            shelfID: shelfID)

        case .shelf(let shelfID, let beforeModuleID):
            guard case .module(let moduleID) = dragged,
                  moduleID != beforeModuleID,
                  let shelf = layout.shelf(id: shelfID),
                  beforeModuleID.map(shelf.moduleIDs.contains) ?? true else {
                return nil
            }
            return .insert(moduleID: moduleID, into: shelfID,
                           beforeModuleID: beforeModuleID)
        }
    }
}

extension NavigationLayout {
    func applying(_ command: NavigationLayoutCommand) throws
        -> NavigationLayout {
        var changed = self
        switch command {
        case .move(let dragged, let zone, let requestedIndex):
            guard let movingItem = changed.navigationItem(for: dragged) else {
                throw NavigationLayoutCommandError.missingSource
            }
            if case .shelf(let shelfID) = dragged,
               zone == .drawer, !shelfID.canEnterDrawer {
                throw NavigationLayoutCommandError.invalidTarget
            }
            let origin = changed.topLevelLocation(of: dragged)
            let removedTopLevel = try changed.remove(dragged)
            var index = requestedIndex
            if removedTopLevel, origin?.zone == zone,
               let sourceIndex = origin?.index, sourceIndex < index {
                index -= 1
            }
            guard (0...changed.items(in: zone).count).contains(index) else {
                throw NavigationLayoutCommandError.invalidTarget
            }
            changed.insert(movingItem, in: zone, at: index)

        case .combine(let moduleID, let targetID, let shelfUUID):
            guard moduleID != targetID,
                  changed.contains(.module(moduleID)) else {
                throw NavigationLayoutCommandError.missingSource
            }
            guard changed.containsLooseModule(targetID) else {
                throw NavigationLayoutCommandError.missingTarget
            }
            let shelfID = NavigationShelfID.user(shelfUUID)
            guard changed.shelf(id: shelfID) == nil else {
                throw NavigationLayoutCommandError.duplicateShelf
            }
            _ = try changed.remove(.module(moduleID))
            guard let target = changed.looseModuleLocation(targetID) else {
                throw NavigationLayoutCommandError.missingTarget
            }
            var items = changed.items(in: target.zone)
            items[target.index] = .shelf(NavigationShelf(
                id: shelfID, moduleIDs: [targetID, moduleID]))
            changed.setItems(items, in: target.zone)

        case .insert(let moduleID, let shelfID, let beforeModuleID):
            guard changed.contains(.module(moduleID)) else {
                throw NavigationLayoutCommandError.missingSource
            }
            guard let existing = changed.shelf(id: shelfID),
                  beforeModuleID.map(existing.moduleIDs.contains) ?? true else {
                throw NavigationLayoutCommandError.missingTarget
            }
            _ = try changed.remove(.module(moduleID))
            guard var destination = changed.shelf(id: shelfID),
                  let location = changed.shelfLocation(shelfID) else {
                throw NavigationLayoutCommandError.missingTarget
            }
            let index: Int
            if let beforeModuleID,
               let found = destination.moduleIDs.firstIndex(of: beforeModuleID) {
                index = found
            } else {
                index = destination.moduleIDs.endIndex
            }
            destination.moduleIDs.insert(moduleID, at: index)
            var items = changed.items(in: location.zone)
            items[location.index] = .shelf(destination)
            changed.setItems(items, in: location.zone)
        }
        return changed
    }

    fileprivate func contains(_ dragged: NavigationDraggedItem) -> Bool {
        navigationItem(for: dragged) != nil
    }

    private func navigationItem(for dragged: NavigationDraggedItem)
        -> NavigationItem? {
        switch dragged {
        case .module(let id):
            return allModuleIDs.contains(id) ? .module(id) : nil
        case .shelf(let id):
            return shelf(id: id).map(NavigationItem.shelf)
        }
    }

    fileprivate func containsLooseModule(_ moduleID: String) -> Bool {
        looseModuleLocation(moduleID) != nil
    }

    private func looseModuleLocation(_ moduleID: String)
        -> (zone: NavigationZone, index: Int)? {
        for zone in NavigationZone.allCases {
            if let index = items(in: zone).firstIndex(of: .module(moduleID)) {
                return (zone, index)
            }
        }
        return nil
    }

    private func shelfLocation(_ shelfID: NavigationShelfID)
        -> (zone: NavigationZone, index: Int)? {
        for zone in NavigationZone.allCases {
            if let index = items(in: zone).firstIndex(where: {
                guard case .shelf(let shelf) = $0 else { return false }
                return shelf.id == shelfID
            }) {
                return (zone, index)
            }
        }
        return nil
    }

    private func topLevelLocation(of dragged: NavigationDraggedItem)
        -> (zone: NavigationZone, index: Int)? {
        switch dragged {
        case .shelf(let shelfID): return shelfLocation(shelfID)
        case .module(let moduleID): return looseModuleLocation(moduleID)
        }
    }

    @discardableResult
    private mutating func remove(_ dragged: NavigationDraggedItem) throws
        -> Bool {
        switch dragged {
        case .shelf(let shelfID):
            guard let location = shelfLocation(shelfID) else {
                throw NavigationLayoutCommandError.missingSource
            }
            var items = items(in: location.zone)
            items.remove(at: location.index)
            setItems(items, in: location.zone)
            return true

        case .module(let moduleID):
            if let location = looseModuleLocation(moduleID) {
                var items = items(in: location.zone)
                items.remove(at: location.index)
                setItems(items, in: location.zone)
                return true
            }
            for zone in NavigationZone.allCases {
                var items = items(in: zone)
                guard let itemIndex = items.firstIndex(where: {
                    $0.moduleIDs.contains(moduleID)
                }), case .shelf(var shelf) = items[itemIndex],
                    let moduleIndex = shelf.moduleIDs.firstIndex(of: moduleID)
                else { continue }

                shelf.moduleIDs.remove(at: moduleIndex)
                if case .user = shelf.id, shelf.moduleIDs.count < 2 {
                    if let remaining = shelf.moduleIDs.first {
                        items[itemIndex] = .module(remaining)
                        setItems(items, in: zone)
                        return false
                    }
                    items.remove(at: itemIndex)
                    setItems(items, in: zone)
                    return true
                }
                items[itemIndex] = .shelf(shelf)
                setItems(items, in: zone)
                return false
            }
            throw NavigationLayoutCommandError.missingSource
        }
    }

    private mutating func insert(_ item: NavigationItem,
                                 in zone: NavigationZone,
                                 at index: Int) {
        var items = items(in: zone)
        items.insert(item, at: index)
        setItems(items, in: zone)
    }
}

struct NavigationDrawerSummary: Equatable, Sendable {
    let moduleCount: Int
    let containsNetworkShelf: Bool

    init(moduleCount: Int, containsNetworkShelf: Bool) {
        self.moduleCount = moduleCount
        self.containsNetworkShelf = containsNetworkShelf
    }

    init(items: [NavigationItem]) {
        moduleCount = items.reduce(0) { $0 + $1.moduleIDs.count }
        containsNetworkShelf = items.contains {
            guard case .shelf(let shelf) = $0 else { return false }
            return shelf.id == .network
        }
    }
}

struct NavigationDragFeedbackState: Equatable, Sendable {
    private(set) var target: NavigationDropTarget?
    private var activated = false

    mutating func enter(_ target: NavigationDropTarget) {
        self.target = target
        activated = false
    }

    mutating func activateSpringLoading(for target: NavigationDropTarget)
        -> Bool {
        guard self.target == target, !activated else { return false }
        activated = true
        return true
    }

    mutating func exit(_ target: NavigationDropTarget) {
        guard self.target == target else { return }
        self.target = nil
        activated = false
    }
}

enum NavigationSpringLoadFlash {
    static let count = 2
    static var animationRepeatCount: Float { Float(count) }
}
