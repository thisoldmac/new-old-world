import CryptoKit
import Foundation
import XCTest
@testable import NOWAgentIntegration

/// The stream row's own coverage, pointed at what is new about it rather than
/// at what it shares with capture.
///
/// What it shares — paging a PNG, refusing a re-staged picture, carrying the
/// bytes once — is `CaptureProjectionTests`' subject and the two rows run the
/// same loop; the frame cases here are the ones where a *stream* makes the
/// same failure likelier rather than merely possible, because on a live
/// stream the next frame is a second away.
///
/// What is new is the bracket: three intentions on one row, a lane that is
/// held rather than borrowed, and an answer that has to say whether it is
/// still open.
///
/// Nothing here constructs a bracket and then parses its own construction.
/// The fake host serves pages and remembers what it was asked; every claim is
/// about what the projection did with those answers.
final class StreamProjectionTests: XCTestCase {

    // MARK: - Three intentions, one row

    func testStartOpensTheBracketAndReportsIt() async throws {
        let host = StreamHost(png: Self.bytes(count: 64))
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "start"]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .opened)
        XCTAssertEqual(answer.stream?.state, .open)
        XCTAssertEqual(answer.stream?.origin, .agent)
        let opened = await host.opened
        XCTAssertNotNil(opened)
    }

    func testStopClosesItAndSaysSoRatherThanReportingItOpen() async throws {
        let host = StreamHost(png: Self.bytes(count: 64))
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "stop"]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .closed)
        XCTAssertEqual(answer.stream?.state, .closed)
        let stopped = await host.stopped
        XCTAssertTrue(stopped)
    }

    /// The pace a caller did not choose is the policy constant, and it is
    /// **never absent**.
    ///
    /// The contract reads an absent `minIntervalMs` as "the guest paces
    /// itself" — about 15 fps — which is the fps-floor hazard this surface
    /// exists on the wrong side of: an agent reads one frame per call, so a
    /// stream nobody bounded is a Macintosh grabbing fifteen screens a second
    /// for one reader. If this ever passes nil through, that is the defect.
    func testAnOmittedPaceIsTheSurfacesOwnCeilingAndNotTheGuestsFloor()
        async {
        let host = StreamHost(png: Self.bytes(count: 64))
        _ = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "start"]), through: host)
        let opened = await host.opened
        XCTAssertEqual(opened?.minIntervalMs,
                       AgentIntegrationStreamPolicy.defaultMinIntervalMs)
        XCTAssertEqual(opened?.depth,
                       AgentIntegrationCapturePolicy.defaultDepth)
    }

    func testAPaceOutsideTheSurfacesRangeIsRefusedBeforeAnythingIsSent()
        async {
        let host = StreamHost(png: Self.bytes(count: 64))
        for pace in [0, 1,
                     AgentIntegrationStreamPolicy.maximumIntervalMs + 1] {
            let outcome = await StreamScreenProjection.invoke(
                .init(raw: ["intention": "start", "minIntervalMs": pace]),
                through: host)
            guard case .invalidArguments = outcome else {
                return XCTFail(
                    "A pace of \(pace) ms was accepted. Zero in particular "
                        + "is the contract's spelling of 'unbounded'.")
            }
        }
        let opened = await host.opened
        XCTAssertNil(opened, "A refused pace must cost the guest nothing.")
    }

    /// Tuning belongs to `start` alone, and sending it with a stop is
    /// refused rather than ignored: a caller that sent it believes it is
    /// tuning something.
    func testStopAndFrameRefuseTheArgumentsOnlyStartTakes() async {
        let host = StreamHost(png: Self.bytes(count: 64))
        for intention in ["stop", "frame"] {
            let outcome = await StreamScreenProjection.invoke(
                .init(raw: ["intention": intention, "depth": 1]),
                through: host)
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail("\(intention) accepted a depth.")
            }
            XCTAssertTrue(message.contains("depth"), message)
        }
        let stopped = await host.stopped
        XCTAssertFalse(stopped)
    }

    func testAnIntentionThisRowDoesNotHaveIsRefusedNamingTheThree() async {
        let host = StreamHost(png: Self.bytes(count: 64))
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "pause"]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An intention this row does not have was taken.")
        }
        XCTAssertTrue(message.contains("start"), message)
    }

    func testAnUnknownArgumentIsRefusedNamingIt() async {
        let host = StreamHost(png: Self.bytes(count: 64))
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "start", "quality": 3]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An argument this row does not take was accepted.")
        }
        XCTAssertTrue(message.contains("quality"), message)
    }

    // MARK: - A frame is a picture, carried once

    func testAMultiPageFrameArrivesAsOneImageAndOneCopyOfIt() async throws {
        let png = Self.bytes(count:
            AgentIntegrationCapturePolicy.pageBytes * 2 + 977)
        let host = StreamHost(png: png)
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "frame"]), through: host)

        let value = try Self.value(outcome)
        guard case .image(let bytes, let mimeType)? = value.attachment else {
            return XCTFail("The frame came back with no image attached; a "
                           + "caller would have metadata and no picture.")
        }
        XCTAssertEqual(bytes, png)
        XCTAssertEqual(mimeType, "image/png")
        let pages = await host.pageRequests
        XCTAssertEqual(pages, [
            AgentIntegrationCapturePolicy.pageBytes,
            AgentIntegrationCapturePolicy.pageBytes * 2,
        ])

        let answer = try Self.answer(value)
        XCTAssertEqual(answer.outcome, .frame)
        XCTAssertEqual(answer.frame?.bytes, png.count)
        let json = try Self.structured(value)
        XCTAssertFalse(
            json.contains(png.prefix(64).base64EncodedString()),
            "The frame's bytes appear in the structured result as well as "
                + "the attachment, so every frame is carried twice.")
    }

    /// A frame re-staged mid-fetch is caught rather than stitched.
    ///
    /// The same guard capture keeps, and the reason it matters more here is
    /// arithmetic: a capture is re-staged only if another call takes one,
    /// while a stream produces a new frame every `minIntervalMs`, so on this
    /// row the race is the normal case rather than the unlucky one.
    func testAFrameRestagedMidFetchIsRefusedRatherThanStitched()
        async throws {
        let host = StreamHost(
            png: Self.bytes(count:
                AgentIntegrationCapturePolicy.pageBytes * 2),
            restageAfterFirstPage: true)
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "frame"]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-stream-frame-stale")
    }

    func testAMismatchedDigestIsRefusedRatherThanShown() async throws {
        let host = StreamHost(png: Self.bytes(count: 64),
                              lieAboutDigest: true)
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "frame"]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code,
                       "now-stream-frame-digest-mismatch")
    }

    /// **A bracket that closed while its frame was being read out is
    /// reported closed.**
    ///
    /// The picture is still whole and is still handed over — the frame was
    /// captured before the stream ended — but a caller told the stream is
    /// open would ask for another frame and be refused for a reason it has
    /// no way to connect to this call. The bracket therefore comes off the
    /// LAST page rather than the first.
    func testABracketThatClosedMidFetchIsReportedClosedWithTheFrame()
        async throws {
        let png = Self.bytes(count:
            AgentIntegrationCapturePolicy.pageBytes + 12)
        let host = StreamHost(png: png, closeAfterFirstPage: true)
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "frame"]), through: host)
        let value = try Self.value(outcome)
        guard case .image(let bytes, _)? = value.attachment else {
            return XCTFail("A whole frame was dropped because the bracket "
                           + "closed after it was captured.")
        }
        XCTAssertEqual(bytes, png)
        let answer = try Self.answer(value)
        XCTAssertEqual(answer.outcome, .frame)
        XCTAssertEqual(
            answer.stream?.state, .closed,
            "The caller is told the stream is still open, so its next call "
                + "is a refusal it cannot explain.")
    }

    /// The host's own refusal reaches the caller as itself, code and
    /// sentence, rather than being rewritten into a generic failure.
    func testTheHostsBusyRefusalIsPassedThroughNamingWhoHasTheLane()
        async throws {
        let host = StreamHost(
            png: Data(),
            refuseWith: AgentIntegrationStreamFailure.busy(.person))
        let outcome = await StreamScreenProjection.invoke(
            .init(raw: ["intention": "start"]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-stream-busy")
        XCTAssertTrue(
            answer.refused?.message.contains("person") ?? false,
            "A bare \"busy\" sends an agent looking for a fault in a host "
                + "that is working: the commonest holder of this lane is "
                + "somebody watching their own Mac.")
    }

    // MARK: - The row's own declarations

    /// All three messages, required and exposed, which is what closes three
    /// gap rows with one capability.
    func testTheRowRequiresAndExposesTheWholeBracket() {
        let names = AgentIntegrationCapabilityNames.self
        XCTAssertEqual(Set(StreamScreenProjection.requires),
                       [names.streamStart, names.streamStop,
                        names.streamRefresh])
        XCTAssertEqual(Set(StreamScreenProjection.exposes),
                       Set(StreamScreenProjection.requires),
                       "Every one of the three is directed by a caller; "
                           + "none is consumed internally, so this is one "
                           + "of the rows where the two lists are equal.")
        XCTAssertFalse(
            StreamScreenProjection.requires.contains(
                names.captureRequest),
            "Requiring capture.request would tie the bracket to the family "
                + "it is mutually exclusive with on the wire.")
    }

    /// Read-only, and the tier that follows from it.
    ///
    /// Pinned because the temptation on this row is real and specific: a
    /// stream is a longer-lived thing than a capture, and declaring it
    /// non-read-only to buy the Full Access tier would corrupt the
    /// annotation agents read in order to smuggle in a distinction the two
    /// tiers cannot express. Duration is answered by the ownership rule, not
    /// by the tier.
    func testTheRowIsReadOnlyAndSitsAtTheReadOnlyTier() {
        XCTAssertEqual(
            HostCapabilityTierDerivation.hint(
                "readOnlyHint", of: StreamScreenProjection.self), true)
        XCTAssertEqual(
            HostCapabilityTierDerivation.requiredTier(
                of: StreamScreenProjection.self), .readOnly)
    }

    /// The app-UI affordance exists, and the symbol the row names appears
    /// **exactly once** in the file.
    ///
    /// The second half is the point. `HostFaceReach.reached` records as its
    /// fifth rot mode a row naming a symbol its view uses three times, where
    /// deleting the affordance compiles and passes; `toggleStream()` was
    /// introduced so this row would not have that hole, and a check that
    /// only asserted presence would let it grow one back.
    func testTheStreamAffordanceIsNamedByASymbolUsedExactlyOnce() throws {
        let view = try GateSource.hostSwift(
            "now-host/Sources/Host/ScreenshotsModuleView.swift")
        let occurrences = view.components(
            separatedBy: "model.toggleStream()").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "The row's app-UI proof names model.toggleStream(), which the "
                + "view now contains \(occurrences) times. More than one "
                + "and deleting the button proves nothing.")
    }

    // MARK: - Reading a result back

    private static func value(_ outcome: HostProjectionOutcome) throws
        -> HostProjectionValue {
        guard case .value(let value) = outcome else {
            throw Failure.refused(outcome)
        }
        return value
    }

    private static func structured(_ value: HostProjectionValue) throws
        -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try value.encoded(using: encoder),
                      as: UTF8.self)
    }

    private static func answer(_ value: HostProjectionValue) throws
        -> AgentIntegrationStreamAnswer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try decoder.decode(AgentIntegrationStreamAnswer.self,
                                  from: try value.encoded(using: encoder))
    }

    private enum Failure: Error {
        case refused(HostProjectionOutcome)
    }

    private static func bytes(count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 31 + 7) % 251) })
    }
}

/// A host that serves pages of one frame and records what it was asked.
///
/// Like `PagingHost` beside it, it knows nothing about brackets beyond the
/// bookkeeping it was told to do — which is what lets it disagree with the
/// projection about identity, digests and whether the stream is still open.
private actor StreamHost: AgentIntegrationClient {
    struct Opened: Equatable {
        let depth: Int
        let minIntervalMs: Int
    }

    private let png: Data
    private let restageAfterFirstPage: Bool
    private let closeAfterFirstPage: Bool
    private let lieAboutDigest: Bool
    private let refusal: AgentIntegrationProjectionFailure?
    private var frameID = UUID()
    private var open = true
    private(set) var opened: Opened?
    private(set) var stopped = false
    private(set) var pageRequests: [Int] = []

    init(png: Data,
         restageAfterFirstPage: Bool = false,
         closeAfterFirstPage: Bool = false,
         lieAboutDigest: Bool = false,
         refuseWith refusal: AgentIntegrationProjectionFailure? = nil) {
        self.png = png
        self.restageAfterFirstPage = restageAfterFirstPage
        self.closeAfterFirstPage = closeAfterFirstPage
        self.lieAboutDigest = lieAboutDigest
        self.refusal = refusal
    }

    func startGuestStream(depth: Int, minIntervalMs: Int) async
        -> AgentIntegrationStreamResult {
        if let refusal { return .refused(refusal) }
        opened = Opened(depth: depth, minIntervalMs: minIntervalMs)
        return .bracket(bracket(state: .open))
    }

    func stopGuestStream() async -> AgentIntegrationStreamResult {
        if let refusal { return .refused(refusal) }
        stopped = true
        open = false
        return .bracket(bracket(state: .closed))
    }

    func nextGuestStreamFrame() async -> AgentIntegrationStreamResult {
        if let refusal { return .refused(refusal) }
        return frame(at: 0)
    }

    func fetchGuestStreamFramePage(frameID: UUID, offset: Int) async
        -> AgentIntegrationStreamResult {
        pageRequests.append(offset)
        if restageAfterFirstPage { self.frameID = UUID() }
        if closeAfterFirstPage { open = false }
        return frame(at: offset)
    }

    private func frame(at offset: Int) -> AgentIntegrationStreamResult {
        let end = min(offset + AgentIntegrationCapturePolicy.pageBytes,
                      png.count)
        let digest = lieAboutDigest
            ? String(repeating: "0", count: 64)
            : Self.hex(png)
        return .frame(.init(
            bracket: bracket(state: open ? .open : .closed),
            chunk: .init(
                image: .init(
                    captureID: frameID,
                    sessionID: Self.session,
                    capturedAt: Self.moment,
                    width: 640, height: 480, depth: 8,
                    transferMs: 90, wireBytes: png.count,
                    bytes: png.count,
                    sha256: digest),
                page: .init(offset: offset,
                            base64: png[offset..<end]
                                .base64EncodedString()))))
    }

    private func bracket(state: AgentIntegrationStreamBracket.State)
        -> AgentIntegrationStreamBracket {
        .init(streamID: 7,
              sessionID: Self.session,
              state: state,
              origin: .agent,
              openedAt: Self.moment,
              depth: opened?.depth
                  ?? AgentIntegrationCapturePolicy.defaultDepth,
              minIntervalMs: opened?.minIntervalMs
                  ?? AgentIntegrationStreamPolicy.defaultMinIntervalMs)
    }

    private static let session = UUID()
    /// Fixed so an encode/decode round trip cannot drift on sub-second
    /// precision and read as a re-staged frame.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Everything else answers "no host"

    /* The nine requirements that predate the defaulting rule at the top of
       AgentIntegrationClient. A lane this fake has not thought about
       answers "no host" rather than something plausible. */

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}
