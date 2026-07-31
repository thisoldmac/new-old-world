import Combine
import Foundation
import XCTest
@testable import Host
import NOWAgentIntegration

/// The stream control's own coverage, and it is almost entirely about **the
/// one question a bracket asks that no other capability on this surface
/// does**: who ends it when the agent that opened it is not there any more.
///
/// The rest of the lane — opening, reading, closing — is exercised by the
/// projection's tests against a fake host and by `GuestListenerTests` against
/// a fake guest. What can only be tested here is the ownership rule, because
/// it is the only part that is a policy rather than a message.
///
/// The clock, the caller's pid and the liveness check are all injected. That
/// is not just for speed: a test that waited out a 60-second lease would be a
/// test nobody runs, and a test that asked the real kernel about a real pid
/// could only ever assert about processes it did not control.
@MainActor
final class AgentIntegrationStreamControlTests: XCTestCase {

    // MARK: - Opening it

    func testStartOpensTheBracketAndMarksItTheAgentsRatherThanThePersons()
        async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }

        let result = rig.control.start(depth: 8, minIntervalMs: 1_000)

        guard case .bracket(let bracket) = result else {
            return XCTFail("the bracket did not open: \(result)")
        }
        XCTAssertEqual(bracket.state, .open)
        XCTAssertEqual(bracket.origin, .agent)
        XCTAssertEqual(rig.listener.streamOrigin, .agent,
                       "the listener must record whose stream this is, or "
                           + "the person's page cannot tell it from theirs")
        try await rig.waitForStreamStart()
    }

    /// A person's stream is not takeable, and the refusal says whose it is.
    func testAStreamThePersonOpenedIsRefusedNamingThem() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.listener.startStream(depth: 8, origin: .person)
        try await rig.waitForStreamStart()

        let result = rig.control.start(depth: 8, minIntervalMs: 1_000)

        guard case .refused(let failure) = result else {
            return XCTFail("an agent took the lane from a person: \(result)")
        }
        XCTAssertEqual(failure.code, "now-stream-busy")
        XCTAssertTrue(failure.message.contains("person"), failure.message)
        XCTAssertEqual(rig.listener.streamOrigin, .person,
                       "the refused call must not have relabelled the "
                           + "person's own stream as an agent's")
    }

    /// A bracket opened by a caller the kernel would not name still opens,
    /// and is simply unowned. Refusing to stream because a pid lookup lost a
    /// race would punish a working agent for the accept path.
    func testABracketWithNoNameableOwnerStillOpensAndHasNoLease()
        async throws {
        let rig = try await Rig(callerProcessID: nil)
        defer { rig.tearDown() }

        let result = rig.control.start(depth: 8, minIntervalMs: 1_000)

        guard case .bracket(let bracket) = result else {
            return XCTFail("the bracket did not open: \(result)")
        }
        XCTAssertNil(bracket.leaseExpiresAt,
                     "a bracket with no owner cannot have an owner's lease")
    }

    // MARK: - The ownership rule

    /// **The case the whole rule exists for.** The agent that opened the
    /// stream is gone; nothing else on this surface would ever notice,
    /// because every other capability has already answered and finished.
    func testAStreamWhoseOwnerHasDiedIsEndedByTheHost() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        let id = try await rig.waitForStreamStart()

        rig.living.remove(Rig.owner)
        rig.control.endIfOwnerIsGone()

        try await waitUntil("stream.stop reaches the wire") {
            rig.guest.received.contains(.streamStop(StreamStop(id: id)))
        }
    }

    /// **The case liveness alone cannot catch.** The companion is still
    /// running — an MCP client left open — and nobody has read a frame for
    /// longer than the lease. A live stream nobody reads costs a 1400c
    /// exactly as much as one nobody opened.
    func testALiveOwnerThatStoppedReadingLosesTheStreamAnyway()
        async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        let id = try await rig.waitForStreamStart()
        XCTAssertTrue(rig.living.contains(Rig.owner))

        rig.now = rig.now.addingTimeInterval(
            AgentIntegrationStreamPolicy.lease + 1)
        rig.control.endIfOwnerIsGone()

        try await waitUntil("stream.stop reaches the wire") {
            rig.guest.received.contains(.streamStop(StreamStop(id: id)))
        }
    }

    /// The lease is renewed by calling, so an agent that keeps reading keeps
    /// its stream. Without this the rule would be a timer that ends every
    /// stream at 60 seconds whatever anybody was doing.
    func testCallingAgainRenewsTheLease() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        let id = try await rig.waitForStreamStart()

        /* Just short of the lease, then a call, then past where the
           ORIGINAL lease would have expired. */
        rig.now = rig.now.addingTimeInterval(
            AgentIntegrationStreamPolicy.lease - 1)
        _ = rig.control.page(frameID: UUID(), offset: 0)
        rig.now = rig.now.addingTimeInterval(2)
        rig.control.endIfOwnerIsGone()

        XCTAssertEqual(rig.listener.activeStreamId, id,
                       "an agent that is reading lost its stream")
        XCTAssertFalse(
            rig.guest.received.contains(.streamStop(StreamStop(id: id))))
    }

    /// A stream the agent did NOT open is never ended by this rule, however
    /// long its own lease has been expired. The rule ends what this surface
    /// opened and nothing else — a person's live view has no lease, and
    /// inventing one would have the agent lane closing somebody's window.
    func testAPersonsStreamIsNeverEndedByTheOwnershipRule() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        let id = try await rig.waitForStreamStart()

        /* The agent's bracket ends the ordinary way, and the person opens
           one immediately after — the case where a stale owner record would
           reach across into a stream that is not its own. */
        _ = rig.control.stop()
        try rig.guest.send(.streamStopped(StreamStopped(id: id,
                                                        reason: nil)))
        try await waitUntil("agent bracket closed") {
            rig.listener.activeStreamId == nil
        }
        rig.listener.startStream(depth: 8, origin: .person)
        let personID = try await rig.waitForStreamStart(after: id)

        rig.living.remove(Rig.owner)
        rig.now = rig.now.addingTimeInterval(
            AgentIntegrationStreamPolicy.lease * 10)
        rig.control.endIfOwnerIsGone()

        XCTAssertEqual(rig.listener.activeStreamId, personID,
                       "the agent lane ended a stream a person opened")
        XCTAssertFalse(
            rig.guest.received.contains(
                .streamStop(StreamStop(id: personID))))
    }

    // MARK: - Closing it

    /// Stopping needs no standing. The person at the host can end any
    /// stream from the page they watch it on, and an agent that could see a
    /// stream and not end it could only make things worse.
    func testAnAgentMayStopAStreamItDidNotOpen() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.listener.startStream(depth: 8, origin: .person)
        let id = try await rig.waitForStreamStart()

        let result = rig.control.stop()

        guard case .bracket(let bracket) = result else {
            return XCTFail("the stop was refused: \(result)")
        }
        XCTAssertEqual(bracket.state, .closed)
        try await waitUntil("stream.stop reaches the wire") {
            rig.guest.received.contains(.streamStop(StreamStop(id: id)))
        }
    }

    func testStoppingWhenNothingIsOpenIsARefusalAndNotASilentSuccess()
        async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }

        let result = rig.control.stop()

        guard case .refused(let failure) = result else {
            return XCTFail("a stop with nothing to stop reported success: "
                           + "\(result)")
        }
        XCTAssertEqual(failure.code, "now-stream-not-open")
    }

    func testAskingForAFrameWithNoBracketOpenIsARefusal() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }

        let result = await rig.control.nextFrame()

        guard case .refused(let failure) = result else {
            return XCTFail("a frame was produced with no stream: \(result)")
        }
        XCTAssertEqual(failure.code, "now-stream-not-open")
    }

    // MARK: - Reading a frame

    /// A frame request sends `stream.refresh` and answers with the frame
    /// that follows it — not with whatever the host happened to be holding.
    func testAFrameRequestAsksForAKeyframeAndAnswersWithWhatFollows()
        async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        let id = try await rig.waitForStreamStart()

        async let answer = rig.control.nextFrame()
        try await waitUntil("stream.refresh") {
            rig.guest.received.contains(.streamRefresh(StreamRefresh(id: id)))
        }
        try rig.sendFrame(streamID: id, transfer: 1)

        guard case .frame(let frame) = await answer else {
            return XCTFail("no frame came back")
        }
        XCTAssertEqual(frame.bracket.state, .open)
        XCTAssertEqual(frame.chunk.page.offset, 0)
        XCTAssertGreaterThan(frame.chunk.image.bytes, 0)
    }

    /// A guest that never answers the refresh is a bounded refusal, not a
    /// call that hangs. The timeout is injected so this costs a second
    /// rather than twenty.
    func testAGuestThatSendsNoFrameIsABoundedRefusal() async throws {
        let rig = try await Rig(frameTimeout: 0.4)
        defer { rig.tearDown() }
        _ = rig.control.start(depth: 8, minIntervalMs: 1_000)
        _ = try await rig.waitForStreamStart()

        let result = await rig.control.nextFrame()

        guard case .refused(let failure) = result else {
            return XCTFail("a silent guest produced a frame: \(result)")
        }
        XCTAssertEqual(failure.code, "now-stream-no-frame")
    }

    // MARK: - The rig

    /// A real listener and a fake guest, with the three things the ownership
    /// rule depends on replaced by values a test can move: the clock, the
    /// caller's pid, and whether that pid is running.
    @MainActor
    private final class Rig {
        nonisolated static let owner: pid_t = 4242

        let listener: GuestListener
        let guest: FakeGuest
        let control: AgentIntegrationStreamControl
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var living: Set<pid_t> = [Rig.owner]
        private var seen: Set<Int> = []

        init(callerProcessID: pid_t? = Rig.owner,
             frameTimeout: TimeInterval = 5) async throws {
            (listener, guest) = try await connectedListener()
            let session = UUID()
            /* The rig captures itself in three closures, which is safe here
               and would not be in the app: the control never outlives the
               test that made it, and `tearDown` drops the listener first. */
            var box: Rig?
            control = AgentIntegrationStreamControl(
                listener: listener,
                currentSessionID: { session },
                clock: { box?.now ?? Date() },
                callerProcessID: { callerProcessID },
                isProcessRunning: { pid in
                    MainActor.assumeIsolated { box?.living.contains(pid) }
                        ?? false
                },
                frameTimeout: frameTimeout)
            box = self
        }

        func tearDown() {
            guest.connection.cancel()
            listener.stop()
        }

        /// The id of the bracket the guest has just been told to open.
        @discardableResult
        func waitForStreamStart(after previous: Int? = nil) async throws
            -> Int {
            if let previous { seen.insert(previous) }
            var found: Int?
            try await waitUntil("stream.start") {
                for message in self.guest.received {
                    if case .streamStart(let start) = message,
                       !self.seen.contains(start.id) {
                        found = start.id
                        return true
                    }
                }
                return false
            }
            let id = try XCTUnwrap(found)
            seen.insert(id)
            return id
        }

        /// One whole frame on the bracket, as the guest sends them: a
        /// capture transfer whose `capture.begin` id is the stream id.
        func sendFrame(streamID: Int, transfer: Int) throws {
            var palette = [UInt8](repeating: 0, count: 256 * 3)
            palette[3] = 255
            let blob = Data(palette + [UInt8](repeating: 1, count: 8))
            try guest.send(.captureBegin(CaptureBegin(
                id: streamID, transfer: transfer, width: 4, height: 2,
                depth: 8, rowBytes: 4, bytes: blob.count,
                paletteBytes: palette.count, encoding: "raw",
                captureMs: 1, encodeMs: 1)))
            guest.sendRaw(try FrameCodec.encode(
                channel: .bulk, flags: [.end],
                transfer: UInt16(transfer), payload: blob))
            try guest.send(.captureEnd(CaptureEnd(
                id: streamID, transfer: transfer, ok: true, sendMs: 2)))
        }
    }
}
