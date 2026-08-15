import Combine
import Foundation
import Network
import OSLog

enum LocalNetworkDirectAccessEvidence: Equatable {
    case notChecked
    case requesting
    case waiting
    case directReady
    case failed

    var confirmsDirectAccess: Bool { self == .directReady }
}

/// The operation that proves the product can reach the connected Macintosh.
/// It does not own or solicit macOS privacy UI. Keeping the interface out of
/// this seam is deliberate: Network.framework follows the route to the guest,
/// so Ethernet and Wi-Fi may coexist and either may become the viable path.
protocol LocalNetworkDirectAccessConnection: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? { get set }
    var pathDescription: String { get }
    func start(queue: DispatchQueue)
    func sendVerification(_ content: Data,
                          completion: @escaping @Sendable (NWError?) -> Void)
    func cancel()
}

/// Owns only the operation that makes macOS present its Local Network
/// privacy UI. Its state is deliberately not authorization evidence: the
/// guest-targeted connection below remains the only proof that unicast LAN
/// traffic is admitted.
protocol LocalNetworkPermissionPrompt: AnyObject, Sendable {
    var eventHandler: (@Sendable (String) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

private final class SystemLocalNetworkDirectAccessConnection: @unchecked Sendable,
    LocalNetworkDirectAccessConnection {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp)
    }

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? {
        get { connection.stateUpdateHandler }
        set { connection.stateUpdateHandler = newValue }
    }

    var pathDescription: String {
        connection.currentPath.map(String.init(describing:))
            ?? "no current path"
    }

    func start(queue: DispatchQueue) { connection.start(queue: queue) }
    func sendVerification(_ content: Data,
                          completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(content: content,
                        completion: .contentProcessed(completion))
    }
    func cancel() { connection.cancel() }
}

private final class SystemLocalNetworkPermissionPrompt: @unchecked Sendable,
    LocalNetworkPermissionPrompt {
    static let serviceType = "_newoldworld._tcp"

    var eventHandler: (@Sendable (String) -> Void)?
    private let listener: NWListener
    private let browser: NWBrowser

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.service = NWListener.Service(
            name: "now-permission-\(UUID().uuidString)",
            type: Self.serviceType)
        browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: .tcp)

        listener.stateUpdateHandler = { [weak self] state in
            self?.eventHandler?("listener \(String(describing: state))")
        }
        browser.stateUpdateHandler = { [weak self] state in
            self?.eventHandler?("browser \(String(describing: state))")
        }
    }

    func start(queue: DispatchQueue) {
        /* Browsing and advertising is the operation Apple documents for
           soliciting Local Network privacy. Keep both halves alive until the
           direct guest path settles; self-discovery is never promoted into
           permission evidence. */
        listener.start(queue: queue)
        browser.start(queue: queue)
    }

    func cancel() {
        browser.cancel()
        listener.cancel()
    }
}

/// Owns the app-level Local Network request. macOS offers no authorization
/// query or reset API, so this object reports only what a real path proves:
/// ready, still waiting, or failed. It never promotes a loopback or Bonjour
/// setup event into permission evidence.
@MainActor
final class LocalNetworkAccessController: ObservableObject {
    typealias ConnectionFactory = (String, UInt16)
        -> any LocalNetworkDirectAccessConnection
    typealias PromptFactory = () throws -> any LocalNetworkPermissionPrompt

    /// The discard port is a stable destination for the real outbound
    /// datagram that verifies unicast LAN traffic. Starting a UDP connection
    /// only evaluates its path; queued content makes this a genuine operation
    /// rather than another readiness proxy.
    static let verificationPort: UInt16 = 9
    static let verificationPayload = Data("NOW local network verification".utf8)

    private let logger = Logger(subsystem: ProductIdentity.bundleIdentifier,
                                category: "LocalNetwork")
    private let queue = DispatchQueue(
        label: "dev.newoldworld.local-network.permission")
    private let audit: (HostLog.LogLevel, String) -> Void
    private let makeConnection: ConnectionFactory
    private let makePrompt: PromptFactory
    @Published private(set) var status = "Not checked this launch"
    private(set) var directEvidence = LocalNetworkDirectAccessEvidence.notChecked
    private(set) var directAccessReady = false
    var onDirectAccessReady: (@MainActor () -> Void)?
    private var directConnection: (any LocalNetworkDirectAccessConnection)?
    private var permissionPrompt: (any LocalNetworkPermissionPrompt)?
    private var waitingGuidance: Task<Void, Never>?

    init(audit: ((HostLog.LogLevel, String) -> Void)? = nil,
         makeConnection: ConnectionFactory? = nil,
         makePrompt: PromptFactory? = nil) {
        self.audit = audit ?? { HostLog.shared.write($0, "network", $1) }
        self.makeConnection = makeConnection ?? {
            SystemLocalNetworkDirectAccessConnection(host: $0, port: $1)
        }
        self.makePrompt = makePrompt ?? {
            try SystemLocalNetworkPermissionPrompt()
        }
    }

    /// Requests the app capability at the app boundary. This deliberately
    /// needs no guest and belongs to neither Mirror nor Continuity.
    func request() {
        stopPrompt()
        if !directAccessReady {
            status = "Requesting app-level Local Network access from macOS\u{2026}"
        }

        do {
            let prompt = try makePrompt()
            permissionPrompt = prompt
            prompt.eventHandler = { [weak self, weak prompt] event in
                Task { @MainActor in
                    guard let self, let prompt,
                          prompt === self.permissionPrompt else { return }
                    self.audit(.info, "Local Network prompt operation: \(event)")
                }
            }
            prompt.start(queue: queue)
            audit(.info, "started app-owned Local Network prompt operation")
        } catch {
            logger.error("Could not start Local Network prompt operation: \(error.localizedDescription, privacy: .public)")
            audit(.error, "could not start app-owned Local Network prompt "
                  + "operation: \(error)")
            if !directAccessReady {
                status = "Local Network request could not start: "
                    + error.localizedDescription
            }
        }
    }

    /// Separately verifies the operation Continuity actually needs. The
    /// factory receives no interface because simultaneous Wi-Fi and Ethernet
    /// are normal; the routing table owns that choice.
    func verifyDirectAccess(to host: String) {
        stopDirectRequest()
        guard !host.isEmpty else {
            directEvidence = .failed
            directAccessReady = false
            status = "Connect a Mac before checking direct Local Network access."
            return
        }

        let connection = makeConnection(host, Self.verificationPort)
        directConnection = connection
        directEvidence = .requesting
        directAccessReady = false
        status = "Requesting Local Network access to \(host) from macOS\u{2026}"
        logger.info("Requesting direct Local Network path to \(host, privacy: .public)")
        audit(.info, "verifying direct Local Network path to "
              + "\(host):\(Self.verificationPort)")

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection,
                      connection === self.directConnection else { return }
                let path = connection.pathDescription
                switch state {
                case .ready:
                    self.directAccessBecameReady(host: host, path: path)
                    self.stopDirectRequest()
                    self.stopPrompt()
                case .waiting(let error):
                    self.directAccessIsWaiting(host: host, error: error,
                                               path: path)
                    self.scheduleWaitingGuidance(host: host,
                                                 connection: connection)
                case .failed(let error):
                    self.directAccessFailed(host: host, error: error,
                                            path: path)
                    self.stopDirectRequest()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        connection.sendVerification(Self.verificationPayload) {
            [weak self, weak connection] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let connection,
                      connection === self.directConnection else { return }
                /* A prohibited path can report the queued send's ENETDOWN
                   while the system prompt is still outstanding. The path
                   state remains authoritative and must stay alive; this
                   callback is diagnostic evidence, not a second state
                   machine that cancels the request. */
                let path = connection.pathDescription
                self.logger.notice("Local Network verification datagram is queued/waiting: \(String(describing: error), privacy: .public); \(path, privacy: .public)")
                self.audit(.warn, "Local Network verification to \(host) is "
                           + "queued/waiting: \(String(describing: error)); "
                           + path)
            }
        }
    }

    /// Evidence from the operation the permission exists to serve. The real
    /// Continuity lane calls this too, so the app-level card and feature card
    /// share one truthful verdict.
    func directAccessBecameReady(host: String? = nil, path: String? = nil) {
        directEvidence = .directReady
        directAccessReady = true
        let target = host.map { " to \($0)" } ?? ""
        let route = path.map { "; \($0)" } ?? ""
        logger.info("Direct Local Network access is confirmed\(target, privacy: .public)\(route, privacy: .public)")
        audit(.info, "direct Local Network access is confirmed\(target)\(route)")
        status = "Local Network access confirmed\(target)"
        onDirectAccessReady?()
    }

    func directAccessIsWaiting(host: String, error: NWError,
                               path: String) {
        directEvidence = .waiting
        directAccessReady = false
        logger.notice("Direct Local Network path is waiting: \(String(describing: error), privacy: .public); \(path, privacy: .public)")
        audit(.warn, "direct Local Network path to \(host) is waiting: "
              + "\(String(describing: error)) \u{2014} \(error.localizedDescription); "
              + path)
        status = "Waiting for macOS Local Network access to \(host)\u{2026}"
    }

    func cancel() {
        stopDirectRequest()
        stopPrompt()
        directEvidence = .notChecked
        directAccessReady = false
        status = "Not checked this launch"
    }

    private func directAccessFailed(host: String, error: NWError,
                                    path: String) {
        directEvidence = .failed
        directAccessReady = false
        logger.error("Direct Local Network request failed: \(String(describing: error), privacy: .public); \(path, privacy: .public)")
        audit(.error, "direct Local Network request to \(host) failed: "
              + "\(String(describing: error)) \u{2014} \(error.localizedDescription); "
              + path)
        status = "Local Network request to \(host) failed: "
            + error.localizedDescription
    }

    private func scheduleWaitingGuidance(
        host: String, connection: any LocalNetworkDirectAccessConnection
    ) {
        guard waitingGuidance == nil else { return }
        waitingGuidance = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let connection, !Task.isCancelled,
                  connection === self.directConnection,
                  self.directEvidence == .waiting else { return }
            self.waitingGuidance = nil
            self.status = "macOS has not granted Local Network access to "
                + "\(host). Approve its prompt or enable NOW Continuity in "
                + "System Settings > Privacy & Security > Local Network."
        }
    }

    private func stopDirectRequest() {
        waitingGuidance?.cancel()
        waitingGuidance = nil
        let connection = directConnection
        directConnection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    private func stopPrompt() {
        let prompt = permissionPrompt
        permissionPrompt = nil
        prompt?.eventHandler = nil
        prompt?.cancel()
    }
}
