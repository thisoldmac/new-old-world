import AppKit
import Foundation
import MirrorKit
import UniformTypeIdentifiers

/// Host ownership for file crossings that begin or end on the live Mirror.
/// The scene supplies semantic identities; this object owns conversion,
/// file promises, the one bulk lane, and the status a person can inspect.
@MainActor
final class MirrorFileTransferModel: NSObject, ObservableObject,
                                     NSFilePromiseProviderDelegate {
    struct Activity: Equatable {
        enum Direction: Equatable { case toGuest, toHost }

        var name: String
        var direction: Direction
        var received: Int
        var expected: Int
        var awaitingSettlement = false

        var label: String {
            switch direction {
            case .toGuest: return "Copying \(name) to \(MachineNaming.simpleReference)"
            case .toHost: return "Copying \(name) to this Mac"
            }
        }
    }

    private final class PromiseCompletion: @unchecked Sendable {
        private let body: (Error?) -> Void
        init(_ body: @escaping (Error?) -> Void) { self.body = body }
        @MainActor func finish(_ error: Error?) { body(error) }
    }

    private struct PendingHostFile {
        var url: URL
        var target: CrossMachineFileTargeting.Destination
        var promiseBatch: PromiseBatch?
    }

    /// One AppKit promise receiver may materialize several sibling files in
    /// one directory. The directory belongs to the batch, not to its first
    /// callback; deleting it after the first read used to discard every
    /// sibling that had not yet entered the wire lane.
    final class PromiseBatch {
        let root: URL
        let generation: UInt64
        private(set) var callbacksRemaining: Int
        private(set) var filesOutstanding = 0
        private(set) var invalidated = false

        init(root: URL, generation: UInt64, expectedCallbacks: Int) {
            self.root = root
            self.generation = generation
            callbacksRemaining = max(1, expectedCallbacks)
        }

        func callbackFinished(enqueued: Bool) {
            callbacksRemaining = max(0, callbacksRemaining - 1)
            if enqueued { filesOutstanding += 1 }
        }

        func fileFinished() {
            filesOutstanding = max(0, filesOutstanding - 1)
        }

        func invalidate() { invalidated = true }

        var isFinished: Bool {
            invalidated || (callbacksRemaining == 0 && filesOutstanding == 0)
        }
    }

    enum TransferError: LocalizedError {
        case noSource
        case busy
        case directory(String)
        case unreadable(String)
        case wire(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "That mirrored file is no longer available."
            case .busy: return "Another file is already crossing the Mirror."
            case .directory(let name):
                return "\(name) is a folder; this first version copies files only."
            case .unreadable(let name): return "Could not read \(name)."
            case .wire(let message): return message
            }
        }
    }

    @Published private(set) var activity: Activity?
    @Published private(set) var notice: String?
    /// Where a terminal FAILURE of a host→guest copy is said out loud
    /// somewhere a person is actually looking.
    ///
    /// `notice` is not that place and was never wired to be: the detached
    /// Mirror window renders no view observing it, so on 2026-08-16 a
    /// name-collision refusal reached this object and stopped. Deliberately
    /// the same shape as `ContinuityGrabTransfer.outcomeSink`, which exists
    /// for the same reason in the opposite direction — a sink rather than a
    /// binding, because the surface that must show it (a notification, the
    /// menu-bar flash) is not a view of this model.
    var outcomeSink: ((String) -> Void)?
    var connection: GuestConnectionState = .disconnected

    private let listener: GuestListener
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.newoldworld.mirror.file-promises"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var watch: HostEventSubscription?
    private var queue: [PendingHostFile] = []
    private var promiseBatches: [PromiseBatch] = []
    private var promiseInFlight = false
    private var hostFilePreparationInFlight = false
    private var transferGeneration: UInt64 = 0

    init(listener: GuestListener) {
        self.listener = listener
        super.init()
        watch = listener.events.subscribe(
            scopedTo: { [weak self] in self?.connection.key }
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .transferProgressed(_, let received, let expected):
                guard var activity = self.activity else { return }
                activity.received = received
                activity.expected = expected
                activity.awaitingSettlement = expected > 0
                    && received >= expected
                self.activity = activity
            case .transferEnded:
                if var activity = self.activity {
                    activity.awaitingSettlement = true
                    self.activity = activity
                }
            default:
                break
            }
        }
    }

    var isBusy: Bool {
        activity != nil || promiseInFlight || hostFilePreparationInFlight
    }

    func activeGuestWillChange() {
        transferGeneration &+= 1
        discardQueuedHostFiles()
        if isBusy {
            notice = "The file copy ended because the active Mac changed."
        }
        activity = nil
        promiseInFlight = false
        hostFilePreparationInFlight = false
    }

    func clearNotice() { notice = nil }

    /// Begins only after the native drop has landed and AppKit has provided
    /// file URLs. Multiple files retain release order over the single lane.
    func copyHostFiles(_ urls: [URL],
                       to target: CrossMachineFileTargeting.Destination) {
        enqueueHostFiles(urls, to: target, promiseBatch: nil)
    }

    /// Accepts the same AppKit payload Finder and document applications put
    /// on a native drag. URLs are consumed directly; promised files are first
    /// materialized in a private staging directory, then enter the same copy
    /// queue. Returning true means this process accepted ownership of the
    /// drop, not that the guest has finished writing it.
    func copyHostPasteboard(
        _ pasteboard: NSPasteboard,
        to target: CrossMachineFileTargeting.Destination
    ) -> Bool {
        guard case .connected = connection else {
            notice = "No \(MachineNaming.commonNoun) is connected."
            return false
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: options) ?? []).compactMap {
                ($0 as? NSURL).map { $0 as URL }
            }
        if !urls.isEmpty {
            copyHostFiles(urls, to: target)
            return true
        }

        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) ?? [])
            .compactMap { $0 as? NSFilePromiseReceiver }
        guard !receivers.isEmpty else {
            notice = "That drag did not contain a file \(MachineNaming.simpleReference) can copy."
            return false
        }
        guard receivers.count <= 32 else {
            notice = "That is \(receivers.count) files; 32 at a time is the Mirror limit."
            return false
        }
        for receiver in receivers {
            receivePromisedHostFile(receiver, target: target)
        }
        return true
    }

    /// **THE HOST HALF OF THE SILENT COLLISION.** Metal, 2026-08-16: a file
    /// dropped onto the guest whose name already existed there did nothing
    /// and said nothing.
    ///
    /// The guest was never at fault and neither was the wire.
    /// `now_files_receive_begin_at` returns `kFilesExists`, `wire.c` refuses
    /// `code=exists` with a reason, and this Mac receives it. It died HERE,
    /// twice over: the failure arm assigned `notice` and nothing else — no
    /// `HostLog`, so a metal round had no line to find — and the detached
    /// Mirror window renders no view that observes `notice`, so the sentence
    /// reached no person either. Two independent routes to the same silence,
    /// which is why neither showed up as a suspect.
    ///
    /// This closes the log half and hands the person half to `outcomeSink`,
    /// the same seam `ContinuityGrabTransfer` already uses for exactly this
    /// class of terminal outcome one edge over.
    /// The sentence, as a pure function, so a test can read it without a
    /// listener, a guest, or a log file — the seam this file already uses
    /// for `wireTarget` and `wireSource`.
    static func hostFileFailureAudit(code: String, name: String,
                                     reason: String)
        -> (level: HostLog.LogLevel, body: String) {
        guard code == "exists" else {
            return (.warn, "host file refused by the guest: code=\(code), "
                + "name=\(name), reason=\(reason)")
        }
        /* NOT "cancelled", and not "replaced". Nobody was asked. That
           vocabulary belongs to the replace dialog (docs/open-issues.md, the
           collision ruling), and spending its words now on a refusal no
           person authored would make the dialog's arrival invisible in the
           log — the reader could not tell a person's decision from this
           Mac's silence. The line is meant to read as a defect, because it
           is one. */
        return (.warn, "collision: refused-without-asking name=\(name) — the "
            + "guest already has a file by this name and nobody was given "
            + "the choice; the replace dialog is not built yet")
    }

    private func reportHostFileFailure(_ failure: GuestListener.FileFailure,
                                       name: String) {
        let line = Self.hostFileFailureAudit(code: failure.code, name: name,
                                             reason: failure.message)
        HostLog.shared.write(line.level, "continuity", line.body)
        outcomeSink?(failure.message)
    }

    private func enqueueHostFiles(
        _ urls: [URL],
        to target: CrossMachineFileTargeting.Destination,
        promiseBatch: PromiseBatch?
    ) {
        guard case .connected = connection else {
            notice = "No \(MachineNaming.commonNoun) is connected."
            if let promiseBatch {
                promiseBatch.callbackFinished(enqueued: false)
                finishPromiseBatchIfPossible(promiseBatch)
            }
            return
        }
        guard !urls.isEmpty else { return }
        guard urls.count <= 32 else {
            notice = "That is \(urls.count) files; 32 at a time is the Mirror limit."
            if let promiseBatch {
                promiseBatch.callbackFinished(enqueued: false)
                finishPromiseBatchIfPossible(promiseBatch)
            }
            return
        }
        var enqueued = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDirectory)
            else {
                notice = TransferError.unreadable(url.lastPathComponent)
                    .localizedDescription
                continue
            }
            guard !isDirectory.boolValue else {
                notice = TransferError.directory(url.lastPathComponent)
                    .localizedDescription
                continue
            }
            queue.append(.init(url: url, target: target,
                               promiseBatch: promiseBatch))
            enqueued = true
        }
        if let promiseBatch {
            promiseBatch.callbackFinished(enqueued: enqueued)
            finishPromiseBatchIfPossible(promiseBatch)
        }
        startNextHostFile()
    }

    private func receivePromisedHostFile(
        _ receiver: NSFilePromiseReceiver,
        target: CrossMachineFileTargeting.Destination
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-continuity-drop-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            notice = error.localizedDescription
            return
        }
        let batch = PromiseBatch(
            root: root, generation: transferGeneration,
            expectedCallbacks: receiver.fileNames.count)
        promiseBatches.append(batch)
        receiver.receivePromisedFiles(
            atDestination: root, options: [:], operationQueue: promiseQueue
        ) { [weak self, batch] url, error in
            Task { @MainActor in
                guard let self else { return }
                guard batch.generation == self.transferGeneration,
                      !batch.invalidated else {
                    try? FileManager.default.removeItem(at: batch.root)
                    return
                }
                if let error {
                    self.notice = error.localizedDescription
                    batch.callbackFinished(enqueued: false)
                    self.finishPromiseBatchIfPossible(batch)
                    return
                }
                self.enqueueHostFiles([url], to: target,
                                      promiseBatch: batch)
            }
        }
    }

    private func finishPromiseBatchIfPossible(_ batch: PromiseBatch) {
        guard batch.isFinished else { return }
        try? FileManager.default.removeItem(at: batch.root)
        promiseBatches.removeAll { $0 === batch }
    }

    private func discardQueuedHostFiles() {
        queue.removeAll()
        for batch in promiseBatches {
            batch.invalidate()
            try? FileManager.default.removeItem(at: batch.root)
        }
        promiseBatches.removeAll()
    }

    /// A native file promise is the host-side stub. It carries the original
    /// icon in the dragging session, but no bytes cross until Finder (or an
    /// application) accepts the promise on release.
    func promise(for source: CrossMachineFileTargeting.Source)
        -> NSFilePromiseProvider? {
        guard case .connected = connection else {
            notice = "No \(MachineNaming.commonNoun) is connected."
            return nil
        }
        let type = UTType(filenameExtension:
            (source.file.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier,
                                             delegate: self)
        provider.userInfo = source
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        guard let source = provider.userInfo
                as? CrossMachineFileTargeting.Source else { return "Untitled" }
        let name = LocalFileName.sanitized(source.file.name)
        if source.file.kind == "application"
            && !name.lowercased().hasSuffix(".bin") {
            return name + ".bin"
        }
        return name
    }

    func operationQueue(for provider: NSFilePromiseProvider)
        -> OperationQueue { promiseQueue }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = PromiseCompletion(completionHandler)
        let source = provider.userInfo as? CrossMachineFileTargeting.Source
        Task { @MainActor [weak self] in
            guard let self else {
                completion.finish(TransferError.noSource)
                return
            }
            guard let source else {
                completion.finish(TransferError.noSource)
                return
            }
            self.redeem(source, to: url, completion: completion)
        }
    }

    private func redeem(
        _ source: CrossMachineFileTargeting.Source,
        to url: URL,
        completion: PromiseCompletion
    ) {
        guard !isBusy else {
            completion.finish(TransferError.busy)
            return
        }
        promiseInFlight = true
        let generation = transferGeneration
        notice = nil
        activity = Activity(name: source.file.name, direction: .toHost,
                            received: 0, expected: 0)
        listener.getMirrorFile(
            source: Self.wireSource(source),
            container: source.file.kind == "application" ? "macbinary" : nil,
            stagingDirectory: url.deletingLastPathComponent()
        ) { [weak self] result in
            guard let self else { return }
            guard generation == self.transferGeneration else {
                completion.finish(TransferError.wire(
                    "The active Mac changed during the file copy."))
                return
            }
            switch result {
            case .failure(let failure):
                self.promiseInFlight = false
                self.activity = nil
                self.notice = failure.message
                completion.finish(TransferError.wire(failure.message))
            case .success(let file):
                Task { [weak self] in
                    let outcome = await Task.detached(priority: .userInitiated) {
                        Result {
                            let conversion = try FileConverter.materialize(
                                name: file.name, container: file.container,
                                fileType: file.fileType, staged: file.staged,
                                to: url)
                            if let modified = file.modified,
                               let date = ClassicDate.date(from: modified) {
                                try? FileManager.default.setAttributes(
                                    [.modificationDate: date],
                                    ofItemAtPath: url.path)
                            }
                            return conversion
                        }
                    }.value
                    guard let self else { return }
                    guard generation == self.transferGeneration else {
                        completion.finish(TransferError.wire(
                            "The active Mac changed during the file copy."))
                        return
                    }
                    self.promiseInFlight = false
                    self.activity = nil
                    switch outcome {
                    case .success(let conversion):
                        self.notice = conversion.map {
                            "Copied \(source.file.name) to this Mac (\($0))."
                        } ?? "Copied \(source.file.name) to this Mac."
                        completion.finish(nil)
                    case .failure(let error):
                        self.notice = error.localizedDescription
                        completion.finish(error)
                    }
                }
            }
        }
    }

    nonisolated static func wireSource(
        _ source: CrossMachineFileTargeting.Source
    )
        -> MirrorFileSource {
        switch source {
        case .desktop(let file):
            return .init(kind: "desktop", name: file.name)
        case .finderWindow(let path, let file):
            return .init(kind: "finder-window", name: file.name, path: path)
        }
    }

    nonisolated static func wireTarget(
        _ target: CrossMachineFileTargeting.Destination
    )
        -> MirrorFileDrop {
        switch target {
        case .desktop:
            return .init(kind: "desktop")
        case .finderFolder(let path):
            return .init(kind: "finder-folder", path: path)
        case .applicationProcess(let psn, let name):
            return .init(kind: "application-process", psn: psn, name: name)
        case .applicationCreator(let creator, let name):
            return .init(kind: "application-creator", creator: creator,
                         name: name)
        }
    }

    private func startNextHostFile() {
        guard activity == nil, !promiseInFlight,
              !hostFilePreparationInFlight, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        let generation = transferGeneration
        let sourceURL = item.url
        hostFilePreparationInFlight = true
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    let modified = (try? sourceURL.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                        .flatMap(ClassicDate.guestWireSeconds(from:))
                    let data = try Data(contentsOf: sourceURL,
                                        options: [.mappedIfSafe])
                    return (OutboundFile.plan(
                        url: sourceURL, data: data, convertText: true), modified)
                }
            }.value
            guard let self,
                  generation == self.transferGeneration else { return }
            self.hostFilePreparationInFlight = false
            item.promiseBatch?.fileFinished()
            if let batch = item.promiseBatch {
                self.finishPromiseBatchIfPossible(batch)
            }
            switch outcome {
            case .failure:
                self.notice = TransferError.unreadable(
                    item.url.lastPathComponent).localizedDescription
                self.startNextHostFile()
            case .success(let prepared):
                let (plan, modified) = prepared
                self.notice = plan.note
                self.activity = Activity(
                    name: plan.name, direction: .toGuest,
                    received: 0, expected: plan.bytes.count)
                self.listener.putMirrorFile(
                    name: plan.name, target: Self.wireTarget(item.target),
                    container: plan.container, bytes: plan.bytes,
                    fileType: plan.fileType, creator: plan.creator,
                    modified: modified
                ) { [weak self] result in
                    guard let self,
                          generation == self.transferGeneration else { return }
                    self.activity = nil
                    switch result {
                    case .success:
                        self.notice = plan.note.map {
                            "Copied \(plan.name) to \(MachineNaming.simpleReference) (\($0))."
                        } ?? "Copied \(plan.name) to \(MachineNaming.simpleReference)."
                        self.startNextHostFile()
                    case .failure(let failure):
                        self.notice = failure.message
                        self.reportHostFileFailure(failure, name: plan.name)
                        self.discardQueuedHostFiles()
                    }
                }
            }
        }
    }
}
