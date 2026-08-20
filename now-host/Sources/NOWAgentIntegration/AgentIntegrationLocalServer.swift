import Darwin
import Foundation

/// **Who is on the other end of the request being served**, as the kernel
/// named them.
///
/// It exists for one capability and should stay that narrow: the live-stream
/// bracket is the only thing on this surface that outlives the call that
/// opened it, so it is the only thing that has to know whose it is. Every
/// other operation answers and is done, and an operation that started
/// branching on its caller would be building a per-agent policy nobody
/// designed.
///
/// Nil means the kernel would not name the peer — a companion that closed
/// between accept and the lookup — which the ledger already models the same
/// way. A capability that needs an owner must treat nil as "no owner",
/// never as "the same one as last time".
public enum AgentIntegrationLocalCaller {
    @TaskLocal public static var processID: pid_t?

    /// Whether a process this host once served is still there.
    ///
    /// `kill(pid, 0)` asks the kernel and sends nothing. **Its known limit is
    /// the ledger's:** pids are recycled, so a companion that died and whose
    /// number was reused reads as alive. That undercounts departures rather
    /// than inventing them, which is the direction to be wrong in here — the
    /// lease is what catches the recycled case, and a liveness check that
    /// guessed the other way would end a working agent's stream.
    public static func isRunning(_ processID: pid_t) -> Bool {
        /* EPERM means it exists and belongs to somebody else; only ESRCH
           means gone. The uid gate makes the first unreachable in practice
           and it is handled anyway, because "not ours" is not "not there". */
        kill(processID, 0) == 0 || errno == EPERM
    }
}

/// The socket server is shared by its accept/client queues. Mutable descriptor
/// and replay state is guarded by `lock`/`attemptLock`; companion state owns
/// its own lock, and callbacks are immutable Sendable values.
public final class AgentIntegrationLocalServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (
        AgentIntegrationLocalRequest
    ) async -> AgentIntegrationLocalResult
    typealias PeerAuthorizer = @Sendable (Int32, uid_t) -> Bool
    /// Told after every change to the companion ledger, on a serial queue and
    /// in order. A push rather than a poll because the fact it carries is
    /// mostly *transitions* — a companion appearing, a request starting and
    /// finishing — and a pane that polled would miss the short ones, which
    /// are all of them.
    public typealias CompanionObserver =
        @Sendable (AgentCompanionActivity) -> Void

    public let endpoint: AgentIntegrationEndpoint
    private let expectedUID: uid_t
    private let peerAuthorizer: PeerAuthorizer
    private let handler: Handler
    private let companionObserver: CompanionObserver?
    private let companions = AgentCompanionLedger()
    private let acceptQueue = DispatchQueue(
        label: "dev.newoldworld.agent-integration.accept")
    private let clientQueue = DispatchQueue(
        label: "dev.newoldworld.agent-integration.client",
        attributes: .concurrent)
    /// Serial, so observers see the snapshots in the order they happened.
    /// Delivering from the accept thread instead would let an observer that
    /// blocks stall the next accept.
    private let observerQueue = DispatchQueue(
        label: "dev.newoldworld.agent-integration.companions")
    private let lock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private let attemptLock = NSLock()
    private var inFlightAttempts: Set<UUID> = []

    private struct StoredAttempt: Codable {
        let request: Data
        let response: Data
    }

    private enum AttemptAdmission {
        case admitted
        case replay(AgentIntegrationLocalResponse)
        case pending
        case collision
    }

    public convenience init(
        endpoint: AgentIntegrationEndpoint? = nil,
        expectedUID: uid_t = geteuid(),
        companionObserver: CompanionObserver? = nil,
        handler: @escaping @MainActor @Sendable (
            AgentIntegrationLocalRequest
        ) async -> AgentIntegrationLocalResult
    ) throws {
        try self.init(
            endpoint: endpoint,
            expectedUID: expectedUID,
            peerAuthorizer: {
                Self.sameUserPeer($0, $1)
            },
            companionObserver: companionObserver,
            handler: handler)
    }

    init(
        endpoint: AgentIntegrationEndpoint? = nil,
        expectedUID: uid_t = geteuid(),
        peerAuthorizer: @escaping PeerAuthorizer = {
            AgentIntegrationLocalServer.sameUserPeer($0, $1)
        },
        companionObserver: CompanionObserver? = nil,
        handler: @escaping Handler
    ) throws {
        self.endpoint = try endpoint ?? .currentUser(uid: expectedUID)
        self.expectedUID = expectedUID
        self.peerAuthorizer = peerAuthorizer
        self.companionObserver = companionObserver
        self.handler = handler
    }

    /// What has reached this endpoint, for whoever draws it.
    ///
    /// A snapshot, not a live view: it is read from the main thread while the
    /// accept thread writes, and handing out anything else would be handing
    /// out a race.
    public var companionActivity: AgentCompanionActivity {
        companions.snapshot
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listeningDescriptor < 0 else { return }
        try prepareDirectory()
        try removeStaleSocket()

        let descriptor = try AgentIntegrationUnixSocket.makeSocket()
        do {
            try AgentIntegrationUnixSocket.withAddress(
                path: endpoint.socketURL.path) { address, length in
                guard bind(descriptor, address, length) == 0 else {
                    throw AgentIntegrationUnixSocket.ioError("bind")
                }
            }
            guard chmod(endpoint.socketURL.path, 0o600) == 0 else {
                throw AgentIntegrationUnixSocket.ioError("chmod")
            }
            guard listen(descriptor, 16) == 0 else {
                throw AgentIntegrationUnixSocket.ioError("listen")
            }
        } catch {
            /* Same identity rule as stop(): remove the file only if the
               failed bind actually created it. */
            let pathIsOurs = Self.pathNamesSocket(
                descriptor, at: endpoint.socketURL.path)
            close(descriptor)
            if pathIsOurs {
                unlink(endpoint.socketURL.path)
            }
            throw error
        }

        listeningDescriptor = descriptor
        acceptQueue.async { [weak self] in
            self?.acceptConnections(on: descriptor)
        }
    }

    public func stop() {
        lock.lock()
        let descriptor = listeningDescriptor
        listeningDescriptor = -1
        lock.unlock()
        guard descriptor >= 0 else { return }
        /* Decided BEFORE the close, because the identity question needs
           the descriptor alive to ask. */
        let pathIsOurs = Self.pathNamesSocket(
            descriptor, at: endpoint.socketURL.path)
        _ = shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        if pathIsOurs {
            unlink(endpoint.socketURL.path)
        }
    }

    /// Whether `path` still names THIS listener's socket — the same
    /// dev/inode pair — and not a successor's.
    ///
    /// The blind unlink this replaces stomped a live host: two app
    /// copies share one default path, the newer one had honestly
    /// replaced a dead file (removeStaleSocket probes first), and the
    /// OLDER copy's quit then deleted the newer copy's socket on the
    /// way out. Every companion after that answered "notSent" while
    /// both hosts had looked healthy (measured on the desk,
    /// 2026-08-19: mount new build, launch, quit the old one).
    static func pathNamesSocket(_ descriptor: Int32,
                                at path: String) -> Bool {
        var ours = stat()
        var named = stat()
        guard fstat(descriptor, &ours) == 0,
              lstat(path, &named) == 0 else { return false }
        return ours.st_dev == named.st_dev && ours.st_ino == named.st_ino
    }

    private func acceptConnections(on listener: Int32) {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else {
                if errno == EINTR { continue }
                return
            }
            AgentIntegrationUnixSocket.setTimeouts(descriptor)
            /* The uid gate, unchanged and still first: nothing below runs
               for a peer it turns away, and the ledger learns only that a
               refusal happened. Asking the kernel who the peer was comes
               AFTER, so an unauthorized process cannot enter the companion
               list by being looked up. */
            guard peerAuthorizer(descriptor, expectedUID) else {
                close(descriptor)
                publish(companions.refused(at: Date()))
                continue
            }
            let peer = Self.peerProcessID(descriptor)
            publish(companions.began(processID: peer, at: Date()))
            clientQueue.async { [weak self] in
                self?.handleClient(descriptor, peer: peer)
            }
        }
    }

    private func handleClient(_ descriptor: Int32, peer: pid_t?) {
        let request: AgentIntegrationLocalRequest
        do {
            let data = try AgentIntegrationUnixSocket.readLine(
                from: descriptor)
            request = try AgentIntegrationLocalCodec.decodeRequest(data)
        } catch {
            finish(
                descriptor,
                response: .init(error: .init(
                    code: "invalid-request",
                    message: localMessage(for: error))))
            return
        }

        switch admitAttempt(request) {
        case .replay(let response):
            finish(descriptor, response: response,
                   operation: request.operation.rawValue)
            return
        case .pending:
            finish(descriptor, response: .init(
                requestID: request.requestID,
                error: .init(
                    code: "attempt-pending",
                    message: "This mutation was already dispatched; retry the same attempt after it settles.")))
            return
        case .collision:
            finish(descriptor, response: .init(
                requestID: request.requestID,
                error: .init(
                    code: "attempt-collision",
                    message: "This attempt ID is already bound to a different request.")))
            return
        case .admitted:
            break
        }

        Task { [weak self, companions] in
            guard let self else {
                close(descriptor)
                /* The server is gone but the request it accepted is not
                   still running; the ledger outlives it here only long
                   enough not to leave a phantom in flight. */
                _ = companions.ended(at: Date())
                return
            }
            let response: AgentIntegrationLocalResponse
            /* The caller's identity travels as a task-local rather than as a
               handler parameter, and the choice is worth stating: thirty-odd
               call sites construct this server and all but one of them are
               tests that do not care who called. A parameter would make every
               one of them say so.

               It is bound HERE, around the one await that reaches the
               handler, so the value is scoped to exactly the request it
               describes and cannot leak into the next one — and it is the
               kernel's answer off the accepted socket, never anything the
               peer said about itself. */
            switch await AgentIntegrationLocalCaller.$processID
                .withValue(peer, operation: { await self.handler(request) }) {
            case .notAddressed(let unavailable):
                response = .init(
                    requestID: request.requestID,
                    notAddressed: unavailable)
            case .sessionHealth(let result):
                response = .init(
                    requestID: request.requestID, result: result)
            case .sessionCapabilities(let result):
                response = .init(
                    requestID: request.requestID,
                    sessionCapabilitiesResult: result)
            case .processList(let result):
                response = .init(
                    requestID: request.requestID,
                    processListResult: result)
            case .launchSoftware(let result):
                response = .init(
                    requestID: request.requestID,
                    launchResult: result)
            case .requestQuit(let result):
                response = .init(
                    requestID: request.requestID,
                    quitResult: result)
            case .transferApprovedArtifact(let result):
                response = .init(
                    requestID: request.requestID,
                    artifactTransferResult: result)
            case .guestFilesCapabilities(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFilesCapabilitiesResult: result)
            case .guestFilesList(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFilesListResult: result)
            case .guestFilesStat(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFilesStatResult: result)
            case .guestFilesUploadStage(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFilesUploadStageResult: result)
            case .guestFilesUploadCommit(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFilesUploadCommitResult: result)
            case .capture(let result):
                response = .init(
                    requestID: request.requestID,
                    captureResult: result)
            case .recorded:
                response = .init(
                    requestID: request.requestID, recorded: true)
            case .census(let result):
                response = .init(
                    requestID: request.requestID, censusResult: result)
            case .softwareInventory(let result):
                response = .init(
                    requestID: request.requestID,
                    softwareInventoryResult: result)
            case .guestFileDownload(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFileDownloadResult: result)
            case .bringToFront(let result):
                response = .init(
                    requestID: request.requestID,
                    bringToFrontResult: result)
            case .guestFileMutation(let result):
                response = .init(
                    requestID: request.requestID,
                    guestFileMutationResult: result)
            case .transferCancel(let result):
                response = .init(
                    requestID: request.requestID,
                    transferCancelResult: result)
            case .guestLogTail(let result):
                response = .init(
                    requestID: request.requestID,
                    guestLogTailResult: result)
            case .hostLogTail(let result):
                response = .init(
                    requestID: request.requestID,
                    hostLogTailResult: result)
            case .machineFacts(let result):
                response = .init(
                    requestID: request.requestID,
                    machineFactsResult: result)
            case .developmentEnvironment(let result):
                response = .init(
                    requestID: request.requestID,
                    developmentEnvironmentResult: result)
            case .catalogSearch(let result):
                response = .init(
                    requestID: request.requestID,
                    catalogSearchResult: result)
            case .revealItem(let result):
                response = .init(
                    requestID: request.requestID,
                    revealItemResult: result)
            case .diagnostics(let result):
                response = .init(
                    requestID: request.requestID,
                    diagnosticsResult: result)
            case .mirrorRead(let result):
                response = .init(
                    requestID: request.requestID,
                    mirrorReadResult: result)
            case .mirrorDrive(let result):
                response = .init(
                    requestID: request.requestID,
                    mirrorDriveResult: result)
            case .mirrorOpen(let result):
                response = .init(
                    requestID: request.requestID,
                    mirrorOpenResult: result)
            case .stream(let result):
                response = .init(
                    requestID: request.requestID,
                    streamResult: result)
            case .windowAct(let result):
                response = .init(
                    requestID: request.requestID,
                    windowActResult: result)
            case .controlAct(let result):
                response = .init(
                    requestID: request.requestID,
                    controlActResult: result)
            case .menuAct(let result):
                response = .init(
                    requestID: request.requestID,
                    menuActResult: result)
            case .textGet(let result):
                response = .init(
                    requestID: request.requestID,
                    textGetResult: result)
            case .textSet(let result):
                response = .init(
                    requestID: request.requestID,
                    textSetResult: result)
            case .observeElements(let result):
                response = .init(
                    requestID: request.requestID,
                    observeElementsResult: result)
            case .projects(let result):
                response = .init(requestID: request.requestID,
                                 projectResult: result)
            case .chats(let result):
                response = .init(requestID: request.requestID,
                                 chatResult: result)
            case .development(let result):
                response = .init(requestID: request.requestID,
                                 developmentResult: result)
            case .notImplemented(let unavailable):
                response = .init(
                    requestID: request.requestID,
                    notImplemented: unavailable)
            }
            self.completeAttempt(request, response: response)
            finish(descriptor, response: response,
                   operation: request.operation.rawValue)
        }
    }

    private func isReplayable(_ request: AgentIntegrationLocalRequest) -> Bool {
        (request.operation == .development
            && request.developmentRequest?.attemptID != nil)
            || (request.operation == .projects
                && request.projectRequest?.attemptID != nil)
    }

    private var attemptDirectory: URL {
        endpoint.socketURL.deletingLastPathComponent()
            .appendingPathComponent("attempt-receipts", isDirectory: true)
    }

    private func attemptURL(_ id: UUID) -> URL {
        attemptDirectory.appendingPathComponent(
            id.uuidString.lowercased() + ".json")
    }

    private func admitAttempt(
        _ request: AgentIntegrationLocalRequest
    ) -> AttemptAdmission {
        guard isReplayable(request) else { return .admitted }
        guard let encoded = try? AgentIntegrationLocalCodec.encode(request)
        else { return .collision }
        let id = request.requestID
        attemptLock.lock()
        defer { attemptLock.unlock() }
        let url = attemptURL(id)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredAttempt.self, from: data) {
            guard stored.request == encoded else { return .collision }
            guard let response = try? AgentIntegrationLocalCodec.decodeResponse(
                stored.response) else { return .collision }
            return .replay(response)
        }
        guard !inFlightAttempts.contains(id) else { return .pending }
        inFlightAttempts.insert(id)
        return .admitted
    }

    private func completeAttempt(
        _ request: AgentIntegrationLocalRequest,
        response: AgentIntegrationLocalResponse
    ) {
        guard isReplayable(request) else { return }
        let id = request.requestID
        guard let encodedRequest = try? AgentIntegrationLocalCodec.encode(request)
        else {
            attemptLock.lock()
            inFlightAttempts.remove(id)
            attemptLock.unlock()
            return
        }
        let stored = StoredAttempt(
            request: encodedRequest,
            response: AgentIntegrationLocalCodec.encodeOrRefusal(
                response, operation: request.operation.rawValue))
        attemptLock.lock()
        defer {
            inFlightAttempts.remove(id)
            attemptLock.unlock()
        }
        do {
            try FileManager.default.createDirectory(
                at: attemptDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let bytes = try JSONEncoder().encode(stored)
            try bytes.write(to: attemptURL(id), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(
                at: attemptDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            if files.count > 256 {
                let ordered = files.sorted {
                    let left = try? $0.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate
                    let right = try? $1.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate
                    return (left ?? .distantPast) < (right ?? .distantPast)
                }
                for stale in ordered.prefix(files.count - 256) {
                    try? FileManager.default.removeItem(at: stale)
                }
            }
        } catch {
            /* The domain response remains authoritative. Persistence failure
               may prevent replay, but must not turn completed guest work into
               a second domain failure after the fact. */
        }
    }

    /// The one exit from a served request, which is why the ledger's
    /// in-flight count is decremented here rather than at each `return`
    /// above: a branch that forgot would leave a companion working forever
    /// on the pane.
    /* **And it always writes something.** It used to encode with `try?`
       and `return` on failure, which put the `defer` above straight into a
       close — so a reply past the 64 KB ceiling reached the caller as a
       hang-up with no error frame and no reason. That is the least
       informative answer this transport can give, and every other refusal
       in this tree names its cause. `encodeOrRefusal` substitutes a
       bounded refusal that does, and the operation is passed in so it can
       say WHICH answer did not fit. */
    private func finish(_ descriptor: Int32,
                        response: AgentIntegrationLocalResponse,
                        operation: String? = nil) {
        defer {
            close(descriptor)
            publish(companions.ended(at: Date()))
        }
        let data = AgentIntegrationLocalCodec.encodeOrRefusal(
            response, operation: operation)
        try? AgentIntegrationUnixSocket.writeLine(data, to: descriptor)
    }

    private func publish(_ activity: AgentCompanionActivity) {
        guard let companionObserver else { return }
        observerQueue.async { companionObserver(activity) }
    }

    /// Which process is on the other end, as the KERNEL answers it.
    ///
    /// `LOCAL_PEERPID` is the counterpart of the `getpeereid` gate above and
    /// is trusted for the same reason: it is the kernel's answer about the
    /// socket, not something the peer sent. Nothing a companion says about
    /// itself is recorded anywhere in this file — a process naming itself is
    /// not evidence that it is that process.
    ///
    /// Nil when the peer went away before the lookup, which counts toward the
    /// totals and joins no companion row.
    static func peerProcessID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID,
                         &pid, &length) == 0,
              length == socklen_t(MemoryLayout<pid_t>.size),
              pid > 0
        else { return nil }
        return pid
    }

    private func prepareDirectory() throws {
        let result = mkdir(endpoint.directoryURL.path, 0o700)
        guard result == 0 || errno == EEXIST else {
            throw AgentIntegrationUnixSocket.ioError("mkdir")
        }
        try AgentIntegrationUnixSocket.validateDirectory(
            endpoint.directoryURL, uid: expectedUID)
    }

    private func removeStaleSocket() throws {
        var status = stat()
        guard lstat(endpoint.socketURL.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw AgentIntegrationUnixSocket.ioError("lstat")
        }
        guard status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == expectedUID,
              status.st_mode & 0o077 == 0 else {
            throw AgentIntegrationLocalTransportError.unsafeEndpoint(
                "Refusing to replace an unsafe local endpoint")
        }
        let probe = try AgentIntegrationUnixSocket.makeSocket()
        defer { close(probe) }
        let connected = try AgentIntegrationUnixSocket.withAddress(
            path: endpoint.socketURL.path) { address, length in
            connect(probe, address, length) == 0
        }
        guard !connected else {
            throw AgentIntegrationLocalTransportError.unsafeEndpoint(
                "Another New Old World host owns the local endpoint")
        }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw AgentIntegrationUnixSocket.ioError("connect")
        }
        guard unlink(endpoint.socketURL.path) == 0 else {
            throw AgentIntegrationUnixSocket.ioError("unlink")
        }
    }

    private func localMessage(for error: Error) -> String {
        switch error {
        case AgentIntegrationLocalTransportError.messageTooLarge:
            return "Local request exceeded the size limit"
        default:
            return "Local request did not match the agent schema"
        }
    }

    static func sameUserPeer(_ descriptor: Int32,
                             _ expectedUID: uid_t) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0
            && uid == expectedUID
    }
}
