import CryptoKit
import Foundation
import XCTest
@testable import NOWAgentIntegration

/// The scene projection's own coverage, pointed at what is new about it
/// relative to `CaptureScreenProjection`: **it answers with JSON text rather
/// than an image**, and **it has no abandon**.
///
/// Nothing here constructs a scene and then parses its own construction. The
/// fake host is a page server that knows only the bytes it was given and the
/// offsets it was asked for; every claim below is about what the projection
/// did with those answers, including the ones it should have refused to
/// believe.
final class SceneProjectionTests: XCTestCase {

    // MARK: - One call, one whole document

    /// Several pages become one document, carried once.
    ///
    /// The size is chosen to be a non-multiple of the page so the last page
    /// is short — a loop that assumed full pages would pass a round number
    /// and lose bytes on any real scene.
    func testAMultiPageSceneArrivesAsOneDocument() async throws {
        let document = Self.json(count:
            AgentIntegrationScenePolicy.pageBytes * 2 + 611)
        let host = PagingHost(document: document)
        let outcome = await SceneProjection.invoke(
            .init(raw: nil), through: host)

        let value = try Self.value(outcome)
        let answer = try Self.answer(value)
        XCTAssertEqual(answer.outcome, .captured)
        XCTAssertEqual(answer.document, String(decoding: document,
                                                as: UTF8.self))
        XCTAssertEqual(answer.scene?.bytes, document.count)

        let pages = await host.pageRequests
        XCTAssertEqual(pages, [
            AgentIntegrationScenePolicy.pageBytes,
            AgentIntegrationScenePolicy.pageBytes * 2,
        ], "The projection should ask for exactly the pages it is missing, "
            + "in order, and stop when the declared length is reached.")
    }

    /// The staleness gate a caller did not name is absent on the wire, not
    /// zero — the contract's own "0 or absent" both mean no age gate, and
    /// this side must not manufacture a value where the caller left none.
    func testAnOmittedStaleAfterMsIsNotInventedAsZero() async {
        let host = PagingHost(document: Self.json(count: 32))
        _ = await SceneProjection.invoke(.init(raw: [:]), through: host)
        let staleAfterMs = await host.requestedStaleAfterMs
        XCTAssertNil(staleAfterMs, "An omitted staleAfterMs should reach the "
            + "guest as absent, exactly what the caller sent.")
    }

    func testAStaleAfterMsIsForwardedToTheHost() async {
        let host = PagingHost(document: Self.json(count: 32))
        _ = await SceneProjection.invoke(
            .init(raw: ["staleAfterMs": 5000]), through: host)
        let staleAfterMs = await host.requestedStaleAfterMs
        XCTAssertEqual(staleAfterMs, 5000)
    }

    func testANegativeStaleAfterMsIsRefusedBeforeAnythingIsSent() async {
        let host = PagingHost(document: Self.json(count: 32))
        let outcome = await SceneProjection.invoke(
            .init(raw: ["staleAfterMs": -1]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("A negative staleAfterMs was accepted.")
        }
        XCTAssertTrue(message.contains("staleAfterMs"))
        let staleAfterMs = await host.requestedStaleAfterMs
        XCTAssertNil(staleAfterMs, "The refusal should cost the guest "
            + "nothing.")
    }

    // MARK: - What it refuses to believe

    /// A stage re-staged underneath the loop is caught, not stitched.
    func testASceneRestagedMidFetchIsRefusedRatherThanStitched() async throws {
        let host = PagingHost(
            document: Self.json(count:
                AgentIntegrationScenePolicy.pageBytes * 2),
            restageAfterFirstPage: true)
        let outcome = await SceneProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-scene-stale")
    }

    /// A digest that does not match the bytes is a refusal, never a
    /// document.
    func testAMismatchedDigestIsRefusedWithBothHashes() async throws {
        let host = PagingHost(document: Self.json(count: 64),
                              lieAboutDigest: true)
        let outcome = await SceneProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-scene-digest-mismatch")
    }

    /// The host's own refusal reaches the caller as itself.
    func testTheHostsRefusalIsPassedThroughRatherThanRewritten() async throws {
        let host = PagingHost(document: Data(),
                              refuseWith: .init(
                                code: "now-scene-failed",
                                message: "a stream is already running"))
        let outcome = await SceneProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-scene-failed")
    }

    /// The IR major gate is the host's, and this row does not repeat or
    /// second-guess it: an unsupported major reaches the caller as the
    /// host's own refusal.
    func testAnUnsupportedMajorArrivesAsARefusal() async throws {
        let host = PagingHost(
            document: Self.json(count: 32),
            refuseWith: .unsupportedMajor(99))
        let outcome = await SceneProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-scene-unsupported-major")
    }

    // MARK: - There is no abandon

    /// `abandon` is not one of this row's arguments — unlike capture, and
    /// the contract's own reason: a scene transfer is short enough that
    /// cancelling it costs more than finishing it.
    func testAbandonIsNotAnArgumentThisRowTakes() async {
        let host = PagingHost(document: Self.json(count: 64))
        let outcome = await SceneProjection.invoke(
            .init(raw: ["abandon": true]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An unknown argument (abandon) was accepted.")
        }
        XCTAssertTrue(message.contains("abandon"))
    }

    func testAnUnknownArgumentIsRefusedNamingIt() async {
        let host = PagingHost(document: Self.json(count: 64))
        let outcome = await SceneProjection.invoke(
            .init(raw: ["depth": 8]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An argument this row does not take was "
                           + "accepted.")
        }
        XCTAssertTrue(message.contains("depth"), message)
    }

    // MARK: - The row's own declarations

    /// The app-UI affordance is a real one — the Mirror page's own Start
    /// Mirror button, whose press asks for a scene before the loop's first
    /// tick. `HostFaceParityTests` checks every row this way; this is the
    /// same check, aimed at the one file that matters for this row.
    ///
    /// **The literal is spelled here rather than read off the row, on
    /// purpose**, and it costs an edit in two places when the affordance
    /// moves — as it did on 2026-08-01, when the page's Fetch button became
    /// Start / Stop (27de200) and `model.fetchScene` left this file. A test
    /// that asked the row what to look for would agree with the row about a
    /// button that is not there, which is the "one half twice" mistake
    /// AGENTS.md names.
    func testTheAppUIAffordanceExists() throws {
        let panel = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorModuleView.swift")
        XCTAssertTrue(
            panel.contains("model.startSession"),
            "The Mirror page no longer spells the affordance that reaches "
                + "now_scene. Either it moved and SceneProjection's .appUI "
                + "row follows it here, or the page lost it and the row "
                + "declares a divergence.")
    }

    /// There is no `scene.cancel` to require or fold in beside
    /// `scene.request`, and the row's requirement set says so by omission —
    /// checked here rather than left to be noticed.
    func testTheRowRequiresOnlyTheOneMessageTheContractDeclares() {
        XCTAssertEqual(SceneProjection.requires,
                       [AgentIntegrationCapabilityNames.sceneRequest])
        XCTAssertEqual(SceneProjection.exposes,
                       [AgentIntegrationCapabilityNames.sceneRequest])
    }

    // MARK: - Reading a result back

    private static func value(_ outcome: HostProjectionOutcome) throws
        -> HostProjectionValue {
        guard case .value(let value) = outcome else {
            throw Failure.refused(outcome)
        }
        return value
    }

    private static func answer(_ value: HostProjectionValue) throws
        -> AgentIntegrationSceneAnswer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try decoder.decode(AgentIntegrationSceneAnswer.self,
                                 from: try value.encoded(using: encoder))
    }

    private enum Failure: Error {
        case refused(HostProjectionOutcome)
    }

    /// Deterministic filler that is valid enough to stand in for a
    /// document: this side never decodes it, so it does not need to be real
    /// scene JSON, only bytes with no run of zeroes that would look like an
    /// empty page.
    private static func json(count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 37 + 11) % 251) })
    }
}

/// A host that serves pages of one scene document and records what it was
/// asked.
///
/// It knows nothing about scenes: it hands out slices at the offsets it is
/// given, which is exactly what makes it able to disagree with the
/// projection about them.
private actor PagingHost: AgentIntegrationClient {
    private let document: Data
    private let restageAfterFirstPage: Bool
    private let lieAboutDigest: Bool
    private let refusal: AgentIntegrationSceneFailure?
    private var sceneID = UUID()
    private(set) var requestedStaleAfterMs: Int?
    private(set) var pageRequests: [Int] = []

    init(document: Data,
         restageAfterFirstPage: Bool = false,
         lieAboutDigest: Bool = false,
         refuseWith refusal: AgentIntegrationSceneFailure? = nil) {
        self.document = document
        self.restageAfterFirstPage = restageAfterFirstPage
        self.lieAboutDigest = lieAboutDigest
        self.refusal = refusal
    }

    func requestGuestScene(staleAfterMs: Int?) async
        -> AgentIntegrationSceneResult {
        if let refusal { return .refused(refusal) }
        requestedStaleAfterMs = staleAfterMs
        return chunk(at: 0)
    }

    func fetchGuestScenePage(sceneID: UUID, offset: Int) async
        -> AgentIntegrationSceneResult {
        pageRequests.append(offset)
        if restageAfterFirstPage { self.sceneID = UUID() }
        return chunk(at: offset)
    }

    private func chunk(at offset: Int) -> AgentIntegrationSceneResult {
        let end = min(offset + AgentIntegrationScenePolicy.pageBytes,
                      document.count)
        let digest = lieAboutDigest
            ? String(repeating: "0", count: 64)
            : Self.hex(document)
        return .captured(.init(
            facts: .init(
                sceneID: sceneID,
                sessionID: Self.session,
                observedAt: Self.moment,
                irVersion: 1,
                seq: 3,
                source: "peek",
                walkMs: 12,
                transferMs: 40,
                bytes: document.count,
                sha256: digest),
            page: .init(offset: offset,
                        base64: document[offset..<end]
                            .base64EncodedString())))
    }

    private static let session = UUID()
    /// Fixed so an encode/decode round trip cannot drift on sub-second
    /// precision and read as a mismatched stage.
    private static let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Everything else answers "no host"

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
