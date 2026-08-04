import XCTest
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration
@testable import Host

/// The translation from Mirror's vocabulary to NOW's act lane.
///
/// This is the seam the archived port never got to exercise, because the
/// scene it would have translated could not address anything: controls
/// were in the wrong coordinate space and windows carried no reference.
/// Both are fixed, so the translation is now the thing that can be wrong
/// — and it is wrong in a way no compiler catches, because every window
/// act is the same struct with a different subset of its geometry filled.
@MainActor
final class NOWMirrorSourceTests: XCTestCase {

    // MARK: - The live window's IR gate

    func testTheLiveMirrorReadsEveryMajorMirrorKitSupports() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let v1 = try Data(contentsOf: fixture)
        var v2Object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: v1) as? [String: Any])
        v2Object["version"] = 2
        let v2 = try JSONSerialization.data(withJSONObject: v2Object)

        XCTAssertEqual(try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: v1).version, 1)
        XCTAssertEqual(try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: v2).version, 2,
            "the actual Mirror window must not retain its own v1-only gate")
        XCTAssertEqual(NOWMirrorSceneDecoder.readableMajors, "v1, v2")
    }

    func testTheLiveMirrorGatesBeforeItParses() {
        let garbage = Data("not a scene".utf8)

        XCTAssertThrowsError(try NOWMirrorSceneDecoder.decode(
            irVersion: 3, document: garbage)) { error in
            XCTAssertEqual(error as? IR.CompatError, .unknownMajor(3))
        }
    }

    func testTheLiveMirrorRejectsEnvelopeBodyDisagreement() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))

        XCTAssertThrowsError(try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: fixture))) { error in
            guard case .malformedScene(let message) = error as? IR.CompatError
            else { return XCTFail("expected version disagreement, got \(error)") }
            XCTAssertTrue(message.contains("does not match envelope"))
        }
    }

    func testMenuTargetComesFromTheSceneFrontProcess() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let scene = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        XCTAssertEqual(NOWMirrorSource.frontProcess(in: scene),
                       .init(high: 0, low: 29_949_953))

        var ambiguous = scene
        ambiguous.processes?[0].front = true
        XCTAssertNil(NOWMirrorSource.frontProcess(in: ambiguous),
                     "two front rows must refuse rather than guess")
    }

    func testAnEmptyAppleShellCannotEraseTheLastCompleteGuestMenu() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let complete = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        let completeApple = try XCTUnwrap(
            complete.menubar?.menus.first(where: \.apple))
        XCTAssertFalse(completeApple.items.isEmpty,
                       "the captured guest fixture must exercise real rows")

        var delayed = complete
        let appleIndex = try XCTUnwrap(
            delayed.menubar?.menus.firstIndex(where: \.apple))
        delayed.menubar?.app = "New Old World"
        delayed.menubar?.menus[appleIndex].id = 512
        delayed.menubar?.menus[appleIndex].left = 7
        delayed.menubar?.menus[appleIndex].items = []

        let merged = NOWMirrorSceneContinuity.accept(
            delayed, after: complete)
        let apple = try XCTUnwrap(
            merged.scene.menubar?.menus.first(where: \.apple))

        XCTAssertEqual(apple.items, completeApple.items,
                       "a delayed empty shell is expected-stale, not deletion")
        XCTAssertEqual(apple.id, 512,
                       "identity still comes from the newest guest scene")
        XCTAssertEqual(apple.left, 7,
                       "geometry still comes from the newest guest scene")
        XCTAssertTrue(merged.retainedAppleItems)
    }

    func testACompleteAppleRefreshAlwaysReplacesRetainedRows() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        var previous = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        var incoming = previous
        let appleIndex = try XCTUnwrap(
            incoming.menubar?.menus.firstIndex(where: \.apple))
        previous.menubar?.menus[appleIndex].items[0].title = "Stale row"
        incoming.menubar?.menus[appleIndex].items[0].title = "Fresh row"

        let merged = NOWMirrorSceneContinuity.accept(
            incoming, after: previous)

        XCTAssertEqual(merged.scene.menubar?.menus[appleIndex].items[0].title,
                       "Fresh row")
        XCTAssertFalse(merged.retainedAppleItems)
    }

    func testAnInitiallyEmptyAppleMenuStaysHonestlyEmpty() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        var incoming = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        let appleIndex = try XCTUnwrap(
            incoming.menubar?.menus.firstIndex(where: \.apple))
        incoming.menubar?.menus[appleIndex].items = []

        let merged = NOWMirrorSceneContinuity.accept(incoming, after: nil)

        XCTAssertTrue(merged.scene.menubar?.menus[appleIndex].items.isEmpty
                      == true)
        XCTAssertFalse(merged.retainedAppleItems,
                       "the host must never invent Apple-menu rows")
    }

    func testVisibleSceneComesFromTheSessionEngineAfterCutover() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let legacy = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: fixture))
        var reduced = legacy
        reduced.seq += 1
        reduced.windows.removeAll()
        let projection = MirrorProjection(
            id: 7,
            session: .init(guest: "maxbook", incarnation: "session-a"),
            sequence: reduced.seq, digest: "engine", baseComplete: true,
            scene: reduced)

        XCTAssertEqual(NOWMirrorSource.projectedScene(
            snapshot: projection, fallback: legacy), reduced)
        XCTAssertEqual(NOWMirrorSource.projectedScene(
            snapshot: nil, fallback: legacy), legacy,
            "registry-free source fixtures retain their explicit fallback")
    }

    func testOnlyConfirmedSettlementEarnsTheGreenCheckmark() {
        XCTAssertTrue(NOWMirrorSource.isConfirmedSettlement("confirmed"))
        for status in [nil, "unknown", "dispatched-but-unconfirmed",
                       "timed-out", "refused", "session-changed"] {
            XCTAssertFalse(NOWMirrorSource.isConfirmedSettlement(status),
                           "\(status ?? "absent") must not render green")
        }
    }

    func testSuccessfulInputDispatchIsExplicitlyUnconfirmed() {
        XCTAssertEqual(NOWMirrorSource.dispatchOnlySettlement(
            ifSuccessful: nil), "dispatched-but-unconfirmed")
        XCTAssertNil(NOWMirrorSource.dispatchOnlySettlement(
            ifSuccessful: "guest refused"),
            "a refusal keeps its own complaint rather than a dispatch word")
    }

    func testActivationRequiresTheGuestsFrontProcessReread() {
        XCTAssertNil(NOWMirrorSource.activationOutcome(
            "\"yes, re-read from the machine\""))
        XCTAssertNotNil(NOWMirrorSource.activationOutcome(nil))
        XCTAssertNotNil(NOWMirrorSource.activationOutcome("fronted"),
                        "an ok/accepted word is not the guest's re-read")
    }

    func testSettlementTimeoutReportsOnceThenLateConfirmationWins() {
        var tracker = MirrorSettlementTracker()
        XCTAssertTrue(tracker.track("A5A50001-00000007",
                                    label: "move").isEmpty)
        let timedOut = settlement(lo: 7, status: "timed-out",
                                  timedOut: 120)
        XCTAssertEqual(tracker.apply([timedOut]), [
            .init(label: "move", outcome: "timed-out", confirmed: false),
        ])
        XCTAssertTrue(tracker.apply([timedOut]).isEmpty,
                      "polling the same timeout must not report it again")
        XCTAssertEqual(tracker.apply([
            settlement(lo: 7, status: "confirmed", timedOut: 120),
        ]), [
            .init(label: "move", outcome: "confirmed after timing out",
                  confirmed: true),
        ])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testTerminalRefusalAndSessionChangeNeverConfirm() {
        for (lo, status) in [(8, "refused"), (9, "session-changed")] {
            var tracker = MirrorSettlementTracker()
            _ = tracker.track(String(format: "A5A50001-%08X", lo),
                              label: status)
            XCTAssertEqual(tracker.apply([
                settlement(lo: UInt32(lo), status: status),
            ]), [
                .init(label: status, outcome: status, confirmed: false),
            ])
            XCTAssertEqual(tracker.pendingCount, 0)
        }
    }

    func testAbsentSettlementListNeverInventsConfirmation() {
        var tracker = MirrorSettlementTracker()
        _ = tracker.track("A5A50001-0000000A", label: "close")
        XCTAssertTrue(tracker.apply(nil).isEmpty)
        XCTAssertEqual(tracker.pendingCount, 1,
                       "an older guest supplies no settlement evidence")
    }

    func testFullGuestRingMakesAMissingCorrelationExplicitlyUnknown() {
        var tracker = MirrorSettlementTracker()
        _ = tracker.track("A5A50001-00000063", label: "old act")
        let fullRing = (0..<MirrorSettlementTracker.capacity).map {
            settlement(lo: UInt32($0), status: "dispatched-but-unconfirmed")
        }
        XCTAssertEqual(tracker.apply(fullRing), [
            .init(label: "old act",
                  outcome: "unknown (guest settlement evicted)",
                  confirmed: false),
        ])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testHostSettlementTrackingEvictsOldestInsertion() {
        var tracker = MirrorSettlementTracker()
        _ = tracker.track("FFFFFFFF-FFFFFFFF", label: "oldest")
        for value in 0..<(MirrorSettlementTracker.capacity - 1) {
            _ = tracker.track(String(format: "00000000-%08X", value),
                              label: "later \(value)")
        }
        XCTAssertEqual(tracker.track("AAAAAAAA-AAAAAAAA", label: "new"), [
            .init(label: "oldest",
                  outcome: "unknown (host settlement tracking evicted)",
                  confirmed: false),
        ], "eviction follows insertion age, not correlation sort order")
        XCTAssertEqual(tracker.pendingCount, MirrorSettlementTracker.capacity)
    }

    // MARK: - Window acts carry exactly their own geometry

    func testEachWindowActCarriesTheKeysItTakes() {
        let ref = "now-window-1"

        let select = NOWMirrorSource.request(ref, .select)
        XCTAssertEqual(select.action, .select)
        assertOnly(select, keys: [])

        let close = NOWMirrorSource.request(ref, .close)
        XCTAssertEqual(close.action, .close)
        assertOnly(close, keys: [])

        let zoom = NOWMirrorSource.request(ref, .zoom(out: true))
        XCTAssertEqual(zoom.action, .zoom)
        /* The zoom box takes no geometry - the standard state is the
           application's to compute. A host that supplied one would be
           deciding what the window is FOR, and the guest refuses the
           extra key rather than zooming and discarding it. */
        assertOnly(zoom, keys: [])

        let move = NOWMirrorSource.request(ref, .move(left: 40, top: 90))
        XCTAssertEqual(move.action, .move)
        XCTAssertEqual(move.left, 40)
        XCTAssertEqual(move.top, 90)
        assertOnly(move, keys: ["left", "top"])

        let size = NOWMirrorSource.request(ref, .resize(width: 300,
                                                        height: 200))
        XCTAssertEqual(size.action, .resize)
        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 200)
        assertOnly(size, keys: ["width", "height"])
    }

    /// Every act names its own window. Sounds trivial; it is the field
    /// that did not exist at all until `Scene.Window` started carrying
    /// the reference its producer had always sent.
    func testEveryActNamesItsWindow() {
        for what: MirrorAction.WindowAct in [.select, .close,
                                             .zoom(out: false),
                                             .move(left: 1, top: 2),
                                             .resize(width: 3, height: 4)] {
            XCTAssertEqual(NOWMirrorSource.request("now-window-7", what).window,
                           "now-window-7")
        }
    }

    // MARK: - System Application-menu visibility

    func testFinderItemCommandsAlsoActivateFinder() {
        let source = NOWMirrorSource.finderScript(
            "open item \"Macintosh HD\" of desktop")
        XCTAssertTrue(source.contains("open item \"Macintosh HD\" of desktop"))
        XCTAssertTrue(source.contains("activate"))
        XCTAssertTrue(source.contains("tell application \"Finder\""))
    }

    func testApplicationVisibilityUsesClassicFinderSemantics() {
        let hide = NOWMirrorSource.applicationVisibilityScript(
            .hide(name: "New Old World"))
        XCTAssertTrue(hide.contains("set visible of application process "
                                    + "\"New Old World\" to false"))
        XCTAssertTrue(hide.contains("ignoring application responses"))
        XCTAssertTrue(hide.contains("return \"dispatched-but-unconfirmed\""))
        let show = NOWMirrorSource.applicationVisibilityScript(.showAll)
        XCTAssertTrue(show.contains("set visible of every application "
                                    + "process to true"))
        XCTAssertTrue(show.contains("if not (visible of candidate)"))

        let others = NOWMirrorSource.applicationVisibilityScript(
            .hideOthers(except: "New \"Old\" World"))
        XCTAssertTrue(others.contains("repeat with candidate in every "
                                      + "application process"), others)
        XCTAssertTrue(others.contains(
            "if name of candidate is not \"New \\\"Old\\\" World\" then"),
            others)
        XCTAssertTrue(others.contains("set visible of candidate to false"),
                      others)
        XCTAssertTrue(others.contains("ignoring application responses"))
        XCTAssertNil(NOWMirrorSource.visibilityOutcome("\"confirmed\""))
        XCTAssertEqual(NOWMirrorSource.visibilityOutcome(
            "\"dispatched-but-unconfirmed\""),
            "dispatched-but-unconfirmed")
        XCTAssertEqual(NOWMirrorSource.visibilityOutcome(nil),
                       "visibility outcome unavailable")
    }

    /// The guest states the key rule and this asserts against THAT, not
    /// against a copy of it — a translation tested against its own
    /// assumptions tests one half twice.
    private func assertOnly(_ r: AgentIntegrationWindowActRequest,
                            keys expected: Set<String>,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(
            AgentIntegrationWindowActRequest.geometryKeys(for: r.action),
            expected,
            "the vocabulary and this test disagree about what \(r.action) "
            + "takes", file: file, line: line)

        var present: Set<String> = []
        if r.left != nil { present.insert("left") }
        if r.top != nil { present.insert("top") }
        if r.width != nil { present.insert("width") }
        if r.height != nil { present.insert("height") }
        XCTAssertEqual(present, expected,
                       "\(r.action) carries \(present) where the guest "
                       + "takes \(expected); a surplus key is not a "
                       + "slightly-wrong act, it is a refused one",
                       file: file, line: line)
    }

    private func settlement(lo: UInt32, status: String,
                            timedOut: UInt32 = 0) -> ActSettlement {
        .init(correlationHi: 0xA5A5_0001, correlationLo: lo,
              status: status, residentStage: 4, createdTicks: 100,
              timedOutTicks: timedOut, terminalTicks: 140,
              confirmedScene: status == "confirmed" ? 12 : 0)
    }

    // MARK: - What this driver declares

    func testTheDriverDeclaresTheActPlaneAndNoPositionalClick() {
        let planes = ActionPlanes.residentActPlane
        XCTAssertTrue(planes.semanticActs)
        /* NOW's contract has no click-at-a-point verb and says so
           deliberately. Declaring otherwise would make every desktop
           click a silent no-op instead of a named refusal. */
        XCTAssertFalse(planes.positionalClick)
        XCTAssertFalse(planes.inputDevice)

        guard case .unsupported = ActionModel.availability(
            .click(x: 1, y: 1), planes: planes) else {
            return XCTFail("a positional click must be refused BY NAME")
        }
        guard case .inputDeviceUnavailable = ActionModel.availability(
            .deviceDrag(x0: 0, y0: 0, x1: 1, y1: 1), planes: planes) else {
            return XCTFail("a device drag needs an input adapter")
        }
        XCTAssertEqual(
            ActionModel.availability(.controlPart(ref: "r", part: 21),
                                     planes: planes),
            .available)
    }

    /// A scene NOW actually produced, resolved to the act that would be
    /// sent for a click on a scroll arrow. The fixture is the same one
    /// the decode, render and hit-test gates read, so all four fail
    /// together if the producer drifts.
    func testARealSceneResolvesToASemanticControlAct() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        let scene = try JSONDecoder().decode(
            MirrorKit.Scene.self, from: Data(contentsOf: url))

        // Any live scrollbar in a foreign window will do.
        var found = false
        for win in scene.windows where win.app != "New Old World" {
            for ctl in win.controls where Scrollbar.isLive(ctl) {
                guard let r = ctl.rect else { continue }
                let x = win.rect.l + (r.l + r.r) / 2
                let y = win.rect.t + SceneBuilder.titleBarHeight + r.b - 4
                let hit = HitTester.hitTest(scene, x: x, y: y)
                guard case .scrollbar = hit else { continue }
                guard case .controlPart(let ref, let part, _) =
                    ActionModel.click(on: hit, planes: .residentActPlane,
                                      in: scene).first else {
                    return XCTFail("a live scrollbar must resolve to a "
                                   + "control part on this driver")
                }
                XCTAssertEqual(ref, ctl.ref)
                XCTAssertTrue([20, 21, 22, 23].contains(part),
                              "part \(part) is not an arrow or page region")
                found = true
            }
        }
        XCTAssertTrue(found,
                      "the fixture carries no live scrollbar in a foreign "
                      + "window, so this asserted nothing - recapture with "
                      + "scripts/probes/capture-scene-fixture.py")
    }
}

/// The icon reader, pinned against what the machine actually returned.
///
/// Two format facts, both measured on OS 9.1 rather than remembered, and
/// both of which would silently produce zero icons if wrong:
///
///  - `OSADoScript` renders its result in SOURCE form, so a text answer
///    arrives WRAPPED IN QUOTES;
///  - classic AppleScript's line terminator is CR, which is why the
///    script builds its output with `return` and not `linefeed` — that
///    identifier does not exist in OS 9's AppleScript and fails the whole
///    script with osaErr -1753.
@MainActor
final class NOWMirrorIconParsingTests: XCTestCase {

    /// Verbatim from the guest, trimmed. Two row kinds: `I` is an item
    /// and where the Finder drew it, `F` carries a FILE's type and
    /// creator — which is what picks the real icon out of the atlas.
    /// Without them every document rendered as the same generic page.
    private let sample = "\"I\tTrash\t716\t510\tfolder\r"
        + "I\tBrowse the Internet\t716\t187\talias\r"
        + "I\tFrom Claude.txt\t608\t540\tdocument\r"
        + "I\tMacintosh HD\t736\t28\tdisk\r"
        + "F\tFrom Claude.txt\tTEXT\tttxt\t\r\""

    func testItReadsWhatTheFinderReturned() {
        let items = NOWMirrorSource.parseIcons(sample)
        XCTAssertEqual(items.count, 4, "CR-separated rows inside a quoted "
                       + "result - both are load-bearing")

        XCTAssertEqual(items[0].name, "Trash",
                       "the opening quote of the SOURCE-form result leaked "
                       + "into the first icon's name")
        XCTAssertEqual(items[0].x, 716)
        XCTAssertEqual(items[0].y, 510)
        XCTAssertEqual(items[0].kind, "folder")

        XCTAssertTrue(items[1].alias, "an alias is drawn differently")
        XCTAssertEqual(items[3].kind, "disk")
        XCTAssertEqual(items[3].name, "Macintosh HD")
        XCTAssertTrue(items.allSatisfy(\.placed))
    }

    /// The join that makes an icon look like itself.
    func testAFilesTypeAndCreatorReachTheItem() {
        let items = NOWMirrorSource.parseIcons(sample)
        let doc = items.first { $0.name == "From Claude.txt" }
        XCTAssertEqual(doc?.type, "TEXT")
        XCTAssertEqual(doc?.creator, "ttxt")
        // A folder is not a file and was never asked; absence is correct.
        XCTAssertNil(items.first { $0.name == "Trash" }?.type)
    }

    /// A row the script could not complete is dropped, not guessed at.
    func testShortAndUnparseableRowsAreDropped() {
        let ragged = "\"I\tGood\t10\t20\tfolder\rI\tBad\tnope\t5\tfolder\r"
            + "I\tShort\t1\r\""
        XCTAssertEqual(NOWMirrorSource.parseIcons(ragged).map(\.name),
                       ["Good"])
    }

    func testAnEmptyContainerIsNoIconsRatherThanACrash() {
        XCTAssertTrue(NOWMirrorSource.parseIcons("\"\"").isEmpty)
        XCTAssertTrue(NOWMirrorSource.parseIcons("").isEmpty)
    }

    /// The two passes are two scripts now, and their results are joined.
    /// Each arrives in SOURCE form carrying its OWN quotes, so joining
    /// them raw would leave a `""` inside a line and eat the rows on
    /// either side of it.
    func testTwoSourceFormBlobsJoinWithoutEatingARow() {
        let items = "\"I\tSystem Folder\t10\t20\tfolder\r"
            + "I\tRead Me\t10\t60\tdocument\r\""
        let art = "\"F\tRead Me\tTEXT\tttxt\t\r\""
        let joined = NOWMirrorSource.unquote(items) + "\r"
            + NOWMirrorSource.unquote(art)
        let parsed = NOWMirrorSource.parseIcons(joined)

        XCTAssertEqual(parsed.map(\.name), ["System Folder", "Read Me"],
                       "the row at the seam was eaten by a stray quote")
        XCTAssertEqual(parsed.last?.type, "TEXT",
                       "the second blob's types must still reach the items")
    }

    /// Why they were split at all: `file type of` a folder or a disk is
    /// an error, and AppleScript fails a script WHOLE. Fused, that error
    /// took the names and positions down with it and the window rendered
    /// as an empty box — watched on 2026-08-03, Macintosh HD empty for a
    /// whole drive while Control Panels beside it drew 33 items. Losing
    /// the art is a blemish; losing the contents is not a mirror.
    func testItemsSurviveWhenTheArtPassAnsweredNothing() {
        let items = "\"I\tSystem Folder\t10\t20\tfolder\r"
            + "I\tApplications\t10\t60\tfolder\r\""
        let parsed = NOWMirrorSource.parseIcons(
            NOWMirrorSource.unquote(items) + "\r" + NOWMirrorSource.unquote(""))

        XCTAssertEqual(parsed.map(\.name), ["System Folder", "Applications"])
        XCTAssertTrue(parsed.allSatisfy { $0.type == nil },
                      "no art is absence, not a guess")
    }

    func testUnquoteRemovesTheWrapperExactlyOnce() {
        XCTAssertEqual(NOWMirrorSource.unquote("\"a\rb\""), "a\rb")
        XCTAssertEqual(NOWMirrorSource.unquote("\"\"\"x\"\"\""), "\"\"x\"\"")
        XCTAssertEqual(NOWMirrorSource.unquote("bare"), "bare")
        XCTAssertEqual(NOWMirrorSource.unquote("\""), "\"",
                       "a lone quote is not a wrapper")
    }
}
