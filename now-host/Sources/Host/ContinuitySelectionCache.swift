import AppKit
import Foundation
import UniformTypeIdentifiers

/// One selection stub, bound to the epoch and generation that named it.
///
/// The pair is carried together everywhere because a grab is only honest
/// with both: the epoch is the consent's lifetime and the generation is the
/// exact item a person was looking at. Splitting them into two fields on two
/// objects is how a grant outlives what it was granted for.
struct ContinuityDragStub: Equatable, Sendable {
    var epoch: UInt32
    var generation: UInt32
    var item: ContinuitySelection.Item

    var isFolder: Bool { item.isFolder }

    /// The name macOS should show while the promise is unfulfilled, and the
    /// name the file lands under. Classic names use HFS rules.
    var localName: String {
        let name = LocalFileName.sanitized(item.name)
        return item.creator == "APPL" || item.fileType == "APPL"
            ? (name.lowercased().hasSuffix(".bin") ? name : name + ".bin")
            : name
    }

    /// Whether the bytes must cross as MacBinary to survive. An application
    /// is nothing without its resource fork, so it takes the same container
    /// the Mirror lane already uses for one.
    var wireContainer: String? {
        item.fileType == "APPL" ? "macbinary" : nil
    }

    /// The best type this Mac can name from four classic bytes.
    ///
    /// Deliberately small: the guest sends an OSType, not a UTI, and a wrong
    /// guess costs a Finder icon rather than a byte. Anything unmapped falls
    /// through to the name's extension and then to `.data`, which is what an
    /// unlabelled classic file honestly is over here.
    var utType: UTType {
        if let fileType = item.fileType, let mapped = Self.byOSType[fileType] {
            return mapped
        }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty, let byExtension = UTType(filenameExtension: ext) {
            return byExtension
        }
        return .data
    }

    private static let byOSType: [String: UTType] = [
        "TEXT": .plainText,
        "ttro": .plainText,
        "PDF ": .pdf,
        "GIFf": .gif,
        "JPEG": .jpeg,
        "PNGf": .png,
        "TIFF": .tiff,
        "MooV": .quickTimeMovie,
        "AIFF": .aiff,
        "ZIP ": .zip,
        "APPL": .data,
    ]
}

/// WHICH published selection this is, and WHEN this Mac learned of it.
///
/// The generation alone answers "is this the same selection"; it cannot
/// answer "did this arrive because of the press I am holding". Both
/// questions are asked at the cross, seconds apart from the press, and the
/// second one is the difference between the file a person dragged and the
/// file they dragged a minute ago.
struct ContinuitySelectionMark: Equatable, Sendable {
    var epoch: UInt32
    var generation: UInt32
    /// `ProcessInfo.systemUptime` when the cache applied it. Uptime rather
    /// than a wall clock: this is only ever compared with another reading
    /// of the same clock taken seconds earlier, and a wall clock can move
    /// under it.
    var appliedAt: TimeInterval
    /// Which gesture produced the generation. A `drag` mark is the item the
    /// Drag Manager itself handed the guest at drag begin, so it needs no
    /// clock comparison to be attributed to the gesture in flight — see
    /// `ContinuitySelectionBind.decide`.
    var source: ContinuitySelection.Source = .selection

    /// The same published selection, whenever either side heard about it.
    func isSameSelection(as other: ContinuitySelectionMark) -> Bool {
        epoch == other.epoch && generation == other.generation
    }
}

/// What a cross-edge drag should be bound to, decided at the cross rather
/// than at the press.
///
/// THE PRESS IS THE WRONG MOMENT AND ALWAYS WAS. The host binds on its own
/// mouse-down, which is before the guest has even applied that down — so a
/// press that selects the file it drags binds whatever the last gesture
/// left cached. On metal at 2026-08-15 17:19 that shipped `hello.txt` while
/// Michelle watched `main.c` leave.
///
/// The cross is seconds later and is the first moment both facts exist: the
/// press, and whatever the guest published under it.
enum ContinuitySelectionBind: Equatable {
    /// THE DRAG ITSELF, named by the guest at the moment it began.
    ///
    /// This is the case that ends the ritual. Every other outcome below is
    /// reasoning about a CACHE of what a person had selected before they
    /// pressed — necessarily so, because nothing could see the drag. A
    /// drag-sourced generation is not a better cache; it is a different
    /// kind of fact, read from a live DragRef in the dragging application's
    /// own context, and it names the file in the hand rather than the file
    /// in the selection. Single-gesture press-and-drag of a file that was
    /// never selected lands here, and so does a stale cache disagreeing
    /// with a fresh drag.
    ///
    /// It needs no clock comparison, which is the property worth stating:
    /// `adopted` below attributes an arrival to this press by arguing that
    /// nothing else could have caused it, and that argument is sound but
    /// circumstantial. A drag-sourced generation carries its own
    /// attribution — the gesture is what published it.
    case dragged(ContinuitySelectionMark)
    /// The cache holds exactly what the press bound. The two-step ritual —
    /// select, release, press again, drag — lands here and must keep
    /// working, because it is the one that works today.
    case bound(ContinuitySelectionMark)
    /// A selection published WHILE THIS PRESS WAS HELD, which nothing else
    /// could have caused. This is the single-gesture select-and-drag, and
    /// adopting it is what makes that gesture bind the right file rather
    /// than nothing (or, worse, the last one).
    case adopted(ContinuitySelectionMark)
    /// The selection moved under this press and this Mac cannot attribute
    /// the move to it. Refusing is not a lesser outcome than guessing: the
    /// person gets a snap-back and a line naming both, instead of a file
    /// they did not ask for arriving on their desktop.
    case superseded(pressed: ContinuitySelectionMark,
                    current: ContinuitySelectionMark)
    /// The cache no longer says anything, and the press stands.
    ///
    /// This is the ORDINARY cross, not a corner: crossing back is what ends
    /// the epoch, and the epoch ending drops the cache — measured on metal
    /// 2026-08-14, where `selection dropped: the Continuity epoch ended`
    /// fired as the pointer crossed. A cleared cache contradicts nothing, so
    /// treating it as a refusal would refuse every drag that works today.
    /// The guest's own grant hold is what redeems this one.
    case unchallenged(ContinuitySelectionMark)
    /// Nothing bindable at the cross.
    case nothing

    /// The whole decision, kept pure so the wrong-file case can be watched
    /// failing without a Macintosh, a drag, or an edge.
    ///
    /// `downSentAt` is when the press went out on the wire, not when the
    /// guest applied it — this Mac cannot know the latter, and the error is
    /// in the safe direction: an arrival stamped before the down cannot be
    /// claimed by the press, so it refuses rather than adopts.
    static func decide(pressed: ContinuitySelectionMark?,
                       current: ContinuitySelectionMark?,
                       downSentAt: TimeInterval) -> ContinuitySelectionBind {
        guard let current else {
            return pressed.map(ContinuitySelectionBind.unchallenged)
                ?? .nothing
        }
        /* THE DRAG WINS, AND IT WINS FIRST. Every test below this line is
           an argument about a cache; this one is a report of the gesture.
           It is placed above `bound` as well as above `superseded` on
           purpose: a drag that happens to name the same generation the
           press was made under is still a drag, and saying so is what lets
           one audit line distinguish the ritual working from the ritual
           being unnecessary. */
        if current.source == .drag {
            return .dragged(current)
        }
        if let pressed, pressed.isSameSelection(as: current) {
            return .bound(current)
        }
        if current.appliedAt > downSentAt {
            return .adopted(current)
        }
        guard let pressed else { return .nothing }
        return .superseded(pressed: pressed, current: current)
    }
}

/// The host's copy of what the person at the classic Mac has selected.
///
/// It exists because the guest is unqueryable during a drag — the Finder
/// sits in its own nested Drag Manager loop — so everything the cross needs
/// has to be on this side of the wire before any press. The cache holds
/// exactly one stub: the contract sends the first item of a selection and
/// nothing else, and a second slot would be a multi-item drag pretending to
/// exist.
@MainActor
final class ContinuitySelectionCache {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    /// Why a press could not be bound to something draggable. Every case is
    /// audited by name: v1's attended pass produced no per-direction symptom
    /// because each of these was a silent nil.
    enum Unusable: Error, Equatable {
        case noSelection
        case folderNotYet(String)
        case otherEpoch(stub: UInt32, active: UInt32)

        var message: String {
            switch self {
            case .noSelection:
                return "no guest file is bound to this press: the Mac has "
                    + "published no Finder selection for this epoch"
            case .folderNotYet(let name):
                return "no guest file is bound to this press: \(name) is a "
                    + "folder, and folders cross in a later slice "
                    + "(folder-not-yet)"
            case .otherEpoch(let stub, let active):
                return "no guest file is bound to this press: the cached "
                    + "selection names epoch \(stub) while this Mac owns "
                    + "epoch \(active)"
            }
        }
    }

    private(set) var stub: ContinuityDragStub?
    /// When this Mac applied what it currently holds. See
    /// `ContinuitySelectionMark`; nil exactly when `stub` is nil.
    private(set) var mark: ContinuitySelectionMark?
    private let audit: Audit
    private let now: () -> TimeInterval

    init(audit: @escaping Audit,
         now: @escaping () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.audit = audit
        self.now = now
    }

    /// Applies one `continuity.selection`. `activeEpoch` is what this Mac
    /// believes it owns; a stub for anything else is recorded and dropped
    /// rather than cached, because caching it would make a grab reachable
    /// under an epoch nobody consented in.
    func apply(_ selection: ContinuitySelection, activeEpoch: UInt32) {
        guard selection.version == ContinuityContract.version else {
            audit(.warn, "selection ignored: the Mac reported Continuity "
                + "version \(selection.version.map(String.init) ?? "none") "
                + "and this Mac speaks \(ContinuityContract.version)")
            return
        }
        guard selection.epoch == activeEpoch, activeEpoch != 0 else {
            audit(.warn, "selection ignored: it names epoch "
                + "\(selection.epoch) while this Mac owns epoch "
                + "\(activeEpoch)")
            return
        }
        guard let item = selection.item else {
            stub = nil
            mark = nil
            audit(.info, "selection cleared: epoch=\(selection.epoch), "
                + "generation=\(selection.generation) — nothing is selected "
                + "on the Mac")
            return
        }
        stub = ContinuityDragStub(epoch: selection.epoch,
                                  generation: selection.generation,
                                  item: item)
        mark = ContinuitySelectionMark(epoch: selection.epoch,
                                       generation: selection.generation,
                                       appliedAt: now(),
                                       source: selection.resolvedSource)
        audit(.info, "selection cached: epoch=\(selection.epoch), "
            + "generation=\(selection.generation), "
            + "source=\(selection.resolvedSource.rawValue), "
            + "name=\(item.name), "
            + "type=\(item.fileType ?? "none"), "
            + "creator=\(item.creator ?? "none"), "
            + "dataSize=\(item.dataSize ?? 0), "
            + "resourceSize=\(item.resourceSize ?? 0), "
            + "folder=\(item.isFolder ? 1 : 0)")
    }

    /// Ends every grant this cache could still name. Continuity ending
    /// revokes consent by contract, so the stub cannot outlive its epoch.
    func clear(reason: String) {
        guard stub != nil else { return }
        stub = nil
        mark = nil
        audit(.info, "selection dropped: \(reason)")
    }

    /// The stub a press may be bound to, or the named reason it may not.
    func bindable(activeEpoch: UInt32) -> Result<ContinuityDragStub, Unusable> {
        guard let stub else { return .failure(.noSelection) }
        guard stub.epoch == activeEpoch else {
            return .failure(.otherEpoch(stub: stub.epoch, active: activeEpoch))
        }
        guard !stub.isFolder else {
            return .failure(.folderNotYet(stub.item.name))
        }
        return .success(stub)
    }
}
