import XCTest
@testable import Host

/// The host's half of scene deltas.
///
/// The property under test is not "a delta decodes". It is that applying
/// one produces **the same bytes the guest would have sent whole**, and
/// that when it does not, this side notices and publishes nothing. Both
/// halves are here, and the second matters more: a delta stream that
/// drifts from truth is the worst failure this product can have, because
/// its entire claim is a faithful mirror.
///
/// The fixtures are written the way the guest encodes — no spaces, the
/// guest's field order — because the digest is over bytes and a fixture
/// that was merely equivalent would test a scheme nobody ships.
final class MirrorSceneDeltaTests: XCTestCase {

    // MARK: - Fixtures

    private func window(_ incarnation: String, title: String, left: Int) -> String {
        "{\"id\":\"0.1/\(title)#0\",\"app\":\"Finder\",\"psn\":\"0.1\","
            + "\"title\":\"\(title)\",\"rect\":{\"l\":\(left),\"t\":4,\"r\":300,\"b\":420},"
            + "\"front\":false,\"z\":0,\"visible\":true,"
            + "\"incarnation\":\"\(incarnation)\"}"
    }

    private func whole(seq: Int, at: Double, left: Int = 20,
                       windows: [String]? = nil) -> Data {
        let ws = windows ?? [
            window("process-1a2b3c4d/window-0034ab10", title: "Macintosh HD", left: left),
            window("process-1a2b3c4d/window-00120040", title: "Lab", left: 60),
        ]
        let doc = "{\"version\":2,\"seq\":\(seq),\"capturedAt\":\(String(format: "%.1f", at)),"
            + "\"source\":\"peek\",\"screen\":{\"w\":640,\"h\":480},"
            + "\"apps\":[{\"psn\":\"0.1\",\"name\":\"Finder\",\"front\":true,"
            + "\"incarnation\":\"process-1a2b3c4d\"}],"
            + "\"processes\":[{\"psn\":\"0.1\",\"name\":\"Finder\",\"front\":true,"
            + "\"signature\":\"MACS\",\"incarnation\":\"process-1a2b3c4d\"}],"
            + "\"menubar\":{\"app\":\"Finder\",\"menus\":[]},"
            + "\"windows\":[\(ws.joined(separator: ","))],"
            + "\"meta\":{\"errors\":[],\"coverage\":[{\"scope\":\"processes\","
            + "\"status\":\"complete\"}],\"latencyMs\":4}}"
        return Data(doc.utf8)
    }

    /// A delta the guest would have produced for "one window moved":
    /// the moved window carried whole, the other named and not sent.
    private func delta(baseline: String, seq: Int, at: Double,
                       movedLeft: Int) -> Data {
        let moved = window("process-1a2b3c4d/window-0034ab10",
                           title: "Macintosh HD", left: movedLeft)
        let doc = "{\"version\":2,\"kind\":\"delta\",\"seq\":\(seq),"
            + "\"baseline\":\"\(baseline)\","
            + "\"capturedAt\":\(String(format: "%.1f", at)),"
            + "\"source\":\"peek\",\"screen\":{\"w\":640,\"h\":480},"
            + "\"apps\":[{\"k\":\"process-1a2b3c4d\"}],"
            + "\"processes\":[{\"k\":\"process-1a2b3c4d\"}],"
            + "\"menubar\":{\"same\":true},"
            + "\"windows\":[{\"k\":\"process-1a2b3c4d/window-0034ab10\",\"v\":\(moved)},"
            + "{\"k\":\"process-1a2b3c4d/window-00120040\"}],"
            + "\"meta\":{\"errors\":[],\"coverage\":[{\"scope\":\"processes\","
            + "\"status\":\"complete\"}],\"latencyMs\":4}}"
        return Data(doc.utf8)
    }

    // MARK: -

    func testTheDigestIgnoresTheMomentButNotTheMachine() throws {
        let a = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let b = try MirrorSceneDelta.slice(whole: whole(seq: 2, at: 1077.0))
        XCTAssertNotEqual(whole(seq: 1, at: 1000.0), whole(seq: 2, at: 1077.0),
                          "two walks of one machine differ as documents")
        XCTAssertEqual(a.digest, b.digest,
                       "and hash the same, or 'nothing changed' can never be said")

        let moved = try MirrorSceneDelta.slice(whole: whole(seq: 3, at: 1090.0,
                                                            left: 21))
        XCTAssertNotEqual(a.digest, moved.digest,
                          "a window that moved one pixel changes the digest")
    }

    func testApplyingADeltaRebuildsTheWholeDocumentByteForByte() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let expectedWhole = whole(seq: 2, at: 1030.0, left: 21)
        let expectedDigest =
            try MirrorSceneDelta.slice(whole: expectedWhole).digest

        let applied = try MirrorSceneDelta.apply(
            delta: delta(baseline: base.digest, seq: 2, at: 1030.0,
                         movedLeft: 21),
            to: base, askedBaseline: base.digest, expected: expectedDigest)

        XCTAssertEqual(String(decoding: applied.document, as: UTF8.self),
                       String(decoding: expectedWhole, as: UTF8.self),
                       "the rebuild is the document the guest would have sent, "
                           + "byte for byte — which is the whole resync guarantee")
        XCTAssertEqual(applied.baseline.digest, expectedDigest)
    }

    func testAWrongDigestIsRefusedRatherThanPublished() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        XCTAssertThrowsError(
            try MirrorSceneDelta.apply(
                delta: delta(baseline: base.digest, seq: 2, at: 1030.0,
                             movedLeft: 21),
                to: base, askedBaseline: base.digest, expected: "deadbeef")
        ) { error in
            guard case MirrorSceneDelta.Failure.digestMismatch = error else {
                return XCTFail("expected a digest mismatch, got \(error)")
            }
        }
    }

    /// The detection claim, exercised rather than asserted: corrupt the
    /// baseline the way a mis-applied earlier delta would have, and the
    /// digest catches it even though every structural check passes.
    func testDriftInTheBASELINEIsCaughtByTheDigestAlone() throws {
        var base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let expectedDigest = try MirrorSceneDelta.slice(
            whole: whole(seq: 2, at: 1030.0, left: 21)).digest

        // The window this delta does NOT carry is wrong on our side. Every
        // key still resolves; nothing about the delta is malformed.
        base.windows[1].bytes = Array(
            window("process-1a2b3c4d/window-00120040", title: "Lab", left: 61)
                .utf8)

        XCTAssertThrowsError(
            try MirrorSceneDelta.apply(
                delta: delta(baseline: base.digest, seq: 2, at: 1030.0,
                             movedLeft: 21),
                to: base, askedBaseline: base.digest, expected: expectedDigest)
        ) { error in
            guard case MirrorSceneDelta.Failure.digestMismatch = error else {
                return XCTFail("a corrupted baseline must be caught: \(error)")
            }
        }
    }

    func testAReusedKeyWeDoNotHoldIsCaughtBeforeAnyHashing() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let bad = Data(String(decoding: delta(baseline: base.digest, seq: 2,
                                              at: 1030.0, movedLeft: 21),
                              as: UTF8.self)
            .replacingOccurrences(of: "window-00120040", with: "window-cafef00d")
            .utf8)
        XCTAssertThrowsError(
            try MirrorSceneDelta.apply(delta: bad, to: base,
                                       askedBaseline: base.digest,
                                       expected: nil)
        ) { error in
            guard case MirrorSceneDelta.Failure.unknownKey = error else {
                return XCTFail("expected an unknown key, got \(error)")
            }
        }
    }

    func testADeltaAboutAnotherBaselineIsRefused() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        XCTAssertThrowsError(
            try MirrorSceneDelta.apply(
                delta: delta(baseline: "0badc0de", seq: 2, at: 1030.0,
                             movedLeft: 21),
                to: base, askedBaseline: base.digest, expected: nil)
        ) { error in
            guard case MirrorSceneDelta.Failure.baselineMismatch = error else {
                return XCTFail("expected a baseline mismatch, got \(error)")
            }
        }
    }

    func testADeltaWithNoBaselineHeldIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(
            try MirrorSceneDelta.apply(delta: delta(baseline: "00000000",
                                                    seq: 2, at: 1030.0,
                                                    movedLeft: 21),
                                       to: nil, askedBaseline: "00000000",
                                       expected: nil)
        ) { error in
            guard case MirrorSceneDelta.Failure.noBaseline = error else {
                return XCTFail("expected noBaseline, got \(error)")
            }
        }
    }

    /// A window that left is an absence from the ordered array, and the
    /// rebuild simply does not contain it. The DELETION is then decided by
    /// `meta.coverage` in the reducer, exactly as it is for a whole scene —
    /// which is why a delta is not a second way to remove state.
    func testAWindowThatLeftIsAnAbsenceAndNothingMore() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let shrunk = "{\"version\":2,\"kind\":\"delta\",\"seq\":2,"
            + "\"baseline\":\"\(base.digest)\",\"capturedAt\":1030.0,"
            + "\"source\":\"peek\",\"screen\":{\"w\":640,\"h\":480},"
            + "\"apps\":[{\"k\":\"process-1a2b3c4d\"}],"
            + "\"processes\":[{\"k\":\"process-1a2b3c4d\"}],"
            + "\"menubar\":{\"same\":true},"
            + "\"windows\":[{\"k\":\"process-1a2b3c4d/window-0034ab10\"}],"
            + "\"meta\":{\"errors\":[],\"coverage\":[{\"scope\":\"processes\","
            + "\"status\":\"complete\"}],\"latencyMs\":4}}"
        let applied = try MirrorSceneDelta.apply(
            delta: Data(shrunk.utf8), to: base, askedBaseline: base.digest,
            expected: nil)
        let text = String(decoding: applied.document, as: UTF8.self)
        XCTAssertFalse(text.contains("window-00120040"),
                       "the departed window is absent from the rebuild")
        XCTAssertTrue(text.contains("window-0034ab10"))
        XCTAssertTrue(text.contains("\"coverage\":[{\"scope\":\"processes\""),
                      "and coverage — the only thing that may authorise the "
                          + "deletion this absence implies — is restated whole")
    }

    func testRepublishingABaselineIsTheSameSceneAtANewMoment() throws {
        let base = try MirrorSceneDelta.slice(whole: whole(seq: 1, at: 1000.0))
        let again = MirrorSceneDelta.republish(base, seq: 9, capturedAt: 1234.5)
        XCTAssertEqual(String(decoding: again, as: UTF8.self),
                       String(decoding: whole(seq: 9, at: 1234.5), as: UTF8.self),
                       "a scene.same republishes the baseline verbatim, with "
                           + "only the moment moved")
        XCTAssertEqual(try MirrorSceneDelta.slice(whole: again).digest,
                       base.digest,
                       "and the digest is unmoved, because the moment is not in it")
    }

    /// **THE TWO-HALVES TEST.** Every other case here parses documents
    /// this file wrote, which tests one half twice. These three fixtures
    /// were emitted by the GUEST'S OWN ENCODER (scene_json.c and
    /// scene_digest.c, compiled and run by
    /// now-host/Tests/HostTests/Fixtures/README-scene-delta.md's recipe):
    /// a whole scene, the whole scene the guest would send next, and the
    /// delta it sends instead.
    ///
    /// Applying the guest's delta to the guest's baseline must produce the
    /// guest's next whole document, byte for byte. If that ever stops
    /// being true the two halves have drifted — which is the defect class
    /// this repository calls two-halves-never-met-in-a-test.
    func testTheGuestsOwnDeltaRebuildsTheGuestsOwnNextScene() throws {
        func fixture(_ name: String) throws -> Data {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: "json",
                                  subdirectory: "Fixtures"),
                "\(name).json is missing from the test bundle")
            return try Data(contentsOf: url)
        }
        let baselineDoc = try fixture("scene-delta-baseline")
        let nextWhole = try fixture("scene-delta-next-whole")
        let guestDelta = try fixture("scene-delta-next-delta")

        let base = try MirrorSceneDelta.slice(whole: baselineDoc)
        let expected = try MirrorSceneDelta.slice(whole: nextWhole)
        XCTAssertLessThan(guestDelta.count, nextWhole.count,
                          "the guest only sends a delta when it is smaller")

        let applied = try MirrorSceneDelta.apply(
            delta: guestDelta, to: base, askedBaseline: base.digest,
            expected: expected.digest)
        XCTAssertEqual(String(decoding: applied.document, as: UTF8.self),
                       String(decoding: nextWhole, as: UTF8.self),
                       "the guest's delta rebuilds the guest's own next scene")
        XCTAssertEqual(applied.baseline.digest, expected.digest,
                       "and both halves compute the same FNV-1a body digest "
                           + "over the same bytes")
        /* And it is a SCENE, not merely equal bytes: the rebuild goes
           through the same decoder a whole document does, because that is
           the only path anything above this layer has. */
        let scene = try NOWMirrorSceneDecoder.decode(irVersion: 2,
                                                     document: applied.document)
        XCTAssertEqual(scene.windows.count, 3)
        XCTAssertEqual(scene.windows.first(where: {
            $0.incarnation == "process-1a2b3c4d/window-0034ab10"
        })?.rect.l, 21, "the window that moved arrived at its new place")
    }

    /// The producer/consumer join. A real captured scene must be sliceable
    /// and its digest stable, or the whole plane is a scheme that works on
    /// documents this test wrote and nothing the guest emits.
    func testARealCapturedSceneCanBecomeABaseline() throws {
        let url = Bundle.module.url(forResource: "now-scene-self-front-visible",
                                    withExtension: "json",
                                    subdirectory: "Fixtures")
        guard let url, let data = try? Data(contentsOf: url) else {
            throw XCTSkip("the real-scene fixture is not present")
        }
        let base = try MirrorSceneDelta.slice(whole: data)
        XCTAssertEqual(base.digest.count, 8)
        XCTAssertEqual(base.digest, MirrorSceneDelta.digest(of: base),
                       "slicing is deterministic")
        XCTAssertFalse(base.windows.isEmpty,
                       "a real scene has windows, and each is keyed")
        for w in base.windows {
            XCTAssertTrue(w.key.contains("/window-"),
                          "a window's key is its incarnation: \(w.key)")
        }
    }
}
