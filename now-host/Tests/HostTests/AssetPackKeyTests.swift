import XCTest
@testable import Host

/// The asset-pack key: which machine's art belongs to this guest.
///
/// The whole point of the key is that it COLLIDES — two Macs of the same
/// model running the same System share it, because a pack extracted from
/// one is the right pack for the other. Most of what is asserted here is
/// therefore the opposite of what an identity type's tests assert, and
/// that is deliberate rather than sloppy.
final class AssetPackKeyTests: XCTestCase {

    private func key(id: Int? = nil, model: String? = nil,
                     os: String? = nil) -> AssetPackKey {
        AssetPackKey(machineID: id, machineModel: model, systemVersion: os)
    }

    // MARK: - it is meant to collide

    /// Two different PowerBook 1400cs on the same System are ONE key.
    ///
    /// Gestalt carries no serial number, so this is not a limitation
    /// being tolerated — it is the property that makes a pack shareable
    /// at all. A key that told these apart would give every machine its
    /// own pack and make "someone in the community makes a comprehensive
    /// pack" impossible.
    func testTwoMacsOfOneModelAndSystemShareAKey() {
        let a = key(id: 406, model: "PowerBook 1400cs/117", os: "9.1.0")
        let b = key(id: 406, model: "PowerBook 1400cs/117", os: "9.1.0")
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertEqual(a, b)
    }

    /// The same machine after a System upgrade is a DIFFERENT key,
    /// because its System Folder's art is different. This is the half the
    /// old hardcoded `hello.os` could never have noticed.
    func testASystemUpgradeChangesTheKey() {
        let before = key(id: 406, model: "PowerBook 1400cs/117", os: "8.6.0")
        let after = key(id: 406, model: "PowerBook 1400cs/117", os: "9.1.0")
        XCTAssertNotEqual(before.identity, after.identity)
    }

    func testADifferentModelIsADifferentKey() {
        XCTAssertNotEqual(key(id: 406, os: "9.1.0").identity,
                          key(id: 34, os: "9.1.0").identity)
    }

    // MARK: - the id leads, the model follows

    /// A localised or renamed model must not change the key when the
    /// machine type is known. The number is the same on every System;
    /// the name is not, and on this project it can fall back to a
    /// Sharing name a person edits.
    func testTheModelNameDoesNotMoveAKeyThatHasAnID() {
        let english = key(id: 406, model: "PowerBook 1400cs/117", os: "9.1.0")
        let renamed = key(id: 406, model: "Michelle's PowerBook", os: "9.1.0")
        XCTAssertEqual(english.identity, renamed.identity,
                       "the machine type decides; the name is for reading")
    }

    /// Where the id is absent — or 0, which is the guest saying it could
    /// not establish it — the model carries the key rather than the whole
    /// thing collapsing to unknown.
    func testTheModelCarriesTheKeyWhenThereIsNoID() {
        let named = key(id: 0, model: "Power Macintosh G4", os: "9.1.0")
        XCTAssertTrue(named.identity.contains("power-macintosh-g4"),
                      "got \(named.identity)")
        XCTAssertNotEqual(named.identity,
                          key(id: 0, model: "Power Macintosh G3",
                              os: "9.1.0").identity)
    }

    /// 0 is the guest's word for "Gestalt did not answer" and must never
    /// read as a machine type. A key of `m0` would merge every machine
    /// that failed to identify itself into one pack.
    func testZeroIsNotAMachineType() {
        XCTAssertFalse(key(id: 0, model: "Power Macintosh G4",
                           os: "9.1.0").identity.contains("m0"))
    }

    // MARK: - what "we do not know" must not become

    /// **The case that matters most.** A guest built before 2026-08-07
    /// sends no `machine` and an `os` that is a compiled-in literal. The
    /// key must report itself incomplete, so nothing auto-selects a pack
    /// from it — dressing one machine in another's art is precisely what
    /// the provenance rules exist to prevent.
    func testAGuestPredatingTheFieldCannotBeKeyed() {
        XCTAssertFalse(key(id: nil, model: nil, os: "9").isComplete)
        XCTAssertFalse(key(id: nil, model: nil, os: nil).isComplete)
    }

    /// `unknown` is the guest saying it looked and could not establish
    /// it. That is a fact, and it is still not a key.
    func testUnknownIsNotAKey() {
        XCTAssertFalse(key(id: 0, model: "unknown", os: "unknown").isComplete)
        XCTAssertFalse(key(id: 406, model: nil, os: "unknown").isComplete,
                       "a known machine on an unknown System cannot pick art")
    }

    func testAMeasuredGuestIsComplete() {
        XCTAssertTrue(key(id: 406, model: "PowerBook 1400cs/117",
                          os: "9.1.0").isComplete)
        XCTAssertTrue(key(id: 0, model: "Power Macintosh G4",
                          os: "9.1.0").isComplete,
                      "a model with no id is still enough to key")
    }

    /// The label a person reads NAMES what is missing rather than eliding
    /// it. "PowerBook 1400c" alone is a claim about a pack's System;
    /// "PowerBook 1400c — System unknown" is a usable sentence.
    func testTheLabelSaysWhatIsMissing() {
        XCTAssertEqual(key(id: 406, model: "PowerBook 1400cs/117",
                           os: nil).description,
                       "PowerBook 1400cs/117 — System unknown")
        XCTAssertEqual(key(id: 34, model: nil, os: "7.1.0").description,
                       "machine type 34 — System 7.1.0")
        XCTAssertEqual(key(id: nil, model: nil, os: nil).description,
                       "unknown machine — System unknown")
    }

    // MARK: - it comes off the wire typed

    /// The key reads `hello`'s TYPED fields. Nothing here parses a census
    /// display string, which is the design decision the whole of S0 was
    /// for — the two guests spell the same fact differently there.
    func testTheKeyComesStraightOffHello() {
        let hello = Hello(
            contract: Contract.revision, side: "guest", version: "0.30",
            name: "Michelle's PowerBook", os: "9.1.0",
            machine: GuestMachine(id: 406, model: "PowerBook 1400cs/117"))
        let derived = AssetPackKey(hello: hello)
        XCTAssertEqual(derived.machineID, 406)
        XCTAssertEqual(derived.machineModel, "PowerBook 1400cs/117")
        XCTAssertEqual(derived.systemVersion, "9.1.0")
        XCTAssertTrue(derived.isComplete)
    }

    /// `hello.name` is a label and must not reach the key by any route.
    /// It is the Sharing name, a person edits it, and on this project a
    /// deployed guest wears its MacBinary name — so keying on it would
    /// mint a new pack identity on every redeploy.
    ///
    /// The guest with NO `machine` is the case that guards this, and the
    /// first version of this test used one WITH a machine — where a
    /// `?? hello.name` fallback can never engage, so it asserted nothing
    /// and passed against the mutation it was written for. Left as a
    /// comment because that is the shape: a test of a fallback must reach
    /// the state where the fallback runs.
    func testTheHumanLabelNeverReachesTheKey() {
        func hello(named name: String, machine: GuestMachine?) -> Hello {
            Hello(contract: Contract.revision, side: "guest",
                  version: "0.30", name: name, os: "9.1.0", machine: machine)
        }
        // The redeploy case: same Mac, two MacBinary names, no machine
        // field to hide behind.
        XCTAssertEqual(
            AssetPackKey(hello: hello(named: "New Old World", machine: nil)),
            AssetPackKey(hello: hello(named: "now-guest-ppc", machine: nil)))
        XCTAssertNil(
            AssetPackKey(hello: hello(named: "New Old World",
                                      machine: nil)).machineModel,
            "hello.name must not become a model")

        // And with a machine present, the name still cannot move it.
        let m = GuestMachine(id: 406, model: "PowerBook 1400cs/117")
        XCTAssertEqual(
            AssetPackKey(hello: hello(named: "New Old World", machine: m)),
            AssetPackKey(hello: hello(named: "now-guest-ppc", machine: m)))
    }

    /// A guest that predates the field decodes as nil rather than as a
    /// zero machine — the two mean different things and a receiver acts
    /// differently on them.
    func testAHelloWithoutMachineDecodesAsNil() throws {
        let raw = #"{"type":"hello","contract":\#(Contract.revision),"#
            + #""side":"guest","version":"0.1","name":"x","os":"9"}"#
        let hello = try JSONDecoder().decode(
            Hello.self, from: Data(raw.utf8))
        XCTAssertNil(hello.machine)
        XCTAssertFalse(AssetPackKey(hello: hello).isComplete)
    }
}
