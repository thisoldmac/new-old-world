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
    private let audit: Audit

    init(audit: @escaping Audit) {
        self.audit = audit
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
            audit(.info, "selection cleared: epoch=\(selection.epoch), "
                + "generation=\(selection.generation) — nothing is selected "
                + "on the Mac")
            return
        }
        stub = ContinuityDragStub(epoch: selection.epoch,
                                  generation: selection.generation,
                                  item: item)
        audit(.info, "selection cached: epoch=\(selection.epoch), "
            + "generation=\(selection.generation), name=\(item.name), "
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
