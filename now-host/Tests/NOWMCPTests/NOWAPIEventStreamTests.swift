import XCTest
import Darwin
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class NOWAPIEventStreamTests: XCTestCase {
    func testSlowConsumerCollapsesToOneBoundedResyncFrame() async throws {
        let bus = HostEventBus()
        let stream = NOWAPISSEStream(
            bus: bus, maximumBufferedFrames: 4, startsHeartbeat: false)
        _ = try await next(stream) // stream.ready

        for _ in 0..<100 { bus.publish(.rosterChanged) }

        XCTAssertLessThanOrEqual(stream.bufferedFrameCount, 4)
        let frame = try await next(stream)
        XCTAssertTrue(text(frame).contains("event: stream.resync-required"))
        XCTAssertTrue(text(frame).contains("\"liveOnly\":true"))
        XCTAssertTrue(text(frame).contains("\"replay\":false"))
        stream.cancel()
    }

    func testPublicTranslationUsesTheEventGuestNotCurrentFocus() async throws {
        let bus = HostEventBus()
        let stream = NOWAPISSEStream(bus: bus, startsHeartbeat: false)
        _ = try await next(stream)
        let first = GuestKey(machine: try XCTUnwrap(GuestID("pb1400c")),
                             session: UUID())
        let background = GuestKey(machine: try XCTUnwrap(GuestID("q950")),
                                  session: UUID())

        bus.publish(.guestConnected(background))
        let frame = text(try await next(stream))

        XCTAssertTrue(frame.contains("\"id\":\"q950\""))
        XCTAssertTrue(frame.contains(background.text))
        XCTAssertFalse(frame.contains(first.text))
        XCTAssertFalse(frame.contains("pb1400c"))
        stream.cancel()
    }

    func testFileAndDisconnectEventsNeverLeakPrivateStrings() throws {
        let key = GuestKey(machine: try XCTUnwrap(GuestID("pb1400c")),
                           session: UUID())
        let secretURL = URL(fileURLWithPath: "/Volumes/Secret Disk/Secret Folder/file")
        let file = try XCTUnwrap(NOWAPIPublicEventTranslator.translate(
            .fileReceived(key, url: secretURL, bytes: 12,
                          guestName: "private-guest-name")))
        let disconnected = try XCTUnwrap(NOWAPIPublicEventTranslator.translate(
            .guestDisconnected(key, reason: "socket at /private/reason")))
        let encoded = String(data: try JSONEncoder().encode([file, disconnected]),
                             encoding: .utf8) ?? ""

        XCTAssertFalse(encoded.contains("/Volumes/Secret Disk"))
        XCTAssertFalse(encoded.contains("Secret Folder"))
        XCTAssertFalse(encoded.contains("private-guest-name"))
        XCTAssertFalse(encoded.contains("/private/reason"))
        XCTAssertNil(NOWAPIPublicEventTranslator.translate(
            .fileTreeChanged(key, side: .host, path: "/host/private")))
    }

    func testRouteRejectsReplayAndProducesARealStreamingResponse() async throws {
        let host = EventFixtureHost()
        let router = NOWAPIHTTPRouter(
            apiKey: "key", contractDigest: String(repeating: "d", count: 64),
            host: host)
        let replay = await router.respond(to: request(
            headers: ["x-api-key": "key", "accept": "text/event-stream",
                      "last-event-id": "42"]))
        let cursor = await router.respond(to: request(
            target: "/api/v1/events?cursor=42",
            headers: ["x-api-key": "key", "accept": "text/event-stream"]))
        let live = await router.respond(to: request(
            headers: ["x-api-key": "key", "accept": "text/event-stream"]))

        XCTAssertEqual(replay.status, 409)
        XCTAssertEqual(cursor.status, 409)
        XCTAssertTrue(String(data: replay.body, encoding: .utf8)?
            .contains("event_replay_unsupported") == true)
        XCTAssertEqual(live.status, 200)
        XCTAssertNotNil(live.streamingBody)
        let head = String(data: live.wireHeadData, encoding: .utf8) ?? ""
        XCTAssertTrue(head.contains("Connection: keep-alive"))
        XCTAssertTrue(head.contains("Transfer-Encoding: chunked"))
        XCTAssertFalse(head.contains("Content-Length:"))
        live.streamingBody?.cancel()
    }

    func testCancelDetachesFromHostEventBus() async {
        let bus = HostEventBus()
        let stream = NOWAPISSEStream(bus: bus, startsHeartbeat: false)
        XCTAssertEqual(bus.subscriberCount, 1)
        stream.cancel()
        await Task.yield()
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testRouteCapsConcurrentStreamsAndCancelReturnsTheLease() async {
        let host = EventFixtureHost(maximumStreams: 1)
        let router = NOWAPIHTTPRouter(
            apiKey: "key", contractDigest: String(repeating: "d", count: 64),
            host: host)
        let headers = ["x-api-key": "key", "accept": "text/event-stream"]

        let first = await router.respond(to: request(headers: headers))
        let refused = await router.respond(to: request(headers: headers))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(refused.status, 429)
        XCTAssertTrue(String(data: refused.body, encoding: .utf8)?
            .contains("event_stream_limit_reached") == true)

        first.streamingBody?.cancel()
        let replacement = await router.respond(to: request(headers: headers))
        XCTAssertEqual(replacement.status, 200)
        replacement.streamingBody?.cancel()
    }

    func testListenerKeepsSSEOpenAndClientCloseCancelsSubscription() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let host = EventFixtureHost()
        let listener = try MCPHTTPListener(
            configuration: .init(port: port, bearerToken: "mcp-token"),
            serverFactory: {
                (NOWMCPServer(client: SocketAgentIntegrationClient(),
                              audit: LocalMCPAuditSink()),
                 NOWMCPClientIdentity())
            },
            apiRouter: NOWAPIHTTPRouter(
                apiKey: "key", contractDigest: String(repeating: "d", count: 64),
                host: host))
        try await listener.start()
        defer { listener.stop() }

        let received = try await Self.readOneSSEFrame(port: port)
        XCTAssertTrue(received.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(received.contains("Connection: keep-alive"))
        XCTAssertTrue(received.contains("Transfer-Encoding: chunked"))
        XCTAssertTrue(received.contains("event: stream.ready"))

        for _ in 0..<20 where host.bus.subscriberCount != 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(host.bus.subscriberCount, 0)
    }

    private func next(_ stream: NOWAPISSEStream) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            stream.next { data in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CancellationError()) }
            }
        }
    }

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private func request(
        target: String = "/api/v1/events", headers: [String: String]
    ) -> MCPHTTPRequest {
        .init(method: "GET", target: target, headers: headers, body: Data())
    }

    private nonisolated static func readOneSSEFrame(port: UInt16) async throws
        -> String {
        try await Task.detached {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) {
                Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
                                  socklen_t(MemoryLayout<timeval>.size))
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            let request = "GET /api/v1/events HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "X-API-Key: key\r\nAccept: text/event-stream\r\n\r\n"
            try request.withCString { pointer in
                let count = strlen(pointer)
                guard Darwin.send(descriptor, pointer, count, 0) == count
                else { throw POSIXError(.EIO) }
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: data, as: UTF8.self)
                .contains("event: stream.ready") {
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
                data.append(contentsOf: buffer.prefix(count))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

@MainActor
private final class EventFixtureHost: NOWAPIHostServing {
    let bus = HostEventBus()
    private let streams: NOWAPIEventStreamPool

    init(maximumStreams: Int = NOWAPIEventStreamPool.defaultMaximumStreams) {
        streams = NOWAPIEventStreamPool(
            bus: bus, maximumStreams: maximumStreams)
    }
    func apiGuests() -> [NOWAPIGuestSummary] { [] }
    func apiGuest(id: String) -> NOWAPIGuestDetail? { nil }
    func apiListener() -> NOWAPIListenerSummary {
        .init(state: "idle", desiredPorts: [], boundPorts: [])
    }
    func apiStartListener() -> NOWAPIListenerSummary { apiListener() }
    func apiStopListener() -> NOWAPIListenerSummary { apiListener() }
    func apiConnections() -> [NOWAPIConnectionSummary] { [] }
    func apiDisconnect(sessionID: String) -> Bool { false }
    func apiEventStream() -> NOWAPISSEStream? {
        streams.open(startsHeartbeat: false)
    }
    func apiExecuteCommand(
        guestID: String, expectedSessionID: String,
        request: NOWAPIConsoleCommandRequest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void
    ) {}
}
