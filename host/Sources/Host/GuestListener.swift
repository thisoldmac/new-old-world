import Foundation
import Network

/// The host side of the wire: listens, gates on hello, serves exactly one
/// guest at a time, answers pings, and declares death passively after
/// `timing.idleTimeout` without traffic (the host never pings — see
/// contract/asyncapi.yaml).
@MainActor
final class GuestListener: ObservableObject {
    enum State: Equatable {
        case idle
        case listening(port: UInt16)
        case connected(guestName: String)
        case failed(String)
    }

    struct Timing: Sendable {
        var idleTimeout: TimeInterval = 75
    }

    struct HostIdentity: Sendable {
        var version: String
        var name: String
    }

    /// One line of connection history, newest kept at the front by the view.
    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String

        static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
            lhs.at == rhs.at && lhs.text == rhs.text
        }
    }

    /// Live diagnostics for the currently connected guest.
    struct SessionHealth: Equatable {
        var guestName: String
        var guestVersion: String?
        var guestOS: String?
        var connectedAt: Date
        var lastTraffic: Date
        var pingsAnswered: Int
        var framesReceived: Int
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastDisconnect: String?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var health: SessionHealth?

    private let identity: HostIdentity
    private let timing: Timing
    private var listener: NWListener?
    private var session: Session?

    init(identity: HostIdentity, timing: Timing = Timing()) {
        self.identity = identity
        self.timing = timing
    }

    private static let logLimit = 100

    func note(_ text: String) {
        log.append(LogEntry(at: Date(), text: text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    func start(port: UInt16) {
        stop()
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)
                ?? NWEndpoint.Port(rawValue: 0)!
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] nwState in
                Task { @MainActor in self?.listenerStateChanged(nwState) }
            }
            listener.start(queue: .main)
        } catch {
            state = .failed("Could not listen: \(error.localizedDescription)")
            note("Could not listen: \(error.localizedDescription)")
        }
    }

    func stop() {
        session?.close(sending: Bye(code: .shuttingDown, reason: nil))
        session = nil
        listener?.cancel()
        listener = nil
        state = .idle
    }

    /// The port actually bound (differs from the requested one when 0 was
    /// passed for an ephemeral port — used by tests).
    var boundPort: UInt16? { listener?.port?.rawValue }

    private func listenerStateChanged(_ nwState: NWListener.State) {
        switch nwState {
        case .ready:
            note("Listening on port \(boundPort ?? 0)")
            if case .connected = state { return }
            state = .listening(port: boundPort ?? 0)
        case .failed(let error):
            state = .failed(error.localizedDescription)
            note("Listener failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let newSession = Session(
            connection: connection, identity: identity, timing: timing,
            isBusy: { [weak self] in
                guard let session = self?.session else { return nil }
                return session.guestName
            },
            onActive: { [weak self] activated in
                guard let self else { return }
                self.pending.removeAll { $0 === activated }
                self.session = activated
                self.state = .connected(guestName: activated.guestName)
            },
            onLog: { [weak self] text in self?.note(text) },
            onHealth: { [weak self] health in self?.health = health },
            onClosed: { [weak self] closedSession, reason in
                guard let self else { return }
                self.pending.removeAll { $0 === closedSession }
                guard self.session === closedSession else { return }
                self.session = nil
                self.health = nil
                self.lastDisconnect = reason
                if self.listener != nil {
                    self.state = .listening(port: self.boundPort ?? 0)
                }
            })
        pending.append(newSession)
        newSession.begin()
    }

    // Sessions that have not passed the hello gate yet. An accepted-but-busy
    // connection lives here just long enough to be refused politely.
    private var pending: [Session] = []
}

/// One connection's lifecycle: awaiting hello -> active -> closed.
@MainActor
final class Session {
    let connection: NWConnection
    private let identity: GuestListener.HostIdentity
    private let timing: GuestListener.Timing
    private let isBusy: () -> String?
    private let onActive: (Session) -> Void
    private let onLog: (String) -> Void
    private let onHealth: (GuestListener.SessionHealth?) -> Void
    private let onClosed: (Session, String) -> Void
    private var health: GuestListener.SessionHealth?

    private let decoder = FrameDecoder()
    private var helloed = false
    private var closed = false
    private(set) var guestName = "guest"
    private var idleTask: Task<Void, Never>?

    init(connection: NWConnection,
         identity: GuestListener.HostIdentity,
         timing: GuestListener.Timing,
         isBusy: @escaping () -> String?,
         onActive: @escaping (Session) -> Void,
         onLog: @escaping (String) -> Void,
         onHealth: @escaping (GuestListener.SessionHealth?) -> Void,
         onClosed: @escaping (Session, String) -> Void) {
        self.connection = connection
        self.identity = identity
        self.timing = timing
        self.isBusy = isBusy
        self.onActive = onActive
        self.onLog = onLog
        self.onHealth = onHealth
        self.onClosed = onClosed
    }

    func begin() {
        connection.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor in
                switch nwState {
                case .failed, .cancelled:
                    self?.finish(reason: "Connection lost")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receiveLoop()
        resetIdleClock()
    }

    func close(sending bye: Bye) {
        finish(reason: "Closed", sending: .bye(bye))
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.resetIdleClock()
                    self.consume(data)
                }
                if done || error != nil {
                    self.finish(reason: "Connection lost")
                } else if !self.closed {
                    self.receiveLoop()
                }
            }
        }
    }

    private func touchHealth(framesDelta: Int = 0, pingsDelta: Int = 0) {
        guard var h = health else { return }
        h.lastTraffic = Date()
        h.framesReceived += framesDelta
        h.pingsAnswered += pingsDelta
        health = h
        onHealth(h)
    }

    private func consume(_ data: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.feed(data)
        } catch {
            protocolError("malformed frame: \(error)")
            return
        }
        touchHealth(framesDelta: frames.count)
        for frame in frames {
            switch frame.header.channel {
            case .control:
                handleControl(frame.payload)
            case .bulk:
                // No transfers exist in this slice; bulk before capture
                // support is a protocol error, not silently ignored.
                protocolError("unexpected bulk frame")
            }
            if closed { return }
        }
    }

    private func handleControl(_ payload: Data) {
        let message: ControlMessage
        do {
            message = try ControlMessageCodec.decode(payload)
        } catch {
            protocolError("bad control message: \(error)")
            return
        }
        guard helloed else {
            guard case .hello(let hello) = message else {
                protocolError("expected hello first")
                return
            }
            gate(hello)
            return
        }
        switch message {
        case .ping(let id):
            send(.pong(id: id))
            touchHealth(pingsDelta: 1)
        case .bye(let bye):
            let name = guestName
            finish(reason: byeDescription(bye, guest: name))
        case .hello:
            protocolError("duplicate hello")
        default:
            // capture flow arrives with the screenshots slice
            break
        }
    }

    private func gate(_ hello: Hello) {
        if hello.contract != Contract.revision {
            refuse("contract revision \(hello.contract) != \(Contract.revision)")
            return
        }
        if let connectedName = isBusy() {
            refuse("busy: \(connectedName)")
            return
        }
        helloed = true
        guestName = hello.name ?? "Classic Mac"
        let chunk = min(hello.chunk ?? Contract.defaultChunk,
                        Contract.defaultChunk)
        send(.hello(Hello(contract: Contract.revision, side: "host",
                          version: identity.version, name: identity.name,
                          os: nil, chunk: chunk)))
        let now = Date()
        health = GuestListener.SessionHealth(
            guestName: guestName, guestVersion: hello.version,
            guestOS: hello.os, connectedAt: now, lastTraffic: now,
            pingsAnswered: 0, framesReceived: 1)
        onHealth(health)
        var line = "Connected: \(guestName)"
        if !hello.version.isEmpty {
            line += " (guest \(hello.version)"
            line += hello.os.map { ", OS \($0))" } ?? ")"
        }
        onLog(line)
        onActive(self)
    }

    private func refuse(_ reason: String) {
        onLog("Refused a connection: \(reason)")
        finish(reason: "Refused: \(reason)",
               sending: .refuse(Refuse(contract: Contract.revision,
                                       reason: reason)))
    }

    private func protocolError(_ detail: String) {
        finish(reason: "Protocol error: \(detail)",
               sending: .bye(Bye(code: .protocolError, reason: detail)))
    }

    private func send(_ message: ControlMessage) {
        guard let payload = try? ControlMessageCodec.encode(message),
              let frame = try? FrameCodec.encode(channel: .control,
                                                 payload: payload) else {
            return
        }
        connection.send(content: frame, completion: .idempotent)
    }

    private func resetIdleClock() {
        idleTask?.cancel()
        let timeout = timing.idleTimeout
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            guard !Task.isCancelled else { return }
            self?.finish(reason: "Connection lost (no traffic)")
        }
    }

    /// Ends the session. When a farewell message is given it is flushed
    /// before the connection is cancelled — cancel() drops unsent data,
    /// which would eat the very refuse/bye the peer needs to see.
    private func finish(reason: String, sending farewell: ControlMessage? = nil) {
        guard !closed else { return }
        closed = true
        if helloed {
            onLog(reason)
        }
        idleTask?.cancel()
        if let farewell,
           let payload = try? ControlMessageCodec.encode(farewell),
           let frame = try? FrameCodec.encode(channel: .control,
                                              payload: payload) {
            let connection = self.connection
            connection.send(content: frame,
                            completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
        onClosed(self, reason)
    }

    private func byeDescription(_ bye: Bye, guest: String) -> String {
        switch bye.code {
        case .normal: return "\(guest) disconnected"
        case .shuttingDown: return "\(guest) is shutting down"
        case .protocolError:
            return "Protocol error: \(bye.reason ?? "unspecified")"
        }
    }
}
