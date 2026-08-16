import AppKit
import MirrorKit
import MirrorKitUI
import UniformTypeIdentifiers

/// Installs the cross-edge file seam on the app-owned edge controller.
///
/// It used to live inside `MirrorHostModuleRuntime`'s lazy `source`, which
/// tied the drop destination's existence to somebody having opened the
/// Mirror page. After the module split, edge mode starts from the Continuity
/// module and Mirror's runtime may never be constructed — so
/// `refreshFileEdge`'s "both callbacks installed" requirement was never met
/// and NO AppKit drop destination existed at all. Configuration therefore
/// belongs to the lifetime of edge mode, which is the app's, not a page's.
///
/// What still depends on the Mirror is the SCENE: both directions resolve a
/// guest item or a drop target by point against the live scene, and nothing
/// else on this side has one. That dependency is now explicit and named
/// rather than structural and silent: the destination exists, and a drop
/// arriving with no scene is refused with a line that says why.
@MainActor
enum ContinuityFileDrag {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    /// The one sentence the human and the log both get when the seam is
    /// alive but has nothing to aim at. Stated once so the two callbacks
    /// cannot drift into describing the same gap differently.
    static let noSceneReason =
        "file drag needs the Mirror running: this Mac has no scene of the "
        + "guest screen, so there is nothing to resolve a point against"

    static func configure(
        edge: ContinuityEdgeController,
        fileTransfer: MirrorFileTransferModel,
        scene: @escaping () -> MirrorKit.Scene?,
        selection: (() -> Result<ContinuityDragStub,
                                 ContinuitySelectionCache.Unusable>)? = nil,
        selectionMark: (() -> ContinuitySelectionMark?)? = nil,
        grab: ContinuityGrabTransfer? = nil,
        audit: @escaping Audit = {
            HostLog.shared.write($0, "continuity", $1)
        },
        /// Where a REFUSAL — as opposed to any terminal outcome — is said
        /// out loud somewhere a person is actually looking mid-drag, not
        /// only on the Continuity page's status line nobody watches while
        /// their cursor is over Finder or the guest window. Wired by
        /// `HostAppState` to a system notification plus the menu-bar
        /// flash, the same pair `ScreenHostModuleRuntime` uses for a
        /// screenshot outcome. Optional so every existing test that builds
        /// this seam without one keeps behaving exactly as before.
        refusal: ((String) -> Void)? = nil
    ) {
        if let selection, let grab {
            /* Every terminal grab outcome — refused or completed — becomes
               the status line a person is actually looking at. Without
               this, `grab.notice` was published to nobody: the page draws
               `edge.status`, and a wrong-file refusal
               (`file.refuse code=stale-selection`) ended with the drag
               simply vanishing, audited but never said out loud. */
            grab.outcomeSink = { [weak edge] message in
                edge?.reportFileGrabOutcome(message)
            }
            /* The narrower sibling: only the refusal half of the same
               sentence, handed to whichever surfacing `refusal` was built
               with. See the parameter's own comment for why this is a
               second sink rather than a filter downstream of the first. */
            grab.refusalSink = refusal
            /* The stub lane is installed only when both halves exist: a
               binding with nothing to redeem it would drag a promise that
               can never be fulfilled, which is worse than not claiming the
               press at all. */
            edge.configureSelectionDragging(
                /* Two closures because the controller asks the two
                   questions at two moments: the mark at the press, so the
                   cross can tell a selection this press created from one it
                   inherited, and the item only once that is settled. A lane
                   wired without a mark reader would decide every cross
                   against `nil` and refuse the ordinary two-step ritual. */
                guestSelectionMark: { selectionMark?() },
                guestSelectionItem: { [weak grab] in
                    guard let grab else {
                        audit(.error, "no guest file can be picked up: the "
                            + "grab lane is gone")
                        return nil
                    }
                    switch selection() {
                    case .failure(let unusable):
                        audit(.info, unusable.message)
                        return nil
                    case .success(let stub):
                        audit(.info, "press bound to the guest selection: "
                            + "epoch=\(stub.epoch), "
                            + "generation=\(stub.generation), "
                            + "name=\(stub.item.name), "
                            + "type=\(stub.utType.identifier)")
                        return grab.dragItem(for: stub)
                    }
                })
        }
        edge.configureFileDragging(
            guestFileAtPoint: { [weak fileTransfer] point in
                guard let fileTransfer else {
                    audit(.error, "no guest file can be picked up: the host "
                        + "file transfer model is gone")
                    return nil
                }
                guard let scene = scene() else {
                    audit(.info, "no guest file can be picked up: "
                        + noSceneReason)
                    return nil
                }
                guard case .success(let subject) = DragTargeting.subject(
                    scene, x: point.x, y: point.y) else {
                    audit(.info, "no guest file at \(point.x),\(point.y): "
                        + "nothing draggable is there")
                    return nil
                }
                switch CrossMachineFileTargeting.source(subject, in: scene) {
                case .failure(let refusal):
                    audit(.info, "guest file refused: \(refusal.message)")
                    return nil
                case .success(let guestFile):
                    guard let promise = fileTransfer.promise(for: guestFile)
                    else {
                        audit(.warn, "guest file \(guestFile.file.name) could "
                            + "not become a host file promise")
                        return nil
                    }
                    return HostFileDragItem(
                        writer: promise, subject: subject, scene: scene)
                }
            },
            hostFilesDropped: { [weak fileTransfer] pasteboard, point in
                guard let fileTransfer else {
                    audit(.error, "file drop refused: the host file transfer "
                        + "model is gone")
                    return false
                }
                guard let scene = scene() else {
                    audit(.warn, "file drop refused: " + noSceneReason)
                    /* The direction a file dragged FROM this Mac TOWARD
                       the guest travels: refused here because no scene
                       exists. Left unsurfaced it reads as "host→guest is
                       not working" with nothing on screen to say why —
                       the same silent-refusal shape as the grab side, one
                       edge over. Same sentence, same surfacing. */
                    refusal?(noSceneReason)
                    return false
                }
                switch CrossMachineFileTargeting.destination(
                    scene, x: point.x, y: point.y) {
                case .failure(let refusal):
                    audit(.warn, "file drop refused: \(refusal.message)")
                    return false
                case .success(let target):
                    return fileTransfer.copyHostPasteboard(
                        pasteboard, to: target)
                }
            })
    }
}
