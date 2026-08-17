import Foundation

/// WHETHER A GENERATION MINTED AFTER ITS EPOCH ENDED MAY BE USED, kept pure
/// so every refusal can be watched without a Macintosh, a drag or an edge.
///
/// The frame this decides about is the one the whole guest→host drag arc
/// turns on. A single-gesture drag of a file nobody selected is named by the
/// Drag Manager to the resident mid-gesture, but the GENERATION a grab must
/// ask for is minted by the guest's application — and the application gets
/// no task time until the Finder's drag loop ends, which on a crossing
/// gesture is the cross itself. So the number for the file in the hand can
/// only ever arrive under an epoch that is already over. Measured on metal
/// 2026-08-16: six crossings, six refusals, zero bytes.
///
/// Admitting it is not a relaxation of the epoch rule; it is the same
/// bounded in-flight window the guest's own grant already runs, read from
/// this side. What is NOT admitted is anything that would make a grab
/// reachable without a gesture to attach it to — see the refusals.
enum ContinuityAfterEpochAdmission: Equatable {
    /// Usable: join it to the crossing in flight, by `dragSeq`.
    case join(ContinuityDragStub)
    /// Not usable, and the sentence saying why. Every one of these is
    /// audited: a frame dropped in silence is indistinguishable from a
    /// guest that never sent one, which is the confusion this arc spent
    /// two attended rounds inside.
    case refused(reason: String)

    static func decide(_ selection: ContinuitySelection,
                       lastEpoch: UInt32?) -> ContinuityAfterEpochAdmission {
        guard selection.namesEndedEpoch else {
            return .refused(reason: "this frame names a live epoch and does "
                + "not belong on the after-epoch path at all")
        }
        guard selection.version == ContinuityContract.version else {
            return .refused(reason: "the Mac reported Continuity version "
                + "\(selection.version.map(String.init) ?? "none") and this "
                + "Mac speaks \(ContinuityContract.version)")
        }
        /* THE EPOCH MUST BE THE ONE THAT JUST ENDED, not merely one that is
           not running. A generation from an older session is a consent this
           Mac has already let go of, and the guest's own grant for it has
           expired or belongs to a gesture nobody is holding. */
        guard let lastEpoch, lastEpoch != 0, selection.epoch == lastEpoch else {
            return .refused(reason: "it names epoch \(selection.epoch) and "
                + "this Mac's last epoch was "
                + "\(lastEpoch.map(String.init) ?? "none")")
        }
        /* ONLY THE DRAG PLANE. A poll cannot run without a live epoch, so a
           selection-sourced frame naming a dead one is a fault rather than
           this case — and a cache of what was selected has no claim on a
           gesture in flight even when it is fresh. */
        guard selection.resolvedSource == .drag else {
            return .refused(reason: "only a drag-sourced generation may name "
                + "an epoch that ended, and this one is a "
                + "\(selection.resolvedSource.rawValue)")
        }
        /* A ZERO IS AN IDENTITY, NOT A GRANT, and an identity arriving here
           is one this Mac already has: the resident published it mid-drag
           over its own channel. Nothing to add, and admitting it would let
           it displace the number the drop is holding for. */
        guard selection.generation != 0 else {
            return .refused(reason: "generation 0 names an identity and no "
                + "grant; the number a grab must ask for is what this frame "
                + "exists to carry")
        }
        guard let seq = selection.dragSeq, seq != 0 else {
            return .refused(reason: "it carries no dragSeq, so nothing says "
                + "which gesture it belongs to — and after the epoch the "
                + "join key is the ONLY thing that can")
        }
        guard let item = selection.item else {
            return .refused(reason: "it names no item; an empty selection "
                + "under a dead epoch is a cache instruction for a cache "
                + "that has already been dropped")
        }
        guard !item.isFolder else {
            return .refused(reason: "\(item.name) is a folder, and folders "
                + "cross in a later slice")
        }
        return .join(ContinuityDragStub(epoch: selection.epoch,
                                        generation: selection.generation,
                                        item: item,
                                        dragSeq: seq))
    }
}
