import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// `now_capture_screen` against a REAL screen.
///
///     NOW_METAL=1 NOW_METAL_PORT=5251 NOW_METAL_MACHINE=10.91.5.47 \
///       swift test --package-path now-host \
///       --filter MetalCaptureProjectionTests
///
/// Opt-in; with `NOW_METAL` set it FAILS rather than skips.
///
/// ---- What has never been proven, and is proven here -------------------
///
/// The capture projection was landed with coverage at two layers and no
/// third. `CaptureProjectionTests` drives it against a page server that
/// hands out slices of bytes it was given, and `AgentIntegrationSocketTests`
/// drives the local codec. Both are real tests of real code and neither has
/// ever seen a pixel: the fake page server's "screen" is a counter, its
/// dimensions are the literals 640×480, and its digest is computed over the
/// same bytes the projection is about to check. Every claim about the path
/// as a WHOLE — that a real framebuffer read, decoded by `CaptureDecoder`,
/// re-encoded as PNG, staged, paged out in 8 KiB pages under a 16 KiB local
/// cap, and reassembled — produces one whole legible image whose digest
/// matches, was until this file an inference from two halves.
///
/// So this asks the machine for its screen and then does the one thing no
/// fake can be asked to do: **decodes the result as an image** and checks
/// its pixel dimensions against the numbers the guest reported alongside
/// it. A projection that lost, duplicated or reordered a page produces
/// bytes that are the right length and not a PNG; that is the failure mode
/// with no other symptom.
///
/// ---- The paging is the point, so it is asserted, not assumed -----------
///
/// `pages == ceil(bytes / 8192)` and `pages > 1` are both checked. The
/// second one matters: a screen small enough to arrive in one page would
/// make every claim here true without any paging having happened, and a
/// green run would say nothing about the lane it was written for.
///
/// ---- A capture failure may be a fact about the machine ------------------
///
/// An earlier `vprobe` on this PowerBook reported `CopyBits failed`. If the
/// guest refuses a capture for that reason, that is evidence about this
/// machine's staging path and not a defect in this gate — the failure
/// message below says so, so that nobody arrives at it and starts tuning a
/// test.
@MainActor
final class MetalCaptureProjectionTests: XCTestCase {
    private var surface: MetalAgentLocalSurface!
    private var port: UInt16 = 5251

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against the Mac")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5251
        // Before anything binds: nobody else may hold this port, and nothing
        // else on this Mac may be talking to the machine under test.
        try MetalMachineGuard.preflight(port: port)
        surface = MetalAgentLocalSurface(port: port)
        try surface.start()
    }

    override func tearDown() async throws {
        surface?.stop()
        surface = nil
    }

    // MARK: - The gate

    /// One call, one whole picture of a real screen — at the depth a caller
    /// who names none gets, and at 1 bit, which is the depth that makes this
    /// affordable on classic hardware.
    ///
    /// Both are measured in one test rather than two because they share a
    /// connection and a guest that has just been asked for a screen: two
    /// test methods would each wait out their own dial-in, and the second
    /// would be racing the first's teardown for the machine.
    func testTheProjectionReturnsAWholeImageOfTheRealScreen() async throws {
        let who = try await surface.waitForGuest()
        let verbs = try await surface.requireTheBuildUnderTest()
        let health = surface.listener.health
        print("=== \(who) v\(health?.guestVersion ?? "?") "
              + "(OS \(health?.guestOS ?? "?")) at "
              + "\(surface.listener.guests.map(\.address.text).joined(separator: ", "))"
              + " serving \(verbs.count) verbs ===")
        MetalBaseline.emitMeta(
            guestName: who, version: health?.guestVersion,
            os: health?.guestOS, port: port,
            repeats: MetalBaseline.repeats)

        // 1 bit first: it is the cheapest thing that can prove the whole
        // path, so a machine that cannot capture at all says so before the
        // expensive depth has been asked for.
        try await captureAndVerify(depth: 1)
        try await captureAndVerify(depth: nil)

        print("NOWBASE capture_cap largest_response_bytes="
              + "\(surface.largestResponseBytes) cap_bytes="
              + "\(AgentIntegrationLocalProtocol.maximumMessageBytes) "
              + "responses=\(surface.responsesEncoded)")
        XCTAssertLessThanOrEqual(
            surface.largestResponseBytes,
            AgentIntegrationLocalProtocol.maximumMessageBytes,
            """
            A local response was larger than the cap. The server would not \
            have written it at all — the caller sees a timeout — so this is \
            the paging bound failing, not a slow machine.
            """)
    }

    /// Abandoning when there is nothing in flight is answered as that fact,
    /// over the real socket and against the real machine.
    ///
    /// It is here rather than in a unit test because the lane it releases is
    /// the guest's single transfer lane: the answer depends on live listener
    /// state (`isCapturePending`), and the only place that state is real is
    /// in front of a real connection.
    func testAbandonWithNothingInFlightSaysSoRatherThanTakingAPicture()
        async throws {
        try await surface.waitForGuest()
        try await surface.requireTheBuildUnderTest()

        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: ["abandon": true]),
            through: try surface.projectionClient())
        let answer = try Self.answer(try Self.value(outcome))

        XCTAssertEqual(answer.outcome, .abandoned)
        XCTAssertEqual(answer.abandoned?.code, "now-capture-nothing-in-flight",
                       "abandoned: \(answer.abandoned?.message ?? "-")")
        XCTAssertFalse(surface.listener.isCapturePending,
                       "the abandon left a capture pending on the machine")
    }

    // MARK: - One capture, measured

    private func captureAndVerify(depth: Int?) async throws {
        let asked = depth.map(String.init) ?? "default"
        let arguments: [String: Any] = depth.map { ["depth": $0] } ?? [:]
        let started = Date()
        let outcome = await CaptureScreenProjection.invoke(
            .init(raw: arguments), through: try surface.projectionClient())
        let seconds = Date().timeIntervalSince(started)

        let value = try Self.value(outcome)
        let answer = try Self.answer(value)
        guard answer.outcome == .captured, let image = answer.capture else {
            /* Three different types carry the same two fields, so the reason
               is read out rather than coalesced — a refusal from the guest
               and an unavailable host are different facts. */
            let failure: (code: String, message: String)? =
                answer.refused.map { ($0.code, $0.message) }
                ?? answer.unavailable.map { ($0.code, $0.message) }
                ?? answer.abandoned.map { ($0.code, $0.message) }
            let message = failure.map { "[\($0.code)] \($0.message)" }
                ?? "no failure reported"
            MetalBaseline.emitRung(
                direction: "capture", label: "depth-\(asked)", bytes: 0,
                seconds: seconds, rep: 1, of: 1,
                result: "refused:\(failure?.code ?? "unknown")")
            /* Which half failed is the first question, and the code answers
               it: the two integrity refusals are produced by this side while
               reassembling, and everything else came back from the machine.
               Saying "the machine would not" over a digest mismatch would
               send somebody to the PowerBook to look for a fault on this
               Mac — watched, during this gate's own mutation check. */
            let lane = ["now-capture-digest-mismatch", "now-capture-stale"]
                .contains(failure?.code ?? "")
            return XCTFail(lane
                ? """
                    The capture came back and did not survive reassembly at \
                    depth \(asked): \(message). This is the PAGING lane, not \
                    the machine — a lost, duplicated, reordered or corrupted \
                    page produces exactly this, and the guest's own transfer \
                    had already finished.
                    """
                : """
                    The machine would not hand over its screen at depth \
                    \(asked): \(message).

                    If that reads `CopyBits failed` or names the guest's \
                    staging path, it is a FINDING ABOUT THIS MACHINE and not \
                    a defect in this gate — an earlier vprobe on this \
                    PowerBook reported exactly that. Record it; do not tune \
                    this test until it passes.
                    """)
        }

        guard case .image(let png, let mimeType)? = value.attachment else {
            return XCTFail("""
                The capture came back with its measurements and no picture, \
                so a caller would have \(image.bytes) bytes of metadata \
                about an image it cannot see.
                """)
        }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(png.count, image.bytes,
                       "the reassembled PNG is not the declared length")

        // The digest is checked INSIDE the projection; recomputing it here
        // is not a duplicate of that check but the only way to know the
        // check was against these bytes rather than a value that travelled
        // with them.
        let digest = SHA256.hash(data: png)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, image.sha256,
                       "the host's declared digest is not this picture's")

        // The claim no fake can make: these bytes are an image, and it is
        // the size the guest said its screen was.
        let (width, height) = try Self.pixelSize(png)
        XCTAssertEqual(width, image.width,
                       "the PNG is \(width) px wide; the guest reported "
                           + "\(image.width)")
        XCTAssertEqual(height, image.height,
                       "the PNG is \(height) px tall; the guest reported "
                           + "\(image.height)")
        XCTAssertGreaterThanOrEqual(
            width, 512,
            "a real classic Mac screen is at least 512 px wide; \(width) is "
                + "not a screen")
        XCTAssertGreaterThanOrEqual(height, 342)

        let pages = (image.bytes + AgentIntegrationCapturePolicy.pageBytes - 1)
            / AgentIntegrationCapturePolicy.pageBytes
        XCTAssertGreaterThan(pages, 1, """
            This screen fitted in one page, so nothing above proves the \
            paging lane works. Ask for a deeper capture — the whole reason \
            this projection exists is that no screenshot fits in one 16 KiB \
            local response.
            """)

        MetalBaseline.emitRung(
            direction: "capture", label: "depth-\(asked)",
            bytes: image.bytes, seconds: seconds, rep: 1, of: 1,
            result: "ok",
            extra: [
                ("asked_depth", asked),
                ("got_depth", String(image.depth)),
                ("px", "\(image.width)x\(image.height)"),
                ("wire_bytes", String(image.wireBytes)),
                ("guest_ms", String(image.transferMs)),
                ("pages", String(pages)),
                ("sha256_12", String(image.sha256.prefix(12))),
            ])
        print("=== depth \(asked): \(image.width)x\(image.height) at "
              + "\(image.depth)bpp, \(image.bytes) B of PNG in \(pages) "
              + "pages, \(image.wireBytes) B on the wire, guest "
              + "\(image.transferMs) ms, whole call "
              + String(format: "%.1f", seconds) + "s ===")
    }

    // MARK: - Reading a result back

    /// The image's own pixel dimensions, from the encoded bytes.
    ///
    /// ImageIO rather than a PNG header read by hand: the point is that a
    /// decoder accepts these bytes, and a hand-rolled reader of the IHDR
    /// would happily report a size for a file whose later chunks are
    /// scrambled.
    private static func pixelSize(_ png: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Failure.notAnImage(png.count)
        }
        return (image.width, image.height)
    }

    private static func value(_ outcome: HostProjectionOutcome) throws
        -> HostProjectionValue {
        guard case .value(let value) = outcome else {
            throw Failure.refused(String(describing: outcome))
        }
        return value
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

    private enum Failure: Error, CustomStringConvertible {
        case refused(String)
        case notAnImage(Int)

        var description: String {
            switch self {
            case .refused(let outcome):
                return "the projection refused the call: \(outcome)"
            case .notAnImage(let bytes):
                return """
                    \(bytes) bytes came back and no decoder on this Mac will \
                    read them as an image. The length can be right while the \
                    content is not: a lost, duplicated or reordered page \
                    produces exactly this.
                    """
            }
        }
    }
}
