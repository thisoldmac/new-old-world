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
/// **NO CONTINUITY FILE PATH REQUIRES THE MIRROR.** Michelle's ruling,
/// 2026-08-16: *"the mirror required thing is weird. it shouldn't be needed,
/// either from a technical perspective or a product perspective."*
///
/// The scene was a Mirror-era convenience for the question "where in the
/// guest", and it was never the only answer to it. Continuity's edge mapping
/// answers that question continuously and with no scene at all — it is the
/// same geometry that drives the pointer, which is running whenever a file
/// can cross in the first place. So a file crossing to the guest resolves its
/// landing place from the CROSSING, and a scene, when one happens to exist,
/// only makes that answer more specific.
///
/// Concretely: with a scene, a drop is targeted at the window, folder or
/// application under the point, exactly as before. Without one it lands on
/// the guest DESKTOP — the honest, always-available answer, and the one the
/// classic Finder itself would give a drag released over empty screen. What
/// used to happen instead was a refusal reading "file drag needs the Mirror
/// running", which stated an implementation's dependency as if it were a
/// property of the product.
///
/// The one genuine remainder is the OTHER direction, and it is a different
/// question: picking a guest file up by pointing at it needs to know which
/// icon is under the pointer, and no geometry can answer that. It refuses in
/// its own words now, naming what is missing rather than naming the Mirror —
/// and it is not the path a person normally uses, because the selection lane
/// beside it needs no scene either.
@MainActor
enum ContinuityFileDrag {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    /// Why pointing at a guest file cannot pick it up without a picture of
    /// the guest screen. Names the missing capability, never the component
    /// that used to provide it — see the type comment.
    static let noGuestPictureReason =
        "nothing here can say which guest file is under the pointer without "
        + "a picture of the guest screen; select it on the Macintosh and it "
        + "will cross"

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
                        + noGuestPictureReason)
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
                /* THE POINT IS THE CROSSING'S, AND THE SCENE ONLY SHARPENS
                   IT. `point` arrived from the edge mapping — the same
                   arithmetic driving the guest pointer this instant — so
                   this side always knows WHERE on the guest the file is
                   going. What a scene adds is WHAT is drawn there, and that
                   is a refinement, not a prerequisite. See the type comment
                   for the ruling this implements. */
                guard let scene = scene() else {
                    audit(.info, "file drop landing on the guest desktop at "
                        + "\(point.x),\(point.y): this Mac has no picture of "
                        + "the guest screen, so it cannot aim at a window "
                        + "there — the crossing still says where, and the "
                        + "desktop is a real place")
                    return fileTransfer.copyHostPasteboard(pasteboard,
                                                           to: .desktop)
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
