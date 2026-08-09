import Foundation

/// Semantic mutations for a host-owned Finder interior. These operate on the
/// item model, never on guest pixels; the driver decides how the guest Finder
/// receives them.
@MainActor
public protocol FinderInteractionDriver: AnyObject {
    func setFinderSelection(_ names: [String],
                            in container: InteractionPlan.FinderContainer,
                            at point: Point?)
    func openFinderItems(_ names: [String],
                         in container: InteractionPlan.FinderContainer,
                         at point: Point?)
    func renameFinderItem(_ name: String, to newName: String,
                          in container: InteractionPlan.FinderContainer,
                          at point: Point?)
}

public extension FinderInteractionDriver {
    func setFinderSelection(_ names: [String],
                            in container: InteractionPlan.FinderContainer) {
        setFinderSelection(names, in: container, at: nil)
    }

    func openFinderItems(_ names: [String],
                         in container: InteractionPlan.FinderContainer) {
        openFinderItems(names, in: container, at: nil)
    }

    func renameFinderItem(_ name: String, to newName: String,
                          in container: InteractionPlan.FinderContainer) {
        renameFinderItem(name, to: newName, in: container, at: nil)
    }
}
