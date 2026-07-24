import Darwin
import Foundation

public final class AgentIntegrationLocalServer {
    public typealias Handler = @MainActor @Sendable (
        AgentIntegrationLocalRequest
    ) async -> AgentIntegrationLocalResult
    typealias PeerAuthorizer = @Sendable (Int32, uid_t) -> Bool

    public let endpoint: AgentIntegrationEndpoint
    private let expectedUID: uid_t
    private let peerAuthorizer: PeerAuthorizer
    private let handler: Handler
    private let acceptQueue = DispatchQueue(
        label: "dev.newoldworld.agent-integration.accept")
    private let clientQueue = DispatchQueue(
        label: "dev.newoldworld.agent-integration.client",
        attributes: .concurrent)
    private let lock = NSLock()
    private var listeningDescriptor: Int32 = -1

    public convenience init(
        endpoint: AgentIntegrationEndpoint? = nil,
        expectedUID: uid_t = geteuid(),
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
            handler: handler)
    }

    init(
        endpoint: AgentIntegrationEndpoint? = nil,
        expectedUID: uid_t = geteuid(),
        peerAuthorizer: @escaping PeerAuthorizer = {
            AgentIntegrationLocalServer.sameUserPeer($0, $1)
        },
        handler: @escaping Handler
    ) throws {
        self.endpoint = try endpoint ?? .currentUser(uid: expectedUID)
        self.expectedUID = expectedUID
        self.peerAuthorizer = peerAuthorizer
        self.handler = handler
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
            close(descriptor)
            unlink(endpoint.socketURL.path)
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
        _ = shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(endpoint.socketURL.path)
    }

    private func acceptConnections(on listener: Int32) {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else {
                if errno == EINTR { continue }
                return
            }
            AgentIntegrationUnixSocket.setTimeouts(descriptor)
            guard peerAuthorizer(descriptor, expectedUID) else {
                close(descriptor)
                continue
            }
            clientQueue.async { [weak self] in
                self?.handleClient(descriptor)
            }
        }
    }

    private func handleClient(_ descriptor: Int32) {
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

        Task { [weak self] in
            guard let self else {
                close(descriptor)
                return
            }
            let response: AgentIntegrationLocalResponse
            switch await handler(request) {
            case .sessionHealth(let result):
                response = .init(
                    requestID: request.requestID, result: result)
            case .processList(let result):
                response = .init(
                    requestID: request.requestID,
                    processListResult: result)
            case .launchSoftware(let result):
                response = .init(
                    requestID: request.requestID,
                    launchResult: result)
            }
            finish(descriptor, response: response)
        }
    }

    private func finish(_ descriptor: Int32,
                        response: AgentIntegrationLocalResponse) {
        defer { close(descriptor) }
        guard let data = try? AgentIntegrationLocalCodec.encode(response)
        else { return }
        try? AgentIntegrationUnixSocket.writeLine(data, to: descriptor)
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
