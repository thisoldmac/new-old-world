import XCTest
@testable import NOWAgentIntegration

/// The bracket's own wire shapes.
///
/// Its own file rather than more rows in the P1a codec tests: those cover
/// eleven verbs that arrived as one batch, and this is one operation whose
/// interesting property is the opposite of theirs — its three intentions are
/// told apart by a REQUIRED field rather than by which optional turned up.
///
/// Written the way that file is written, and for the same reason: a request
/// whose point is that a decode branch admits it is hand-authored JSON, never
/// a round trip through our own encoder. A test that encodes with the codec
/// it then decodes with tests one half twice.
final class AgentIntegrationStreamCodecTests: XCTestCase {

    private func requestObject(_ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "stream",
        ]
        for (key, value) in fields { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertRefused(_ fields: [String: Any],
                               _ because: String,
                               line: UInt = #line) throws {
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(
                try requestObject(fields)),
            because, line: line)
    }

    // MARK: - Every shape survives the codec

    private static let samples: [AgentIntegrationLocalRequest] = [
        .streamStart(depth: 8, minIntervalMs: 1_000),
        .streamStart(depth: 1, minIntervalMs: 100),
        .streamFrame(),
        .streamFramePage(
            frameID: UUID(),
            offset: AgentIntegrationCapturePolicy.pageBytes),
        .streamStop(),
    ]

    func testEveryStreamRequestSurvivesTheCodec() throws {
        for sample in Self.samples {
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                try AgentIntegrationLocalCodec.encode(sample))
            XCTAssertEqual(decoded, sample)
        }
    }

    func testEveryStreamRequestSurvivesAddressed() throws {
        for sample in Self.samples {
            var addressed = sample
            addressed.guestSelector = "pb1400c"
            let decoded = try AgentIntegrationLocalCodec.decodeRequest(
                try AgentIntegrationLocalCodec.encode(addressed))
            XCTAssertEqual(decoded, addressed)
        }
    }

    /// The samples cover all three intentions, so a missing one cannot hide
    /// behind however many shapes somebody remembered to list.
    func testTheSamplesCoverEveryIntention() {
        XCTAssertEqual(
            Set(Self.samples.compactMap(\.streamIntention)),
            Set(AgentIntegrationStreamIntention.allCases))
    }

    // MARK: - Companion-authored requests

    func testCompanionAuthoredStartIsAdmitted() throws {
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject([
                "streamIntention": "start",
                "streamDepth": 4,
                "streamMinIntervalMs": 500,
            ]))
        XCTAssertEqual(decoded.streamIntention, .start)
        XCTAssertEqual(decoded.streamDepth, 4)
        XCTAssertEqual(decoded.streamMinIntervalMs, 500)
    }

    /// A bare `frame` is a complete request — it means "the next one" — while
    /// a bare `start` is not. The asymmetry is the whole reason the intention
    /// is a field rather than an inference from which optional arrived.
    func testABareFrameIsCompleteAndABareStartIsNot() throws {
        let frame = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject(["streamIntention": "frame"]))
        XCTAssertEqual(frame.streamIntention, .frame)
        XCTAssertNil(frame.streamFrameID)

        try assertRefused(
            ["streamIntention": "start"],
            "a start with no depth and no pace named neither, and the pace "
                + "in particular must never fall back to the guest's floor")
    }

    func testAStopCarriesNothingAndSaysOnlyItsName() throws {
        let decoded = try AgentIntegrationLocalCodec.decodeRequest(
            try requestObject(["streamIntention": "stop"]))
        XCTAssertEqual(decoded.streamIntention, .stop)
        XCTAssertNil(decoded.streamDepth)
    }

    // MARK: - What the codec refuses

    func testAnIntentionlessStreamRequestIsRefused() throws {
        try assertRefused(
            [:], "a stream request with no intention is not a request")
    }

    /// **The fps-floor hazard, refused at the boundary.** The contract reads
    /// an absent or zero `minIntervalMs` as "the guest paces itself", and
    /// this surface has no unbounded setting to hand out. The codec is where
    /// that holds for every caller, including a process writing the socket
    /// directly rather than going through the projection.
    func testAPaceOutsideTheSurfacesRangeIsRefusedAtTheCodec() throws {
        for pace in [0, 1,
                     AgentIntegrationStreamPolicy.maximumIntervalMs + 1] {
            try assertRefused(
                ["streamIntention": "start", "streamDepth": 8,
                 "streamMinIntervalMs": pace],
                "\(pace) ms was admitted by the codec")
        }
    }

    func testADepthTheGuestDoesNotImplementIsRefusedAtTheCodec() throws {
        try assertRefused(
            ["streamIntention": "start", "streamDepth": 9,
             "streamMinIntervalMs": 1_000],
            "a 9-bit stream was admitted")
    }

    /// Tuning belongs to `start`, and the per-operation key set refuses it
    /// elsewhere rather than ignoring it.
    func testStopAndFrameMayNotCarryStartsFields() throws {
        for intention in ["stop", "frame"] {
            try assertRefused(
                ["streamIntention": intention, "streamDepth": 8,
                 "streamMinIntervalMs": 1_000],
                "\(intention) was admitted carrying start's fields")
        }
    }

    /// Half a page fetch is a request nothing can serve, in either
    /// direction — the same guard the capture page fetch keeps.
    func testHalfAPageFetchIsRefusedInEitherDirection() throws {
        try assertRefused(
            ["streamIntention": "frame",
             "streamFrameID": UUID().uuidString],
            "a frame id with no offset was admitted")
        try assertRefused(
            ["streamIntention": "frame", "streamFrameOffset": 0],
            "an offset with no frame id was admitted")
    }

    func testAnOffsetOffThePageBoundaryIsRefused() throws {
        try assertRefused(
            ["streamIntention": "frame",
             "streamFrameID": UUID().uuidString,
             "streamFrameOffset": 3],
            "an offset that is not a page boundary was admitted")
    }

    /// A stream field on another operation is refused rather than ignored,
    /// which is the property the per-operation key set exists for.
    func testStreamFieldsAreRefusedOnAnotherOperation() throws {
        var object: [String: Any] = [
            "version": AgentIntegrationLocalProtocol.version,
            "requestID": UUID().uuidString,
            "operation": "session_health",
            "streamIntention": "stop",
        ]
        object["streamIntention"] = "stop"
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeRequest(
                try JSONSerialization.data(withJSONObject: object)),
            "session_health accepted a stream intention")
    }

    // MARK: - The response side

    func testTheStreamResultIsTheOnlyThingInItsResponse() throws {
        let response = AgentIntegrationLocalResponse(
            requestID: UUID(),
            streamResult: .bracket(Self.bracket))
        let decoded = try AgentIntegrationLocalCodec.decodeResponse(
            try AgentIntegrationLocalCodec.encode(response))
        XCTAssertEqual(decoded.streamResult, response.streamResult)
        XCTAssertNil(decoded.captureResult)
    }

    /// Counted with the other results by the exactly-one-of guard, not
    /// merely admitted by the allowlist. A field admitted by one gate and
    /// uncounted by the other is a response that can carry two answers.
    func testAResponseCarryingAStreamAndACaptureIsRefused() throws {
        var response = AgentIntegrationLocalResponse(
            requestID: UUID(),
            streamResult: .bracket(Self.bracket))
        response.captureResult = .refused(.busy)
        XCTAssertThrowsError(
            try AgentIntegrationLocalCodec.decodeResponse(
                try AgentIntegrationLocalCodec.encode(response)),
            "a response carrying both a stream and a capture was admitted")
    }

    /// Every case of the result type survives, including the two that carry
    /// a picture and the two that carry a reason.
    func testEveryStreamResultCaseSurvivesTheCodec() throws {
        let results: [AgentIntegrationStreamResult] = [
            .bracket(Self.bracket),
            .frame(.init(bracket: Self.bracket, chunk: .init(
                image: Self.image,
                page: .init(offset: 0, base64: "AAEC")))),
            .refused(AgentIntegrationStreamFailure.notOpen),
            .unavailable(.guest),
        ]
        for result in results {
            let response = AgentIntegrationLocalResponse(
                requestID: UUID(), streamResult: result)
            let decoded = try AgentIntegrationLocalCodec.decodeResponse(
                try AgentIntegrationLocalCodec.encode(response))
            XCTAssertEqual(decoded.streamResult, result)
        }
    }

    private static let session = UUID()
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private static let bracket = AgentIntegrationStreamBracket(
        streamID: 3,
        sessionID: session,
        state: .open,
        origin: .agent,
        openedAt: moment,
        depth: 8,
        minIntervalMs: 1_000,
        leaseExpiresAt: moment.addingTimeInterval(60))

    private static let image = AgentIntegrationCaptureImage(
        captureID: UUID(),
        sessionID: session,
        capturedAt: moment,
        width: 640, height: 480, depth: 8,
        transferMs: 90, wireBytes: 3, bytes: 3,
        sha256: String(repeating: "a", count: 64))
}
