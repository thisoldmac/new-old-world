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

/// One navigation row is both a drag source and a continuous destination.
/// Its outer bands insert before or after the row while its middle activates
/// the row's own combine/shelf destination. A small dead band keeps tiny
/// pointer movements from flickering between adjacent targets.
struct NavigationRowDropTargets: Equatable, Sendable {
    enum Feedback: Equatable, Sendable {
        case insertionBefore
        case center
        case insertionAfter
    }

    /// Share of the row height given to each insertion band once the pointer
    /// has settled on the row. This was a third each, which left the row's
    /// own destination — the only spring-loadable one — about twelve points
    /// tall on a standard sidebar row. A drag cannot be held still inside
    /// that for the dwell spring loading needs, and Finder gives a folder a
    /// far more generous "into" zone than the gaps either side of it.
    static let insertionBandFraction: CGFloat = 0.2

    /// Narrower still on first contact. `previewDrop` applies an insertion's
    /// move live, so resolving one on the frame the pointer arrives reorders
    /// the stack out from under a pointer that has not moved — which is what
    /// "the connections shelf moves itself out of the way" describes.
    static let firstContactInsertionBandFraction: CGFloat = 0.1

    let before: NavigationDropTarget
    let center: NavigationDropTarget
    let after: NavigationDropTarget

    func target(at verticalOffset: CGFloat, height: CGFloat,
                previous: NavigationDropTarget?) -> NavigationDropTarget {
        guard height > 0 else { return center }
        let band = height * (previous == nil
            ? Self.firstContactInsertionBandFraction
            : Self.insertionBandFraction)
        let firstBoundary = band
        let secondBoundary = height - band
        let hysteresis = min(4, max(2, height * 0.06))

        if previous == before,
           verticalOffset <= firstBoundary + hysteresis {
            return before
        }
        if previous == center,
           verticalOffset >= firstBoundary - hysteresis,
           verticalOffset <= secondBoundary + hysteresis {
            return center
        }
        if previous == after,
           verticalOffset >= secondBoundary - hysteresis {
            return after
        }

        if verticalOffset < firstBoundary { return before }
        if verticalOffset > secondBoundary { return after }
        return center
    }

    func candidates(at verticalOffset: CGFloat, height: CGFloat,
                    previous: NavigationDropTarget?) -> [NavigationDropTarget] {
        let preferred = target(at: verticalOffset, height: height,
                               previous: previous)
        let nearestInsertion = verticalOffset < height / 2 ? before : after
        let fartherInsertion = nearestInsertion == before ? after : before
        var candidates = [preferred]
        for candidate in [center, nearestInsertion, fartherInsertion]
        where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    func acceptedTarget(
        at verticalOffset: CGFloat,
        height: CGFloat,
        previous: NavigationDropTarget?,
        accepting: (NavigationDropTarget) -> Bool
    ) -> NavigationDropTarget? {
        candidates(at: verticalOffset, height: height, previous: previous)
            .first(where: accepting)
    }

    func feedback(for target: NavigationDropTarget) -> Feedback {
        if target == before { return .insertionBefore }
        if target == after { return .insertionAfter }
        return .center
    }

    /// The destination this ROW can spring-load into, if the drag may use it.
    ///
    /// Arming is asked of the row rather than of the band under the pointer.
    /// It used to be asked of the resolved band, and an insertion band is
    /// never spring-loadable — so a drag sitting anywhere but the row's
    /// middle answered AppKit with "no spring loading here", and each
    /// revocation restarts the hover dwell from zero. That is the
    /// best-supported reason nobody has ever seen the double flash fire.
    func springLoadingTarget(
        accepting: (NavigationDropTarget) -> Bool
    ) -> NavigationDropTarget? {
        [center, before, after].first {
            $0.supportsSpringLoading && accepting($0)
        }
    }
}

enum NavigationLayoutCommand: Equatable, Sendable {
    case move(NavigationDraggedItem, to: NavigationZone, index: Int)
    case combine(moduleID: String, with: String, shelfID: UUID, title: String)
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
        if case .module(let moduleID) = dragged,
           layout.isFixedModuleHero(moduleID) {
            return nil
        }

        switch target {
        case .zone(let zone, let index):
            guard (0...layout.items(in: zone).count).contains(index) else {
                return nil
            }
            if case .shelf(let shelfID) = dragged,
               !shelfID.canOccupy(zone) {
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
                            shelfID: shelfID,
                            title: layout.nextNewShelfTitle)

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

/// The non-persisted arrangement shown while a native drag crosses an
/// insertion target. Every preview is derived from the layout at drag start,
/// so moving back and forth never compounds index adjustments. Combining two
/// loose modules waits for drop because replacing both hit-tested rows with a
/// new shelf would remove the active destination from beneath the pointer.
struct NavigationDragPreview: Equatable, Sendable {
    let dragged: NavigationDraggedItem
    let target: NavigationDropTarget
    let layout: NavigationLayout

    init?(
        dragged: NavigationDraggedItem,
        target: NavigationDropTarget,
        baseline: NavigationLayout,
        makeShelfID: () -> UUID = UUID.init
    ) {
        guard let command = NavigationDragCoordinator.command(
            for: dragged, droppingOn: target, in: baseline,
            makeShelfID: makeShelfID) else { return nil }

        let previewLayout: NavigationLayout
        switch command {
        case .combine:
            previewLayout = baseline
        case .insert:
            guard let changed = try? baseline.applying(command) else {
                return nil
            }
            // Reordering a shelf's own tabs is worth showing live. Lifting a
            // module OUT of the top-level stack is not: its row closes up,
            // every row below rises, and the shelf the pointer is resting on
            // moves out from under it — the "connections shelf gets out of
            // the way" report, and a spring-load dwell that can never finish
            // because the drag keeps leaving the row. Nothing is lost by
            // waiting: a collapsed shelf shows no tabs to preview into, and
            // the row's centre highlight already says where the module lands.
            previewLayout = baseline.topLevelLocation(of: dragged) == nil
                ? changed : baseline
        case .move:
            // A move is still validated — a target the layout cannot accept
            // must not preview at all — but it is not SHOWN. The insertion
            // line already says where the row lands, and applying the move
            // live is the same defect the `.insert` guard above refuses:
            // every row between the removal point and the insertion point
            // shifts, the row the pointer is resting on included. That is a
            // real `draggingExited`, and AppKit restarts the spring-load
            // dwell from zero each time — so the shelf a drag is aimed at
            // can never be dwelled on. Finder shows a line and leaves its
            // sidebar alone for the same reason.
            //
            // Freezing the presentation at the baseline also collapses two
            // index spaces into one: the rows build their drop targets from
            // the layout the sidebar RENDERS, while every command resolves
            // against the baseline. See
            // `testFooterRowTargetsAndCommandsShareOneIndexSpace`.
            guard (try? baseline.applying(command)) != nil else {
                return nil
            }
            previewLayout = baseline
        }

        self.dragged = dragged
        self.target = target
        layout = previewLayout
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
               !shelfID.canOccupy(zone) {
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

        case .combine(let moduleID, let targetID, let shelfUUID, let title):
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
                id: shelfID, title: title,
                moduleIDs: [targetID, moduleID]))
            changed.setItems(items, in: target.zone)

        case .insert(let moduleID, let shelfID, let beforeModuleID):
            guard changed.contains(.module(moduleID)) else {
                throw NavigationLayoutCommandError.missingSource
            }
            guard let existing = changed.shelf(id: shelfID),
                  beforeModuleID.map(existing.moduleIDs.contains) ?? true else {
                throw NavigationLayoutCommandError.missingTarget
            }
            if existing.moduleIDs.contains(moduleID) {
                guard let location = changed.shelfLocation(shelfID) else {
                    throw NavigationLayoutCommandError.missingTarget
                }
                var destination = existing
                destination.moduleIDs.removeAll { $0 == moduleID }
                let index = beforeModuleID.flatMap {
                    destination.moduleIDs.firstIndex(of: $0)
                } ?? destination.moduleIDs.endIndex
                destination.moduleIDs.insert(moduleID, at: index)
                var items = changed.items(in: location.zone)
                items[location.index] = .shelf(destination)
                changed.setItems(items, in: location.zone)
                break
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

    var nextNewShelfTitle: String {
        let titles = Set(NavigationZone.allCases
            .flatMap { items(in: $0) }
            .compactMap { item -> String? in
                guard case .shelf(let shelf) = item,
                      case .user = shelf.id else { return nil }
                return shelf.title
            })
        guard titles.contains("New Shelf") else { return "New Shelf" }
        var suffix = 2
        while titles.contains("New Shelf \(suffix)") { suffix += 1 }
        return "New Shelf \(suffix)"
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

    fileprivate func topLevelLocation(of dragged: NavigationDraggedItem)
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

enum NavigationSidebarDropResolver {
    /// Where a point no row's own view covers belongs.
    ///
    /// The pinned stack's height is asked for rather than inferred, because
    /// the two stacks are not two halves of the canvas: the footer is only
    /// as tall as its rows need and the list gets everything else. Splitting
    /// the canvas down the middle put the footer's chrome — its divider, its
    /// 8/5pt padding, the gaps around its rows — on `.zone(.lower, index: 0)`,
    /// which PREPENDS. Connections is the last row of that stack, so
    /// brushing the padding above it shoved it down a full row before the
    /// pointer ever reached the row, and a spring-load dwell cannot survive
    /// its destination moving. The upper half never had this problem because
    /// its fallback appends; this is that same append, mirrored.
    static func target(distanceFromTop: CGFloat, height: CGFloat,
                       upperItemCount: Int,
                       lowerItemCount: Int,
                       pinnedStackHeight: CGFloat) -> NavigationDropTarget {
        let stackHeight = min(max(0, pinnedStackHeight), height)
        let stackTop = height - stackHeight
        guard stackHeight > 0, distanceFromTop >= stackTop else {
            return .zone(.upper, index: upperItemCount)
        }
        guard lowerItemCount > 0 else { return .zone(.lower, index: 0) }
        // Inside the stack the rows carry their own drop views, so what is
        // left over here is the chrome around them: above the first row
        // means before it, below the last means after it.
        let share = (distanceFromTop - stackTop) / stackHeight
        let index = Int((share * CGFloat(lowerItemCount)).rounded())
        return .zone(.lower, index: min(max(index, 0), lowerItemCount))
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

struct NavigationSpringLoadActivation {
    static func shouldActivate(
        activated: Bool,
        acceptedTarget: NavigationDropTarget?,
        feedback: inout NavigationDragFeedbackState
    ) -> Bool {
        guard activated, let target = acceptedTarget,
              target.supportsSpringLoading else { return false }
        return feedback.activateSpringLoading(for: target)
    }
}

extension NavigationDropTarget {
    var supportsSpringLoading: Bool {
        switch self {
        case .module: true
        case .zone(.drawer, _): true
        case .shelf: true
        case .zone: false
        }
    }
}
