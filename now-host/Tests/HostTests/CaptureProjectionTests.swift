import CryptoKit
import Foundation
import XCTest
@testable import NOWAgentIntegration

/// The capture projection's own coverage, pointed at the two things about it
/// that are new to this surface: **it answers with an image**, and **it hides
/// paging**.
///
/// Nothing here constructs a capture and then parses its own construction.
/// The fake host is a page server that knows only the bytes it was given and
/// the offsets it was asked for; every claim below is about what the
/// projection did with those answers, including the ones it should have
/// refused to believe.
final class CaptureProjectionTests: XCTestCase {

    // MARK: - One call, one whole image

    /// Several pages become one attachment, carried once.
    ///
    /// The size is chosen to be a non-multiple of the page so the last page
    /// is short — a loop that assumed full pages would pass a round number
    /// and lose bytes on any real screen.
    func testAMultiPageCaptureArrivesAsOneImageAndOneCopyOfIt() async throws {
        let png = Self.bytes(count:
            AgentIntegrationCapturePolicy.pageBytes * 2 + 977)
        let host = PagingHost(png: png)
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: nil), through: host)

        let value = try Self.value(outcome)
        guard case .image(let bytes, let mimeType)? = value.attachment else {
            return XCTFail("The capture came back with no image attached; a "
                           + "caller would have metadata and no picture.")
        }
        XCTAssertEqual(bytes, png)
        XCTAssertEqual(mimeType, "image/png")
        let pages = await host.pageRequests
        XCTAssertEqual(pages, [
            AgentIntegrationCapturePolicy.pageBytes,
            AgentIntegrationCapturePolicy.pageBytes * 2,
        ], "The projection should ask for exactly the pages it is missing, "
            + "in order, and stop when the declared length is reached.")

        let answer = try Self.answer(value)
        XCTAssertEqual(answer.outcome, .captured)
        XCTAssertEqual(answer.capture?.bytes, png.count)
        /* The bytes are NOT in the structured part. If they ever are, this
           face sends a screen twice: once as structuredContent and once in
           the text block it serialises that into. */
        let json = try Self.structured(value)
        XCTAssertFalse(
            json.contains(png.prefix(64).base64EncodedString()),
            "The image bytes appear in the structured result as well as the "
                + "attachment, so every capture is carried twice.")
    }

    /// The depth a caller did not choose is the policy constant, not
    /// whatever the human's panel happens to be set to.
    func testAnOmittedDepthUsesThePolicyDefaultRatherThanHostState() async {
        let host = PagingHost(png: Self.bytes(count: 32))
        _ = await CaptureScreenProjection.invoke(
            .init(raw: [:]), through: host)
        let depth = await host.requestedDepth
        XCTAssertEqual(depth, AgentIntegrationCapturePolicy.defaultDepth)
    }

    func testADepthTheGuestDoesNotImplementIsRefusedBeforeAnythingIsSent()
        async {
        let host = PagingHost(png: Self.bytes(count: 32))
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: ["depth": 9]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("A 9-bit capture was accepted. It reaches the "
                           + "guest as a Toolbox failure that reads like a "
                           + "broken machine.")
        }
        XCTAssertTrue(message.contains("depth"))
        let depth = await host.requestedDepth
        XCTAssertNil(depth, "The refusal should cost the guest nothing.")
    }

    // MARK: - What it refuses to believe

    /// A stage re-staged underneath the loop is caught, not stitched.
    ///
    /// This is the failure mode with no symptom: two halves of two different
    /// screens make a plausible-looking picture of a moment that never
    /// existed, and only the identity carried on every page can see it.
    func testACaptureRestagedMidFetchIsRefusedRatherThanStitched() async throws {
        let host = PagingHost(
            png: Self.bytes(count:
                AgentIntegrationCapturePolicy.pageBytes * 2),
            restageAfterFirstPage: true)
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-capture-stale")
    }

    /// A digest that does not match the bytes is a refusal, never an image.
    func testAMismatchedDigestIsRefusedWithBothHashes() async throws {
        let host = PagingHost(png: Self.bytes(count: 64),
                              lieAboutDigest: true)
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-capture-digest-mismatch")
    }

    /// The host's own refusal reaches the caller as itself.
    func testTheHostsRefusalIsPassedThroughRatherThanRewritten() async throws {
        let host = PagingHost(png: Data(), refuseWith: .busy)
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: nil), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .refused)
        XCTAssertEqual(answer.refused?.code, "now-capture-busy")
    }

    // MARK: - The abandon half

    func testAbandonReachesTheHostAndTakesNoCapture() async throws {
        let host = PagingHost(png: Self.bytes(count: 64))
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: ["abandon": true]), through: host)
        let answer = try Self.answer(try Self.value(outcome))
        XCTAssertEqual(answer.outcome, .abandoned)
        let abandoned = await host.abandoned
        XCTAssertTrue(abandoned)
        let depth = await host.requestedDepth
        XCTAssertNil(depth, "Abandoning must not also take a capture.")
    }

    /// Two intentions in one call is a refusal rather than a guess: guessing
    /// is how a caller loses a screen it thought it asked for.
    func testAbandonCannotBeCombinedWithADepth() async {
        let host = PagingHost(png: Self.bytes(count: 64))
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: ["abandon": true, "depth": 1]), through: host)
        guard case .invalidArguments = outcome else {
            return XCTFail("abandon and depth were accepted together.")
        }
        let abandoned = await host.abandoned
        XCTAssertFalse(abandoned)
    }

    func testAnUnknownArgumentIsRefusedNamingIt() async {
        let host = PagingHost(png: Self.bytes(count: 64))
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: ["quality": 3]), through: host)
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("An argument this row does not take was accepted.")
        }
        XCTAssertTrue(message.contains("quality"), message)
    }

    // MARK: - The row's own declarations

    /// The app-UI affordance is a real one, and it is the button rather than
    /// the handler behind it. `HostFaceParityTests` checks every row this
    /// way; this asserts the two capture surfaces a person has, because the
    /// menu item is the one that has no pane to be found in.
    /// **It carries `HostFaceReach.reached`'s limits, all of them.** This
    /// is `file.contains(symbol)` with the same reach and the same blind
    /// spots — a control left `.disabled(true)`, a view no longer
    /// instantiated, or the same symbol appearing elsewhere in the file all
    /// keep it green while a person loses the affordance. Read that doc
    /// comment before strengthening this one; the decision not to build a
    /// partial Swift parser was taken there and applies here unchanged.
    /// Comments are stripped, which is the one thing that IS cheap.
    func testBothAppCaptureAffordancesExist() throws {
        let panel = try GateSource.hostSwift(
            "now-host/Sources/Host/ScreenshotsModuleView.swift")
        XCTAssertTrue(panel.contains("model.capture()"))
        let menu = try GateSource.hostSwift(
            "now-host/Sources/Host/QuickCapture.swift")
        XCTAssertTrue(
            menu.contains("screenshots.captureToClipboard"),
            "The menu bar's Screenshot Guest no longer reaches a capture. "
                + "It is the affordance for someone who never opens the "
                + "panel.")
    }

    /// `capture.cancel` is required by nothing here, and that is the
    /// decision: the 68K guest serves `capture.request` and not the cancel,
    /// so requiring it would make a capability both guests serve read as
    /// PowerPC-only.
    func testTheRowRequiresOnlyTheFamilyBothGuestsServe() {
        XCTAssertEqual(CaptureScreenProjection.requires,
                       [AgentIntegrationCapabilityNames.captureRequest])
        XCTAssertEqual(CaptureScreenProjection.exposes,
                       [AgentIntegrationCapabilityNames.captureRequest])
        XCTAssertFalse(
            CaptureScreenProjection.requires.contains("capture.cancel"),
            "Requiring capture.cancel switches this capability off against "
                + "the 68K guest, which captures perfectly well without it.")
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
        -> AgentIntegrationCaptureAnswer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try decoder.decode(AgentIntegrationCaptureAnswer.self,
                                 from: try value.encoded(using: encoder))
    }

    private enum Failure: Error {
        case refused(HostProjectionOutcome)
    }

    /// Deterministic, incompressible-looking filler. It is not a PNG and does
    /// not need to be: this side never decodes it, and a fixture that
    /// pretended to be one would invite a test that checks the wrong half.
    private static func bytes(count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 31 + 7) % 251) })
    }
}

/// A host that serves pages of one PNG and records what it was asked.
///
/// It knows nothing about captures: it hands out slices at the offsets it is
/// given, which is exactly what makes it able to disagree with the projection
/// about them.
private actor PagingHost: AgentIntegrationClient {
    private let png: Data
    private let restageAfterFirstPage: Bool
    private let lieAboutDigest: Bool
    private let refusal: AgentIntegrationCaptureFailure?
    private var captureID = UUID()
    private(set) var requestedDepth: Int?
    private(set) var pageRequests: [Int] = []
    private(set) var abandoned = false

    init(png: Data,
         restageAfterFirstPage: Bool = false,
         lieAboutDigest: Bool = false,
         refuseWith refusal: AgentIntegrationCaptureFailure? = nil) {
        self.png = png
        self.restageAfterFirstPage = restageAfterFirstPage
        self.lieAboutDigest = lieAboutDigest
        self.refusal = refusal
    }

    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        if let refusal { return .refused(refusal) }
        requestedDepth = depth
        return chunk(at: 0)
    }

    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        pageRequests.append(offset)
        if restageAfterFirstPage { self.captureID = UUID() }
        return chunk(at: offset)
    }

    func abandonGuestCapture() async -> AgentIntegrationCaptureResult {
        abandoned = true
        return .abandoned(.cancelled)
    }

    private func chunk(at offset: Int) -> AgentIntegrationCaptureResult {
        let end = min(offset + AgentIntegrationCapturePolicy.pageBytes,
                      png.count)
        let digest = lieAboutDigest
            ? String(repeating: "0", count: 64)
            : Self.hex(png)
        return .captured(.init(
            image: .init(
                captureID: captureID,
                sessionID: Self.session,
                capturedAt: Self.moment,
                width: 640, height: 480, depth: 8,
                transferMs: 770, wireBytes: png.count,
                bytes: png.count,
                sha256: digest),
            page: .init(offset: offset,
                        base64: png[offset..<end].base64EncodedString())))
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
