import XCTest
@testable import MirrorKit

/// The parity gate (MIRRORKIT-PLAN decision 5), in two halves:
///
/// 1. **The shape does not drift.** A maximal scene — every optional filled,
///    every array non-empty — is encoded and its key paths compared against
///    `IRSchema`. Add or remove a field anywhere in the IR and this goes red.
/// 2. **A consumer refuses an unknown major.** `MirrorScene.decode` checks
///    `irVersion` *before* it decodes, and rejects a version it cannot vouch
///    for rather than best-efforting it.
///
/// Both were watched failing under a deliberate mutation before being trusted:
/// adding a `Scene.Window.probe` field reddened case 1 twice (wire paths and
/// declared properties); flipping `IR.supportedMajors` reddened case 2.
final class IRFreezeTests: XCTestCase {

    // MARK: - The probe value

    /// A scene that exercises **every** field in the IR, including the two
    /// host-internal shelves that never encode. Deliberately not a fixture:
    /// fixtures are captured guest reality and are the wrong tool for "does
    /// the type still have all its fields" — no real capture fills every
    /// optional at once.
    static func maximalScene() -> Scene {
        let rect = Rect(l: 1, t: 2, r: 3, b: 4)

        var op = DisplayOp(op: "text", ticks: 7)
        op.text = "x"; op.pen = [1, 2]; op.font = 3; op.size = 9; op.face = 0
        op.verb = 1; op.rect = [1, 2, 3, 4]; op.ext = [5, 6]
        op.from = [1, 2]; op.to = [3, 4]
        op.kind = "origin"; op.origin = [0, 0]; op.rgb = [0, 0, 0]
        op.src = [1, 2, 3, 4]; op.dst = [1, 2, 3, 4]

        let item = Scene.DesktopItem(
            name: "n", kind: "file", type: "TEXT", creator: "ttxt",
            x: 10, y: 20, placed: true, alias: false, invisible: false,
            w: 16, h: 16,   // a list row: MAXIMAL means the box too
            origin: .drawn) // …and where that box came from

        let control = Scene.Control(
            ref: "r", role: "scrollbar", title: "t", rect: rect,
            enabled: true, visible: true, value: 1, min: 0, max: 2,
            checked: false,
            semantic: .init(
                knowledge: .known, kind: "scrollBar",
                definition: "system", action: "scroll",
                state: "on", value: "1",
                listCells: [.init(row: 1, column: 0, text: "Cell",
                                       selected: true)],
                listTotalCount: 1,
                selection: .init(start: 0, end: 1), focused: true,
                isDefault: false, provenance: "guest-control-manager",
                completeness: .complete))
        let dialogItem = Scene.DialogItem(
            number: 1, title: "OK", rect: rect, enabled: true,
            visible: true, ref: "r",
            semantic: .init(
                knowledge: .known, kind: "pushButton",
                definition: "application", action: "press",
                state: "off", value: "OK",
                selection: .init(start: 0, end: 2), focused: false,
                isDefault: true, provenance: "guest-ditl",
                completeness: .complete))

        let window = Scene.Window(
            id: "0.1/W#0", app: "A", psn: "0.1", title: "W", kind: 2,
            rect: rect, front: true, z: 0, visible: true,
            controls: [control], dialogItems: [dialogItem],
            ref: "now-window-probe",
            addr: 0x1EA2D3E0,
            incarnation: "process-12345678/window-1ea2d3e0",
            text: .init(content: "c", active: true),
            items: [item],
            display: [op],
            island: PixelIsland(width: 1, height: 1,
                                rgba: Data([0, 0, 0, 255]),
                                originX: 0, originY: 0, scale: 1))

        return Scene(
            version: IR.version, seq: 1, source: "axtree", capturedAt: 1,
            screen: .init(w: 800, h: 600),
            apps: [.init(psn: "0.1", name: "A", front: true,
                         incarnation: "process-12345678", error: "e")],
            processes: [.init(psn: "0.1", name: "A", front: true,
                              signature: "MACS",
                              incarnation: "process-12345678")],
            menubar: .init(app: "A", menus: [
                .init(title: "File", apple: false, left: 40, id: 128, items: [
                    .init(title: "New", index: 1, separator: false,
                          enabled: true, mark: false, cmd: "N"),
                ]),
            ]),
            windows: [window],
            desktopItems: [item],
            meta: .init(
                latencyMs: 1, bytes: 2, errors: ["e"], plane: "p",
                coverage: [
                    .init(scope: "processes", status: .complete),
                    .init(scope: "windows", owner: "process-12345678",
                          status: .complete),
                    .init(scope: "menubar", owner: "process-12345678",
                          status: .retracted, reason: "validation"),
                ]))
    }

    // MARK: - 1. The shape does not drift

    func testEncodedWireShapeMatchesTheFreeze() throws {
        let data = try JSONEncoder().encode(Self.maximalScene())
        let produced = try IRSchema.wirePaths(ofEncoded: data)
        guard let expected = IRSchema.expectedWirePaths(major: IR.version) else {
            return XCTFail("""
                IR.version is \(IR.version) but IRSchema declares no field set \
                for that major. A version move needs its own manifest.
                """)
        }
        assertSetsEqual(produced, expected, what: "encoded IR wire path")
    }

    func testDeclaredPropertiesMatchTheFreeze() throws {
        let produced = IRSchema.declaredProperties(of: Self.maximalScene())
        guard let expected = IRSchema.expectedProperties(major: IR.version) else {
            return XCTFail("no property manifest for major \(IR.version)")
        }
        assertSetsEqual(produced, expected, what: "declared IR property")
    }

    /// `island` stays off the wire. Stated as its own assertion because it is
    /// a *decision*, not a byproduct: re-adding it to `CodingKeys` should read
    /// as breaking this promise, not as editing a list.
    func testIslandIsNotOnTheWire() throws {
        let data = try JSONEncoder().encode(Self.maximalScene())
        let paths = try IRSchema.wirePaths(ofEncoded: data)
        XCTAssertFalse(paths.contains("windows[].island"),
                       "island pixels ride their own pager, not the scene IR")
        // …and it is still declared, so the renderer keeps its shelf.
        let props = IRSchema.declaredProperties(of: Self.maximalScene())
        XCTAssertTrue(props.contains("Scene.Window.island"))
    }

    /// `windows[].items` came back ADDITIVELY (lane H2, 2026-07-31): on the
    /// wire, recorded in `v1Additions`, absent from `v1Frozen`, and the major
    /// did not move. That is the whole shape of an addition, and each clause
    /// is a way the next one could be got wrong.
    func testWindowItemsReEnteredAdditively() throws {
        let data = try JSONEncoder().encode(Self.maximalScene())
        let paths = try IRSchema.wirePaths(ofEncoded: data)
        XCTAssertTrue(paths.contains("windows[].items"),
                      "the Finder's own live positions are on the wire now")
        XCTAssertTrue(paths.contains("windows[].items[].x"))
        XCTAssertTrue(IRSchema.v1Additions.contains("windows[].items"),
                      "an addition must be recorded, or the gate cannot tell "
                      + "it from drift")
        XCTAssertFalse(IRSchema.v1Frozen.contains("windows[].items"),
                       "v1Frozen is final — additions live in v1Additions")
        XCTAssertEqual(IR.version, 2,
                       "v2 moved for semantic truth, not for Finder items")
    }

    /// The probe is only as good as its coverage: if it stops filling an
    /// optional, the wire walk silently stops watching that subtree. Nail the
    /// invariant that every declared wire-bearing type is actually reached.
    func testProbeReachesEveryWireBearingType() throws {
        let data = try JSONEncoder().encode(Self.maximalScene())
        let paths = try IRSchema.wirePaths(ofEncoded: data)
        for root in ["processes", "menubar", "desktopItems",
                     "windows[].text", "windows[].display",
                     "windows[].controls", "windows[].controls[].rect"] {
            XCTAssertTrue(paths.contains(root),
                          "probe scene no longer populates \(root)")
        }
    }

    // MARK: - 2. The version is one number in two places

    func testSceneBuilderStampsTheCurrentVersion() {
        let axtree = SceneBuilder.sceneFromAxtree(
            [:], seq: 0, screen: .init(w: 0, h: 0), capturedAt: 0)
        let observe = SceneBuilder.sceneFromObserve(
            [:], seq: 0, screen: .init(w: 0, h: 0), capturedAt: 0)
        XCTAssertEqual(axtree.version, IR.version)
        XCTAssertEqual(observe.version, IR.version)
        XCTAssertEqual(IR.version, 2, "v2 semantic evidence")
        XCTAssertTrue(IR.supportedMajors.contains(IR.version),
                      "we must be able to consume what we produce")
    }

    // MARK: - 3. A consumer refuses an unknown major

    private func result(irVersion: Any?, scene: Scene? = nil) throws
        -> [String: Any] {
        var out: [String: Any] = [:]
        if let irVersion { out["irVersion"] = irVersion }
        let body = scene ?? Self.maximalScene()
        out["scene"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body))
        return out
    }

    func testConsumerAcceptsTheCurrentMajor() throws {
        let decoded = try MirrorScene.decode(
            result: try result(irVersion: IR.version))
        XCTAssertEqual(decoded.version, IR.version)
        XCTAssertEqual(decoded.windows.first?.title, "W")
        // The excluded shelf does not survive the wire, by design.
        XCTAssertNil(decoded.windows.first?.island)
        // …but window items do, since they re-entered additively.
        XCTAssertEqual(decoded.windows.first?.items?.first?.name, "n")
    }

    func testConsumerRefusesAnUnknownMajor() throws {
        for future in [3, 99] {
            XCTAssertThrowsError(
                try MirrorScene.decode(result: try result(irVersion: future)),
                "major \(future) must be refused, not best-efforted"
            ) { error in
                XCTAssertEqual(error as? IR.CompatError,
                               .unknownMajor(future))
            }
        }
        // A pre-freeze producer (v0) is an unknown major too — it is not
        // "close enough", it is the shape we just stopped promising.
        XCTAssertThrowsError(
            try MirrorScene.decode(result: try result(irVersion: 0))
        ) { XCTAssertEqual($0 as? IR.CompatError, .unknownMajor(0)) }
    }

    func testConsumerRefusesAMissingOrMalformedVersion() throws {
        XCTAssertThrowsError(
            try MirrorScene.decode(result: try result(irVersion: nil))
        ) { XCTAssertEqual($0 as? IR.CompatError, .missingVersion) }

        XCTAssertThrowsError(
            try MirrorScene.decode(result: try result(irVersion: "1"))
        ) { XCTAssertEqual($0 as? IR.CompatError, .malformedVersion("1")) }

        XCTAssertThrowsError(
            try MirrorScene.decode(result: try result(irVersion: true))
        ) { XCTAssertTrue($0 is IR.CompatError) }
    }

    /// The gate must run BEFORE the payload does. Proven by handing it a
    /// bad major *and* garbage where the scene goes: the error must be the
    /// version, not the payload.
    func testVersionIsCheckedBeforeThePayload() {
        let bad: [String: Any] = ["irVersion": 7, "scene": ["nonsense": 1]]
        XCTAssertThrowsError(try MirrorScene.decode(result: bad)) {
            XCTAssertEqual($0 as? IR.CompatError, .unknownMajor(7))
        }
    }

    func testAttachGateIsTheSameGate() throws {
        XCTAssertEqual(try MirrorScene.acceptAttach(
            result: ["session": "s", "irVersion": IR.version]), IR.version)
        XCTAssertThrowsError(try MirrorScene.acceptAttach(
            result: ["session": "s", "irVersion": 3]))
        XCTAssertThrowsError(try MirrorScene.acceptAttach(
            result: ["session": "s"]))
    }

    // MARK: - Reporting

    private func assertSetsEqual(_ produced: Set<String>,
                                 _ expected: Set<String>,
                                 what: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let added = produced.subtracting(expected).sorted()
        let removed = expected.subtracting(produced).sorted()
        if !added.isEmpty {
            XCTFail("""
                \(added.count) new \(what)(s) are not in the v2 manifest:
                  \(added.joined(separator: "\n  "))
                Additive? record them in the current major's additions. \
                Otherwise move IR.version.
                """, file: file, line: line)
        }
        if !removed.isEmpty {
            XCTFail("""
                \(removed.count) frozen \(what)(s) disappeared:
                  \(removed.joined(separator: "\n  "))
                Removing a field from the IR is a breaking change: move \
                IR.version and give the new major its own manifest.
                """, file: file, line: line)
        }
    }
}
