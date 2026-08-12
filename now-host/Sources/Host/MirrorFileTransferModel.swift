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
            case .toGuest: return "Copying \(name) to the classic Mac"
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
    var connection: GuestConnectionState = .disconnected

    private let listener: GuestListener
    private var watch: HostEventSubscription?
    private var queue: [PendingHostFile] = []
    private var promiseInFlight = false

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

    var isBusy: Bool { activity != nil || promiseInFlight }

    func activeGuestWillChange() {
        queue.removeAll()
        if isBusy {
            notice = "The file copy ended because the active Mac changed."
        }
        activity = nil
        promiseInFlight = false
    }

    func clearNotice() { notice = nil }

    /// Begins only after the native drop has landed and AppKit has provided
    /// file URLs. Multiple files retain release order over the single lane.
    func copyHostFiles(_ urls: [URL],
                       to target: CrossMachineFileTargeting.Destination) {
        guard case .connected = connection else {
            notice = "No classic Mac is connected."
            return
        }
        guard !urls.isEmpty else { return }
        guard urls.count <= 32 else {
            notice = "That is \(urls.count) files; 32 at a time is the Mirror limit."
            return
        }
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
            queue.append(.init(url: url, target: target))
        }
        startNextHostFile()
    }

    /// A native file promise is the host-side stub. It carries the original
    /// icon in the dragging session, but no bytes cross until Finder (or an
    /// application) accepts the promise on release.
    func promise(for source: CrossMachineFileTargeting.Source)
        -> NSFilePromiseProvider? {
        guard case .connected = connection else {
            notice = "No classic Mac is connected."
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
        -> OperationQueue { .main }

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
        notice = nil
        activity = Activity(name: source.file.name, direction: .toHost,
                            received: 0, expected: 0)
        listener.getMirrorFile(
            source: Self.wireSource(source),
            container: source.file.kind == "application" ? "macbinary" : nil,
            stagingDirectory: url.deletingLastPathComponent()
        ) { [weak self] result in
            guard let self else { return }
            self.promiseInFlight = false
            self.activity = nil
            switch result {
            case .failure(let failure):
                self.notice = failure.message
                completion.finish(TransferError.wire(failure.message))
            case .success(let file):
                do {
                    let conversion = try FileConverter.materialize(
                        name: file.name, container: file.container,
                        fileType: file.fileType, staged: file.staged, to: url)
                    if let modified = file.modified,
                       let date = ClassicDate.date(from: modified) {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: date],
                            ofItemAtPath: url.path)
                    }
                    self.notice = conversion.map {
                        "Copied \(source.file.name) to this Mac (\($0))."
                    } ?? "Copied \(source.file.name) to this Mac."
                    completion.finish(nil)
                } catch {
                    self.notice = error.localizedDescription
                    completion.finish(error)
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
        guard activity == nil, !promiseInFlight, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        guard let data = try? Data(contentsOf: item.url) else {
            notice = TransferError.unreadable(item.url.lastPathComponent)
                .localizedDescription
            startNextHostFile()
            return
        }
        let plan = OutboundFile.plan(url: item.url, data: data,
                                     convertText: true)
        let modified = (try? item.url.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
            .flatMap(ClassicDate.guestWireSeconds(from:))
        notice = plan.note
        activity = Activity(name: plan.name, direction: .toGuest,
                            received: 0, expected: plan.bytes.count)
        listener.putMirrorFile(
            name: plan.name, target: Self.wireTarget(item.target),
            container: plan.container, bytes: plan.bytes,
            fileType: plan.fileType, creator: plan.creator,
            modified: modified
        ) { [weak self] result in
            guard let self else { return }
            self.activity = nil
            switch result {
            case .success:
                self.notice = plan.note.map {
                    "Copied \(plan.name) to the classic Mac (\($0))."
                } ?? "Copied \(plan.name) to the classic Mac."
                self.startNextHostFile()
            case .failure(let failure):
                self.notice = failure.message
                self.queue.removeAll()
            }
        }
    }
}
