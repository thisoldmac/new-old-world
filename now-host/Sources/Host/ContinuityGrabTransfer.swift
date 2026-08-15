import AppKit
import Foundation
import MirrorKitUI
import UniformTypeIdentifiers

/// Turns one bound selection stub into a native macOS file promise, and
/// redeems it over `continuity.grab`.
///
/// It is a sibling of `MirrorFileTransferModel`'s promise half rather than an
/// extension of it because the two answer to different authorities: that one
/// resolves a scene item inside the Files share, this one redeems a gesture's
/// consent for one generation. What they SHARE is the wire — the grab is
/// served down the ordinary `file.begin` / bulk / `file.end` lane, through the
/// same receive machinery and the same `FileConverter` finalization, so a
/// grabbed file resumes, reports and materializes exactly as a Files pull
/// does. There is no second bulk receiver here and there must never be one.
@MainActor
final class ContinuityGrabTransfer: NSObject, ObservableObject,
                                    NSFilePromiseProviderDelegate {
    typealias Audit = (HostLog.LogLevel, String) -> Void

    /// The one place a grab's failure becomes an error macOS can show. Each
    /// case is also audited by name where it is raised.
    enum GrabError: LocalizedError, Equatable {
        case noStub
        case busy
        case wire(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .noStub:
                return "That dragged item is no longer available on "
                    + MachineNaming.simpleReference + "."
            case .busy:
                return "Another file is already crossing from "
                    + MachineNaming.simpleReference + "."
            case .wire(let code, let message):
                return code == "stale-selection"
                    ? MachineNaming.startingSentence(
                        "the selection on \(MachineNaming.simpleReference) changed before the "
                        + "file could be copied.")
                    : message
            }
        }
    }

    @Published private(set) var notice: String?

    /// The wire, as one function. Named rather than reached through the
    /// listener so a test can watch a refusal arrive without a socket — the
    /// refusal paths are the half v1 shipped silent, and they must be
    /// exercisable.
    typealias GrabRequest = (
        _ epoch: UInt32,
        _ generation: UInt32,
        _ container: String?,
        _ stagingDirectory: URL,
        _ completion: @escaping (Result<GuestListener.FileDelivery,
                                        GuestListener.FileFailure>) -> Void
    ) -> Void

    private let grab: GrabRequest
    private let audit: Audit
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.newoldworld.continuity.grab"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// One grab in flight at a time, for the same reason the Mirror lane
    /// holds `promiseInFlight`: the wire has one bulk lane and a second
    /// redemption would be refused by the listener with a less specific
    /// word than this one.
    private var grabInFlight = false

    init(grab: @escaping GrabRequest, audit: Audit? = nil) {
        self.grab = grab
        self.audit = audit ?? { HostLog.shared.write($0, "continuity", $1) }
        super.init()
    }

    convenience init(listener: GuestListener, audit: Audit? = nil) {
        self.init(grab: { [weak listener] epoch, generation, container,
                          staging, completion in
            guard let listener else {
                completion(.failure(.init(
                    code: "disconnected",
                    message: "This Mac is shutting down.")))
                return
            }
            listener.grabContinuityFile(
                epoch: epoch, generation: generation, container: container,
                stagingDirectory: staging, completion: completion)
        }, audit: audit)
    }

    var isBusy: Bool { grabInFlight }

    /// The host-side stub AppKit drags. No bytes cross until something in
    /// macOS accepts the promise on release.
    func promise(for stub: ContinuityDragStub) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(
            fileType: stub.utType.identifier, delegate: self)
        provider.userInfo = stub
        return provider
    }

    /// The drag image. Stub icon extraction from the guest's desktop
    /// database is declared by the contract and deliberately unsent, so this
    /// is the generic icon for the type the OSType named — honest about
    /// being generic rather than a picture of the wrong file.
    func dragItem(for stub: ContinuityDragStub) -> HostFileDragItem {
        HostFileDragItem(writer: promise(for: stub),
                         image: NSWorkspace.shared.icon(for: stub.utType))
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        _ = fileType
        guard let stub = provider.userInfo as? ContinuityDragStub else {
            return "Untitled"
        }
        return stub.localName
    }

    func operationQueue(for provider: NSFilePromiseProvider)
        -> OperationQueue { promiseQueue }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let stub = provider.userInfo as? ContinuityDragStub
        let completion = GrabCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                completion.finish(GrabError.noStub)
                return
            }
            guard let stub else {
                self.audit(.error, "grab refused: the dropped promise carried "
                    + "no selection stub, so there is nothing to ask the Mac "
                    + "for")
                completion.finish(GrabError.noStub)
                return
            }
            self.redeem(stub, to: url, completion: completion)
        }
    }

    private func redeem(_ stub: ContinuityDragStub, to url: URL,
                        completion: GrabCompletion) {
        guard !grabInFlight else {
            audit(.warn, "grab refused: another grab is already in flight "
                + "(epoch=\(stub.epoch), generation=\(stub.generation))")
            completion.finish(GrabError.busy)
            return
        }
        grabInFlight = true
        notice = nil
        audit(.info, "grab requested: epoch=\(stub.epoch), "
            + "generation=\(stub.generation), name=\(stub.item.name), "
            + "container=\(stub.wireContainer ?? "auto")")
        grab(stub.epoch, stub.generation, stub.wireContainer,
             url.deletingLastPathComponent()) { [weak self] result in
            guard let self else {
                completion.finish(GrabError.noStub)
                return
            }
            switch result {
            case .failure(let failure):
                self.grabInFlight = false
                /* Named, not counted. `stale-selection` and `bad-epoch` are
                   the guest refusing a grant it will not honour, and they
                   read identically to a dead wire unless the code is in the
                   line. */
                self.audit(.error, "grab refused by the Mac: "
                    + "code=\(failure.code), reason=\(failure.message), "
                    + "epoch=\(stub.epoch), generation=\(stub.generation)")
                self.notice = GrabError.wire(code: failure.code,
                                             message: failure.message)
                    .localizedDescription
                completion.finish(GrabError.wire(code: failure.code,
                                                 message: failure.message))
            case .success(let file):
                self.materialize(file, stub: stub, to: url,
                                 completion: completion)
            }
        }
    }

    private func materialize(_ file: GuestListener.FileDelivery,
                             stub: ContinuityDragStub,
                             to url: URL,
                             completion: GrabCompletion) {
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    let note = try FileConverter.materialize(
                        name: file.name, container: file.container,
                        fileType: file.fileType, staged: file.staged, to: url)
                    if let modified = file.modified,
                       let date = ClassicDate.date(from: modified) {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: date],
                            ofItemAtPath: url.path)
                    }
                    return note
                }
            }.value
            guard let self else { return }
            self.grabInFlight = false
            switch outcome {
            case .success(let note):
                self.audit(.info, "grab completed: name=\(file.name), "
                    + "generation=\(stub.generation), "
                    + "container=\(file.container), "
                    + "integrity=\(file.crc32 == nil ? "unchecked" : "crc32"), "
                    + "conversion=\(note ?? "none")")
                self.notice = note.map {
                    "Copied \(stub.item.name) to this Mac (\($0))."
                } ?? "Copied \(stub.item.name) to this Mac."
                completion.finish(nil)
            case .failure(let error):
                self.audit(.error, "grab arrived but could not be written: "
                    + "name=\(file.name), reason=\(error.localizedDescription)")
                self.notice = error.localizedDescription
                completion.finish(error)
            }
        }
    }

    /// AppKit hands the completion in from its own queue; this box carries it
    /// back to the main actor without pretending the closure is Sendable.
    private final class GrabCompletion: @unchecked Sendable {
        private let body: (Error?) -> Void
        init(_ body: @escaping (Error?) -> Void) { self.body = body }
        @MainActor func finish(_ error: Error?) { body(error) }
    }
}
