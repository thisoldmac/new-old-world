import Foundation

/// One deliberately small public notification. Events are hints that tell a
/// client which ordinary resource to fetch again; they are never replacement
/// state and never serialize HostEvent's private associated values.
struct NOWAPIPublicEvent: Codable, Equatable, Sendable {
    struct Guest: Codable, Equatable, Sendable {
        let id: String
        let sessionID: String

        enum CodingKeys: String, CodingKey {
            case id
            case sessionID = "sessionId"
        }
    }

    let type: String
    var guest: Guest? = nil
    var receivedBytes: Int? = nil
    var expectedBytes: Int? = nil
    var liveOnly: Bool? = nil
    var replay: Bool? = nil
    let refetch: [String]
}

/// The privacy boundary between the host's rich in-process bus and v1.
/// Exhaustive matching makes a new HostEvent private until it is reviewed and
/// explicitly admitted here.
enum NOWAPIPublicEventTranslator {
    @MainActor
    static func translate(_ event: HostEvent) -> NOWAPIPublicEvent? {
        switch event {
        case .guestConnected(let key):
            return guestEvent("guest.connected", key,
                              refetch: ["/api/v1/guests", "/api/v1/connections"])
        case .guestDisconnected(let key, _):
            return guestEvent("guest.disconnected", key,
                              refetch: ["/api/v1/guests", "/api/v1/connections"])
        case .guestRenamed(let key, let id):
            return .init(
                type: "guest.changed",
                guest: .init(id: id.slug, sessionID: key.text),
                refetch: ["/api/v1/guests", "/api/v1/connections"])
        case .rosterChanged:
            return .init(type: "guests.changed", refetch: ["/api/v1/guests"])
        case .linkStateChanged:
            return .init(type: "listener.changed", refetch: ["/api/v1/listener"])
        case .transferProgressed(let key?, let received, let expected):
            return .init(
                type: "transfer.progressed", guest: guest(key),
                receivedBytes: max(0, received), expectedBytes: max(0, expected),
                refetch: ["/api/v1/transfers"])
        case .transferEnded(let key?):
            return guestEvent("transfers.changed", key,
                              refetch: ["/api/v1/transfers"])
        case .fileReceived(let key?, _, _, _):
            // The URL is a private host landing and guestName is untrusted
            // display text. Neither crosses this boundary.
            return guestEvent("files.changed", key,
                              refetch: ["/api/v1/guests/\(key.machine.slug)/files"])
        case .fileTreeChanged(let key?, let side, _):
            guard side == .guest else { return nil }
            // The path is omitted even for the guest side: invalidation is
            // enough, and keeping paths out makes the privacy rule uniform.
            return guestEvent("files.changed", key,
                              refetch: ["/api/v1/guests/\(key.machine.slug)/files"])
        case .processListChanged(let key?):
            return guestEvent("processes.changed", key,
                              refetch: ["/api/v1/guests/\(key.machine.slug)"])
        case .focusChanged, .captureArrived, .streamFrame,
             .streamStateChanged, .transferProgressed(nil, _, _),
             .transferEnded(nil), .updateFinished, .fileReceived(nil, _, _, _),
             .fileTreeChanged(nil, _, _), .processListChanged(nil),
             .mirrorInvalidated, .guestReportedError:
            return nil
        }
    }

    private static func guestEvent(
        _ type: String, _ key: GuestKey, refetch: [String]
    ) -> NOWAPIPublicEvent {
        .init(type: type, guest: guest(key), refetch: refetch)
    }

    private static func guest(_ key: GuestKey) -> NOWAPIPublicEvent.Guest {
        .init(id: key.machine.slug, sessionID: key.text)
    }
}

/// A bounded pull source for one SSE response. Producers may publish faster
/// than the socket can send; at the bound, detailed hints collapse to one
/// resync-required frame. The connection asks for the next frame only after
/// Network reports the previous write consumed.
final class NOWAPISSEStream: MCPHTTPStreamingBody, @unchecked Sendable {
    static let defaultMaximumBufferedFrames = 16
    static let heartbeatInterval: TimeInterval = 15

    private let lock = NSLock()
    private let maximumBufferedFrames: Int
    private var frames: [Data] = []
    private var waiter: (@Sendable (Data?) -> Void)?
    private var overflowed = false
    private var cancelled = false
    private var subscription: HostEventSubscription?
    private var heartbeat: DispatchSourceTimer?
    private var onCancel: (@Sendable () -> Void)?

    @MainActor
    init(bus: HostEventBus,
         maximumBufferedFrames: Int = defaultMaximumBufferedFrames,
         startsHeartbeat: Bool = true,
         onCancel: @escaping @Sendable () -> Void = {}) {
        self.maximumBufferedFrames = max(1, maximumBufferedFrames)
        self.onCancel = onCancel
        enqueue(Self.frame(.init(
            type: "stream.ready", liveOnly: true, replay: false,
            refetch: ["/api/v1/guests", "/api/v1/connections",
                      "/api/v1/listener", "/api/v1/transfers"])))
        subscription = bus.subscribe { [weak self] event in
            guard let publicEvent = NOWAPIPublicEventTranslator.translate(event)
            else { return }
            self?.enqueue(Self.frame(publicEvent))
        }
        if startsHeartbeat { startHeartbeat() }
    }

    func next(_ completion: @escaping @Sendable (Data?) -> Void) {
        let result: Data?
        lock.lock()
        if cancelled {
            result = nil
        } else if !frames.isEmpty {
            result = frames.removeFirst()
            if result == Self.resyncFrame { overflowed = false }
        } else {
            waiter = completion
            lock.unlock()
            return
        }
        lock.unlock()
        completion(result)
    }

    func cancel() {
        let pending: (@Sendable (Data?) -> Void)?
        let activeSubscription: HostEventSubscription?
        let release: (@Sendable () -> Void)?
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        pending = waiter
        waiter = nil
        frames.removeAll(keepingCapacity: false)
        activeSubscription = subscription
        subscription = nil
        let timer = heartbeat
        heartbeat = nil
        release = onCancel
        onCancel = nil
        lock.unlock()
        timer?.cancel()
        pending?(nil)
        release?()
        if let activeSubscription {
            Task { @MainActor in activeSubscription.unsubscribe() }
        }
    }

    var bufferedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    private func enqueue(_ frame: Data) {
        let pending: (@Sendable (Data?) -> Void)?
        let delivered: Data
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        if let waiter {
            pending = waiter
            self.waiter = nil
            delivered = frame
        } else {
            pending = nil
            delivered = frame
            if overflowed {
                lock.unlock()
                return
            }
            if frames.count >= maximumBufferedFrames {
                frames = [Self.resyncFrame]
                overflowed = true
            } else {
                frames.append(frame)
            }
        }
        lock.unlock()
        pending?(delivered)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.newoldworld.api-sse-heartbeat"))
        timer.schedule(deadline: .now() + Self.heartbeatInterval,
                       repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.enqueueHeartbeat()
        }
        heartbeat = timer
        timer.resume()
    }

    private func enqueueHeartbeat() {
        lock.lock()
        let mayEnqueue = !cancelled && frames.isEmpty && waiter != nil
        lock.unlock()
        if mayEnqueue { enqueue(Data(": heartbeat\n\n".utf8)) }
    }

    private static let resyncFrame = frame(.init(
        type: "stream.resync-required", liveOnly: true, replay: false,
        refetch: ["/api/v1/guests", "/api/v1/connections",
                  "/api/v1/listener", "/api/v1/transfers"]))

    private static func frame(_ event: NOWAPIPublicEvent) -> Data {
        let payload = (try? JSONEncoder.sorted.encode(event)) ?? Data("{}".utf8)
        return Data("event: \(event.type)\ndata: ".utf8)
            + payload + Data("\n\n".utf8)
    }
}

/// Caps the timers, subscriptions, and encoding work a local client can hold
/// open at once. Each host owns one pool; cancelling a stream returns its
/// lease synchronously, including peer-close cancellation.
final class NOWAPIEventStreamPool: @unchecked Sendable {
    static let defaultMaximumStreams = 8

    private let bus: HostEventBus
    private let maximumStreams: Int
    private let lock = NSLock()
    private var activeStreams = 0

    init(bus: HostEventBus,
         maximumStreams: Int = defaultMaximumStreams) {
        self.bus = bus
        self.maximumStreams = max(1, maximumStreams)
    }

    @MainActor
    func open(startsHeartbeat: Bool = true) -> NOWAPISSEStream? {
        lock.lock()
        guard activeStreams < maximumStreams else {
            lock.unlock()
            return nil
        }
        activeStreams += 1
        lock.unlock()
        return NOWAPISSEStream(
            bus: bus, startsHeartbeat: startsHeartbeat,
            onCancel: { [weak self] in self?.release() })
    }

    var activeStreamCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeStreams
    }

    private func release() {
        lock.lock()
        activeStreams = max(0, activeStreams - 1)
        lock.unlock()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
