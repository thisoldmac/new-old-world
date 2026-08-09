import Foundation

/// Semantic mutations for a host-owned Finder interior. These operate on the
/// item model, never on guest pixels; the driver decides how the guest Finder
/// receives them.
@MainActor
public protocol FinderInteractionDriver: AnyObject {
    func setFinderSelection(_ names: [String],
                            in container: InteractionPlan.FinderContainer)
    func openFinderItems(_ names: [String],
                         in container: InteractionPlan.FinderContainer)
    func renameFinderItem(_ name: String, to newName: String,
                          in container: InteractionPlan.FinderContainer)
}
