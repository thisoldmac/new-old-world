import Foundation
import XCTest
@testable import Host
import NOWAgentIntegration

/// The scene seam: the control trio that carries a scene as a transfer,
/// and the decoder that reads the document those bytes are.
///
/// Two properties are load-bearing here and neither is the sort a
/// field-by-field "does it decode" test would catch.
///
/// **Absence.** The guest omits `menus`, `controls`, `text`, `kind`,
/// `display`, `desktopItems` and `items` rather than emitting them empty,
/// and the host must not helpfully fill them in. A test that only checks
/// the fields that ARE emitted passes while a decoder turns every absent
/// key into `[]` and teaches the whole product that a window with an
/// unreported control plane is a window with no controls.
///
/// **Order.** IR-V1.md's consumer duty is *read the version, refuse an
/// unknown major, then decode*. A gate placed after the decode still
/// refuses unknown majors on every well-formed document, so the ordinary
/// test of it is green either way; the only assertion that can tell the
/// two apart is one where the body would fail to parse.
final class SceneWireTests: XCTestCase {

    // MARK: - A document the guest's own encoder produced

    /// Emitted by `src/scene/scene_json.c` compiled natively and run over a
    /// two-process / one-window scene (Finder clean, SimpleText's anchor
    /// ambiguous). Pasted verbatim rather than paraphrased: the point of a
    /// fixture is that the other half wrote it.
    private static let guestScene = """
        {"version":1,"seq":7,"capturedAt":1750000000.0,"source":"peek",\
        "screen":{"w":640,"h":480},\
        "apps":[{"psn":"0.8193","name":"Finder","front":true},\
        {"psn":"0.12289","name":"SimpleText","front":false,\
        "error":"ax_oracle_ambiguous"}],\
        "processes":[{"psn":"0.8193","name":"Finder","front":true,\
        "signature":"MACS"},{"psn":"0.12289","name":"SimpleText",\
        "front":false,"signature":"ttxt"}],\
        "windows":[{"id":"0.8193/Macintosh HD#0","app":"Finder",\
        "psn":"0.8193","title":"Macintosh HD",\
        "rect":{"l":8,"t":40,"r":400,"b":300},"front":true,"z":0,\
        "visible":true}],\
        "meta":{"errors":["SimpleText: ax_oracle_ambiguous"],\
        "plane":"peek anchors: processes + windows, no menus",\
        "latencyMs":12}}
        """

    private func decodeGuestScene(
        irVersion: Int = 1) throws -> NOWSceneDocument {
        try NOWSceneCodec.decode(irVersion: irVersion,
                                 document: Data(Self.guestScene.utf8))
    }

    // MARK: - The document decodes at all

    func testAGuestEncodedSceneDecodes() throws {
        let scene = try decodeGuestScene()

        XCTAssertEqual(scene.version, 1)
        XCTAssertEqual(scene.seq, 7)
        XCTAssertEqual(scene.source, "peek")
        XCTAssertEqual(scene.screen?.w, 640)
        XCTAssertEqual(scene.screen?.h, 480)
        XCTAssertEqual(scene.apps?.count, 2)
        XCTAssertEqual(scene.processes?.count, 2)
        XCTAssertEqual(scene.windows?.count, 1)
        XCTAssertEqual(scene.windows?.first?.rect,
                       NOWSceneRect(l: 8, t: 40, r: 400, b: 300))
        XCTAssertEqual(scene.windows?.first?.title, "Macintosh HD")
        XCTAssertEqual(scene.meta?.plane,
                       "peek anchors: processes + windows, no menus")
    }

    // MARK: - Absence

    /// The keys the producer does not report stay unreported on this side.
    ///
    /// The assertions are ORDERED on purpose: the decode is proven to have
    /// worked before anything is claimed about what it produced. A `nil`
    /// read off a document that never parsed would satisfy every line below
    /// while proving nothing at all.
    func testAbsentPlanesDecodeToNilAndNotToEmpty() throws {
        let scene = try decodeGuestScene()

        // Ordered: the decode produced a real scene first.
        XCTAssertEqual(scene.version, 1)
        let window = try XCTUnwrap(scene.windows?.first)
        XCTAssertEqual(window.id, "0.8193/Macintosh HD#0")

        // ...and only then, what it did NOT say.
        XCTAssertNil(window.controls,
                     "an absent controls key means this producer does not "
                     + "report controls, not that the window has none")
        XCTAssertNil(window.text)
        XCTAssertNil(window.kind)
        XCTAssertNil(window.items)
        XCTAssertNil(scene.menubar)
        XCTAssertNil(scene.desktopItems)
    }

    /// An empty array is a different claim from an absent key, and the
    /// decoder keeps them apart. Without this the test above is satisfied
    /// by a decoder that maps BOTH to nil, which throws away the honest
    /// half of the distinction instead of the dishonest one.
    func testAnEmptyArrayIsNotAbsence() throws {
        let withEmpty = Self.guestScene.replacingOccurrences(
            of: "\"visible\":true}", with: "\"visible\":true,\"controls\":[]}")
        XCTAssertNotEqual(withEmpty, Self.guestScene, "the fixture moved")

        let scene = try NOWSceneCodec.decode(irVersion: 1,
                                             document: Data(withEmpty.utf8))
        XCTAssertEqual(scene.windows?.first?.controls, [],
                       "an emitted empty array is a real claim - the "
                       + "producer looked and found none - and must not "
                       + "decode to nil")
    }

    /// Absence survives a round trip through this side. A decoder can be
    /// faithful and an encoder still invent the key back, at which point
    /// anything the host forwards has quietly acquired a claim the guest
    /// never made.
    func testAbsenceSurvivesTheRoundTrip() throws {
        let scene = try decodeGuestScene()
        XCTAssertEqual(scene.version, 1)          // ordered, as above

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(
            String(data: try encoder.encode(scene), encoding: .utf8))

        for key in ["controls", "menus", "menubar", "text", "kind",
                    "display", "desktopItems", "items", "island"] {
            XCTAssertFalse(json.contains("\"\(key)\""), """
                re-encoding put "\(key)" back into a scene the guest \
                deliberately omitted it from
                """)
        }
        // The check above is only meaningful if the encode produced a
        // scene at all: a "" would contain none of those keys either.
        XCTAssertTrue(json.contains("\"version\":1"))
        XCTAssertTrue(json.contains("\"psn\":\"0.8193\""))
    }

    // MARK: - The oracle's verdicts

    /// Every token the anchor oracle can put in `apps[].error` arrives
    /// here as itself. Flattening any two of them - or dropping one to
    /// `nil` - would turn "we could not tell which anchor was yours" into
    /// "you have no windows", which is the single claim this whole
    /// validated-read path exists to refuse.
    ///
    /// The list is pinned against the guest's own source below, so adding
    /// a verdict without teaching this test about it fails.
    private static let verdictTokens = [
        "ax_oracle_not_found",
        "ax_oracle_ambiguous",
        "ax_oracle_mismatch",
        "ax_oracle_stale",
        "ax_read",
        "now_no_plane",
        "now_not_walked",
        // The catch-all for a verdict this vocabulary has no word for. It
        // was missing from the hand-written list above and the source read
        // below is what found it, on the first run - which is the whole
        // argument for reading the C instead of remembering it.
        "now_unknown_verdict",
    ]

    func testEveryOracleVerdictReachesTheHostAsItsOwnToken() throws {
        var seen: Set<String> = []

        for token in Self.verdictTokens {
            let doc = Self.guestScene.replacingOccurrences(
                of: "ax_oracle_ambiguous", with: token)
            let scene = try NOWSceneCodec.decode(irVersion: 1,
                                                 document: Data(doc.utf8))
            let error = try XCTUnwrap(scene.apps?.last?.error,
                                      "\(token) was dropped on the floor")
            XCTAssertEqual(error, token)
            seen.insert(error)
        }
        XCTAssertEqual(seen.count, Self.verdictTokens.count,
                       "two verdicts collapsed into one token")

        // A clean row carries NO error key. The absence is the claim: the
        // key says something happened and its absence says nothing did.
        let scene = try decodeGuestScene()
        XCTAssertNil(scene.apps?.first?.error)
    }

    /// The tokens above are the tokens the guest can actually write. Read
    /// out of the C rather than remembered, because a verdict added on
    /// that side and not here would otherwise be a silent gap in the test
    /// that exists to prevent silent gaps.
    func testTheVerdictTokensAreTheOnesTheGuestWrites() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // HostTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // now-host
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent(
                "now-guest-ppc/src/scene/scene_build.c")
        let text = GateSource.withoutCComments(
            try String(contentsOf: source, encoding: .utf8))

        var found: Set<String> = []
        for line in text.components(separatedBy: .newlines)
        where line.contains("return \"") {
            let body = line.drop { $0 != "\"" }.dropFirst().prefix { $0 != "\"" }
            if body.hasPrefix("ax_") || body.hasPrefix("now_") {
                found.insert(String(body))
            }
        }
        XCTAssertEqual(found, Set(Self.verdictTokens), """
            the guest's apps[].error vocabulary changed - teach \
            verdictTokens about it so the new verdict is proven to survive \
            the wire rather than assumed to
            """)
    }

    // MARK: - The version gate, and its order

    func testASupportedMajorDecodes() throws {
        XCTAssertNoThrow(try decodeGuestScene(irVersion: 1))
    }

    func testAnUnknownMajorIsRefused() {
        XCTAssertThrowsError(try decodeGuestScene(irVersion: 2)) { error in
            XCTAssertEqual(error as? NOWSceneDecodeError,
                           .unsupportedMajor(2))
        }
        XCTAssertThrowsError(try decodeGuestScene(irVersion: 0))
        XCTAssertThrowsError(try decodeGuestScene(irVersion: 99))
    }

    /// **The ordered assertion.** The body here is not JSON at all, so a
    /// decoder that parses first and gates second reports `.malformed` -
    /// and a decoder that obeys IR-V1.md never looks at it and reports
    /// `.unsupportedMajor`.
    ///
    /// This is the only check in the file that can tell those two
    /// implementations apart. Every other version assertion passes under
    /// both, which is exactly how a gate ends up in the wrong place and
    /// stays there.
    func testTheVersionGateRunsBeforeTheDecode() {
        let garbage = Data("this is not a scene, or JSON".utf8)

        XCTAssertThrowsError(
            try NOWSceneCodec.decode(irVersion: 7, document: garbage)
        ) { error in
            XCTAssertEqual(error as? NOWSceneDecodeError,
                           .unsupportedMajor(7), """
                the major was not refused before the payload was parsed - \
                IR-V1.md's consumer duty is read the version, refuse an \
                unknown major, THEN decode
                """)
        }
        // The same bytes under a SUPPORTED major do reach the parser, which
        // is what proves the assertion above is about ordering and not
        // about the decoder rejecting everything.
        XCTAssertThrowsError(
            try NOWSceneCodec.decode(irVersion: 1, document: garbage)
        ) { error in
            guard case .malformed = error as? NOWSceneDecodeError else {
                return XCTFail("expected a parse failure, got \(error)")
            }
        }
    }

    /// One constant feeds the envelope key and the body stamp on the
    /// guest, so they cannot diverge there. If they ever arrive divergent,
    /// something rewrote one of them in flight and the document does not
    /// get read.
    func testTheEnvelopeAndTheBodyMustAgree() {
        let body = Self.guestScene.replacingOccurrences(
            of: "{\"version\":1", with: "{\"version\":2")

        XCTAssertThrowsError(
            try NOWSceneCodec.decode(irVersion: 1, document: Data(body.utf8))
        ) { error in
            XCTAssertEqual(error as? NOWSceneDecodeError,
                           .versionDisagreement(envelope: 1, body: 2))
        }
    }

    // MARK: - The control trio

    func testTheSceneControlMessagesDecode() throws {
        let begin = """
            {"type":"scene.begin","id":4,"transfer":9,"bytes":9214,\
            "irVersion":1,"seq":7,"capturedAt":1750000000.0,\
            "source":"peek","walkMs":31}
            """
        guard case .sceneBegin(let b) =
                try ControlMessageCodec.decode(Data(begin.utf8)) else {
            return XCTFail("scene.begin did not decode as itself")
        }
        XCTAssertEqual(b.id, 4)
        XCTAssertEqual(b.transfer, 9)
        XCTAssertEqual(b.bytes, 9214)
        XCTAssertEqual(b.irVersion, 1)
        XCTAssertEqual(b.source, "peek")

        let end = """
            {"type":"scene.end","id":4,"transfer":9,"ok":false,\
            "reason":"a transfer is already in flight"}
            """
        guard case .sceneEnd(let e) =
                try ControlMessageCodec.decode(Data(end.utf8)) else {
            return XCTFail("scene.end did not decode as itself")
        }
        XCTAssertEqual(e.ok, false)
        XCTAssertEqual(e.reason, "a transfer is already in flight")
        // No bulk is promised on a refusal, so there is no `bytes` to
        // check - the absence of one is the point.

        let request = """
            {"type":"scene.request","id":4,"staleAfterMs":2000}
            """
        guard case .sceneRequest(let r) =
                try ControlMessageCodec.decode(Data(request.utf8)) else {
            return XCTFail("scene.request did not decode as itself")
        }
        XCTAssertEqual(r.staleAfterMs, 2000)
        XCTAssertNil(r.chunkKb, "an unsent tuning key is not a default of 0")
    }

    /// A scene transfer closes with `scene.end`, and is armed as its own
    /// transfer kind.
    ///
    /// Nothing else in either suite can see this. The end message's type is
    /// COMPUTED from the transfer kind (`xfer_end_type`), so a scene that
    /// ended with `capture.end` would decode perfectly, satisfy the
    /// conformance gate, and correlate against a transfer id the host is
    /// holding a scene for — a mis-typed terminal message that every
    /// existing check waves through.
    ///
    /// It reads text, with the limits that always carries: it proves the
    /// two statements are written, not that they run. What it does catch is
    /// the plausible regression — folding the scene kind back into
    /// capture's branch — which is the one a reviewer would not see either.
    func testASceneTransferEndsWithSceneEnd() throws {
        let wire = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("now-guest-ppc/src/core/wire.c"),
            encoding: .utf8)
        // Comments stripped: a gate that demands text is satisfied by a
        // comment naming it, which this suite has been bitten by four
        // times.
        let text = GateSource.withoutCComments(wire)

        XCTAssertTrue(text.contains("case kXferScene:"),
                      "a scene is not its own transfer kind")
        XCTAssertTrue(text.contains("return \"scene\";"),
                      "a scene transfer does not close with scene.end")
        XCTAssertTrue(text.contains("kXferScene)"),
                      "serve_scene does not arm the transfer as a scene")
    }

    /// `irVersion` is what makes the ordered gate possible at all: the
    /// major has to be readable without the body. A scene.begin that could
    /// omit it would push the version check back behind the transfer,
    /// which is the arrangement the envelope exists to avoid.
    func testSceneBeginCannotOmitTheVersionGate() {
        let noVersion = """
            {"type":"scene.begin","id":4,"transfer":9,"bytes":9214}
            """
        XCTAssertThrowsError(
            try ControlMessageCodec.decode(Data(noVersion.utf8)))
    }
}
