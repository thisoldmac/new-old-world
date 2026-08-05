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

    private func testListener() -> GuestListener {
        GuestListener(identity: .init(version: "test", name: "Test Host"))
    }

    private func testAct(_ listener: GuestListener)
        -> AgentIntegrationActControl {
        AgentIntegrationActControl(
            listener: listener, currentSessionID: { nil })
    }

    private func fixtureDelivery(for key: GuestKey) throws
        -> GuestListener.SceneDelivery {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return .init(
            document: try Data(contentsOf: fixture), irVersion: 1,
            seq: 1, capturedAt: 1, source: "test", walkMs: 1,
            settlements: nil, transferMs: 1,
            guestName: "Test Mac", guestKey: key)
    }

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

    func testPolicyRefreshWaitsForHeldSceneAndContentBeforeOneFollowUp() throws {
        let key = GuestKey.synthetic("held-cycle")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let registry = MirrorStateEngineRegistry()
        var planes = Set(MirrorPlaneID.allCases)
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: testAct(listener), interval: 3_600,
            planePolicy: { _ in planes },
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1)

        planes.remove(.semantics)
        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "a held scene still owns the cycle")

        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        XCTAssertEqual(harness.joinedScenes.count, 1)
        planes.insert(.semantics)
        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "content completion is part of the same cycle")

        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined,
                                         sentence: "content held then done"))
        XCTAssertEqual(harness.sceneRequests.count, 2,
                       "all toggles coalesce into one follow-up scene")
    }

    /// The status line is the only thing a person driving the Mirror
    /// reads, so it says when a gesture is waiting on the lane rather than
    /// on the Macintosh — and stays quiet when nothing is.
    func testStatusNamesAWaitingLaneAndIsSilentWhenNothingWaits() {
        let harness = MirrorCycleHarness(activeKey: .synthetic("status"))
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600, cycleIO: harness.io)

        source.actTimeline.depth = 0
        XCTAssertFalse(source.status.contains("waiting"))
        source.actTimeline.depth = 1        // in flight, nothing behind it
        XCTAssertFalse(source.status.contains("waiting"))
        source.actTimeline.depth = 3
        XCTAssertTrue(source.status.contains("2 waiting"), source.status)
    }

    func testSceneFromStoppedLifetimeCannotSettleRestartedSameGuest() throws {
        let key = GuestKey.synthetic("same-guest-restart")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            cycleIO: harness.io)

        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1)
        source.stop()
        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "the listener's old global request remains pending")

        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        XCTAssertTrue(harness.joinedScenes.isEmpty,
                      "the old run cannot process content in the new run")
        XCTAssertNil(source.scene,
                     "the old delivery cannot publish into the new lifetime")

        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 2,
                       "the restarted run can poll after the old lane drains")
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


    /// **A refused Hide must not hold the lane for 15 s**, and only Hide
    /// has the proof that lets it let go. Michelle's 2026-08-05 drive
    /// measured the cost: the Finder refuses `set visible` (`-10000`,
    /// `-10006`, and here `osaErr -1753`), and the refusal then waited out
    /// the whole timeout for evidence of an effect that never happened,
    /// while everything queued behind it waited too.

    /// **The premise the reach above rests on**, asserted against the
    /// scripts themselves so it cannot rot silently. Hide's proof is that
    /// its script mutates exactly once; rewrite it as a loop and the proof
    /// is gone while every test about the reach still passes.

    /// A bare osaErr reads as a broken mirror. Hiding plainly works on a
    /// Macintosh, so the sentence has to say it is NOW that has not built
    /// it, keep the code for whoever is diagnosing, and name the route
    /// still untried — which is what dates the sentence when someone makes
    /// that route work.

    /// **The outcome word is an OBSERVATION, and only one of them is a
    /// success.** The guest calls `ShowHideProcess` and then reads the flag
    /// back with `IsProcessVisible` before answering, so `hidden` means the
    /// machine was seen hidden rather than asked to hide. Watched working
    /// on an emulated Power Mac G4 2026-08-05.
    func testOnlyAReadBackHiddenCountsAsAHide() {
        XCTAssertNil(NOWMirrorSource.hideDispatchOutcome("\"hidden\""))

        /* `unconfirmed` is the exact shape of the old AppleScript lie —
           the call was accepted and the flag did not move — and it must
           never read as success again. */
        let unconfirmed = NOWMirrorSource.hideDispatchOutcome("\"unconfirmed\"")
        XCTAssertNotNil(unconfirmed)
        XCTAssertTrue(unconfirmed?.contains("still visible") == true,
                      unconfirmed ?? "nil")

        let old = NOWMirrorSource.hideDispatchOutcome("\"unavailable\"")
        XCTAssertTrue(old?.contains("CarbonLib 1.5") == true, old ?? "nil")
        XCTAssertNotNil(NOWMirrorSource.hideDispatchOutcome("\"not-running\""))
        XCTAssertNotNil(NOWMirrorSource.hideDispatchOutcome(nil))
        XCTAssertNotNil(NOWMirrorSource.hideDispatchOutcome("\"\""),
                        "an empty outcome is not a quiet success")
    }

    func testKeyCapsIsOpenedFromTheGuestsAppleMenuItemsFolder() {
        let script = NOWMirrorSource.appleMenuItemScript("Key Caps")
        XCTAssertTrue(script.contains("tell application \"Finder\""))
        XCTAssertTrue(script.contains(
            "open item \"Key Caps\" of folder \"Apple Menu Items\" "
            + "of system folder"))
        XCTAssertTrue(script.contains("return \"dispatched\""))
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

    // MARK: - The picture is older than the act

    private func fixtureScene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    /// **A click on a window the newest scene no longer carries is refused
    /// here, not on the machine.**
    ///
    /// The Mirror draws a scene a poll old and an act can wait seconds in
    /// the FIFO behind others, so by dispatch time the host often already
    /// knows the target is gone. On 2026-08-05 it sent anyway: three
    /// closes of one window, two of them answered "nothing in this process
    /// answers to that name any more" — a round trip each, and a lane slot
    /// each, to be told what the host could see.
    func testAWindowTheNewestSceneHasLostIsNotSent() throws {
        let scene = try fixtureScene()
        let live = try XCTUnwrap(scene.windows.first?.ref,
                                 "the fixture must carry a window reference")

        XCTAssertNil(
            NOWMirrorSource.staleTargetComplaint(
                for: .windowAct(ref: live, act: .close), in: scene),
            "a window the scene still carries is the caller's to act on")

        let gone = NOWMirrorSource.staleTargetComplaint(
            for: .windowAct(ref: "now-window-00000000-0000-4000-8000-"
                                 + "000000000000", act: .close),
            in: scene)
        XCTAssertNotNil(gone)
        XCTAssertTrue(gone?.contains("was not sent") == true,
                      "a person needs to know their click did nothing, not "
                          + "just that something was wrong")
    }

    /// **A null result must not cost what a hung one does.** Driving
    /// `finderOpen "Date & Time"` against the desktop, where it does not
    /// live, correctly opened nothing on 2026-08-05 — and still burned the
    /// full 15 s timeout holding the single mutation lane, teaching the
    /// caller nothing it could tell from a wedge. The roster the scene
    /// already publishes answers it here, for free.
    func testAFinderItemTheRosterDoesNotCarryIsNotSent() throws {
        let scene = try finderScene()

        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .finderOpen(item: "Macintosh HD", container: .desktop),
            in: scene), "an item the desktop roster carries is the caller's")

        let absent = NOWMirrorSource.staleTargetComplaint(
            for: .finderOpen(item: "Date & Time", container: .desktop),
            in: scene)
        XCTAssertEqual(absent, "the Finder shows no item named Date & Time "
                           + "on the desktop, so the act was not sent. "
                           + "Read it again.")

        /* Selecting names an item exactly as opening does, and pays the
           same round trip to be told it is not there. */
        let inWindow = NOWMirrorSource.staleTargetComplaint(
            for: .finderSelect(item: "Date & Time",
                               container: .window(title: "Extensions")),
            in: scene)
        XCTAssertEqual(inWindow, "the Finder shows no item named Date & Time "
                           + "in Extensions, so the act was not sent. "
                           + "Read it again.")
    }

    /// **An unread container claims nothing**, which is the same rule as
    /// "no scene is not evidence of absence" one level down. `readIcons`
    /// refuses a partial or changing roster rather than returning part of
    /// one, so a published roster IS complete — but a container it never
    /// reached is nil, and nil must not read as empty or every act into an
    /// unwalked window would be refused on the strength of a read that
    /// never happened.
    func testAnUnreadFinderContainerRefusesNothing() throws {
        let scene = try finderScene()

        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .finderOpen(item: "anything at all",
                             container: .window(title: "Control Panels")),
            in: scene), "that window published no items shelf")
        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .finderOpen(item: "anything at all",
                             container: .window(title: "No Such Window")),
            in: scene), "a window this scene does not carry cannot say")
    }

    private func finderScene() throws -> MirrorKit.Scene {
        let data = Data(#"""
        {"version":2,"seq":1,"capturedAt":1,"source":"peek",
         "screen":{"w":640,"h":480},
         "apps":[{"psn":"0.3","name":"Finder","front":true}],
         "desktopItems":[
          {"name":"Macintosh HD","kind":"disk","x":500,"y":40,
           "placed":true,"alias":false,"invisible":false}],
         "windows":[
          {"id":"0.3/Extensions#0","app":"Finder","psn":"0.3",
           "title":"Extensions","rect":{"l":0,"t":0,"r":300,"b":200},
           "front":true,"z":0,"visible":true,"controls":[],
           "ref":"ext-ref","items":[
            {"name":"AppleShare","kind":"file","type":"INIT",
             "creator":"schr","x":10,"y":10,"placed":true,"alias":false,
             "invisible":false}]},
          {"id":"0.3/Control Panels#0","app":"Finder","psn":"0.3",
           "title":"Control Panels","rect":{"l":0,"t":0,"r":300,"b":200},
           "front":false,"z":1,"visible":true,"controls":[],
           "ref":"panels-ref"}],
         "meta":{"errors":[]}}
        """#.utf8)
        return try JSONDecoder().decode(MirrorKit.Scene.self, from: data)
    }

    /// Two boundaries on the re-read, both deliberate. No scene is not
    /// evidence of absence, and a plan that names no window has nothing
    /// here to check — an element reference is not looked up, because a
    /// structural walk may publish a window without its controls and
    /// "absent" would then describe the walk rather than the machine.
    func testTheRereadRefusesOnlyWhatItCanActuallySee() throws {
        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .windowAct(ref: "now-window-1", act: .close), in: nil))

        let scene = try fixtureScene()
        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .controlPart(ref: "now-element-1", part: 10, mods: 0),
            in: scene))
        XCTAssertNil(NOWMirrorSource.staleTargetComplaint(
            for: .keystroke(code: 36, char: 13, mods: 0), in: scene))
    }

    /// The line that holds the lane. A dispatched attempt waits for
    /// observation; a refusal waits only when this side cannot say the act
    /// never left.
    func testOnlyAProvablyUnsentRefusalStopsTheLaneWaiting() {
        XCTAssertTrue(NOWMirrorSource.effectMayHaveLanded(
            complaint: nil, reach: .notSent),
            "a successful dispatch settles from a later scene, whatever a "
                + "stale reach field says")
        XCTAssertTrue(NOWMirrorSource.effectMayHaveLanded(
            complaint: "act-timeout: armed, and nothing called it",
            reach: .unknown))
        XCTAssertFalse(NOWMirrorSource.effectMayHaveLanded(
            complaint: "element-not-found: nothing in this process answers "
                + "to that name any more",
            reach: .notSent))
    }

    /// **The guard is reached, not merely present.**
    ///
    /// The re-read is covered above as a function and watched to fail by
    /// mutation, but a function nobody calls passes its own tests — and
    /// the rule this replaces lived in exactly such an uncalled-looking
    /// place. So this drives a real source over a scene from the machine
    /// and clicks a window that scene does not carry.
    ///
    /// It exercises the direct path, which is the one this fixture can
    /// reach: with no incarnations in it, no window has a stable identity
    /// and nothing brokered can be planned from it. The brokered path's
    /// own call site is exercised only by hand so far — see
    /// docs/open-issues.md.
    func testAStaleClickIsAnsweredWithoutTouchingTheActLane() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        try await waitUntil("the guest is the active Mac") {
            listener.activeKey != nil
        }
        let key = try XCTUnwrap(listener.activeKey)
        let harness = MirrorCycleHarness(activeKey: key)
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let scene = try XCTUnwrap(source.scene)
        XCTAssertFalse(scene.windows.isEmpty,
                       "the fixture must carry windows or this asserts "
                           + "nothing about a window that is missing")

        let gone = MirrorObject.Window(
            id: "0.1/Gone#0",
            ref: "now-window-00000000-0000-4000-8000-000000000000",
            psn: scene.windows[0].psn, title: "Gone",
            rect: scene.windows[0].rect, kind: scene.windows[0].kind,
            isFront: false, part: .zoomBox)
        source.perform(.init(
            object: .window(gone),
            gesture: .click(count: 1, mods: 0, at: .init(x: 0, y: 0))))

        XCTAssertTrue(source.lastAct.contains("scene moved on"),
                      source.lastAct)
        XCTAssertEqual(source.actTimeline.records.count, 0,
                       "an act that was never sent has no timing to "
                           + "report, and reporting one would put a "
                           + "refusal this side raised into the machine's "
                           + "own measurements")
    }

    // MARK: - The brokered path, where the incident happened

    /// The captured fixture with identities added, so a brokered operation
    /// can be planned from it.
    ///
    /// The real guest sends `incarnation` on processes and windows and a
    /// `coverage` claim per scope; this fixture predates both, which is
    /// why every other test here exercises only the direct path. Rather
    /// than recapture (a guest and a person), the identities are stamped
    /// on deterministically — the values are opaque to everything under
    /// test, which only ever compares them for equality.
    /// **The incident, reproduced: a queued close whose window closes
    /// while it waits.**
    ///
    /// This is the sequence measured on 2026-08-05 at 02:04 and again,
    /// after the fix, at 03:09. Two closes of one window; the first holds
    /// the lane; a newer scene arrives without that window while the
    /// second is still queued; the second then dispatches into a machine
    /// where its target no longer exists.
    ///
    /// Before the fix it went to the guest, came back
    /// `element-not-found`, held the FIFO for the broker's full timeout,
    /// and was then recorded `confirmedAfterRefusal` — green, on the
    /// strength of a scene the FIRST close had produced. All three of
    /// those are asserted against here.
    func testAQueuedActWhoseWindowClosedIsRefusedRatherThanSent()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        try await waitUntil("the guest is the active Mac") {
            listener.activeKey != nil
        }
        let key = try XCTUnwrap(listener.activeKey)
        let harness = MirrorCycleHarness(activeKey: key)
        /* A guest that takes the act and never answers, which is what
           holds the lane here — the same thing a real slow Macintosh
           does, and the only honest way to have a second act still be
           QUEUED when a newer scene lands. The fake never installs a
           `winact` responder, so the act control's own bound is what
           ends it; a short one keeps the test in milliseconds. */
        let session = UUID()
        let act = AgentIntegrationActControl(
            listener: listener, currentSessionID: { session },
            commandTimeout: 0.3)
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: act, interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        // The scene a person is looking at, with the window still open.
        source.start()
        harness.completeScene(0, with: .success(
            sceneDelivery(try identifiedSceneDocument(seq: 1), seq: 1, for: key)))
        harness.joinCompletions[0](.init(
            scene: try XCTUnwrap(harness.joinedScenes.first),
            sentence: "content"))
        let engine = try XCTUnwrap(source.shadowEngine)
        let displayed = try XCTUnwrap(source.scene)
        let target = try XCTUnwrap(displayed.windows.first {
            $0.title == "System Folder"
        })

        // Two clicks on its close box, the second while the first is in
        // flight — which is what a person does to a mirror that lags.
        for _ in 0..<2 {
            source.perform(.init(
                object: .window(.init(
                    id: target.id, ref: target.ref, psn: target.psn,
                    title: target.title, rect: target.rect,
                    kind: target.kind, isFront: target.front,
                    part: .closeBox)),
                gesture: .click(count: 1, mods: 0,
                                at: .init(x: target.rect.l,
                                          y: target.rect.t))))
        }
        XCTAssertEqual(engine.operations.records.count, 2,
                       "both clicks must be planned as operations, or this "
                           + "test is about something else entirely")
        // Long enough for the first act's own bound to pass, so it is
        // waiting on EVIDENCE rather than on the socket.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(engine.operations.records.first?.outcome,
                       .awaitingEvidenceAfterRefusal,
                       "the first act must still hold the lane, or the "
                           + "second one never queues and this proves "
                           + "nothing about a queued act")

        // The machine moves on: a newer scene, without that window.
        source.planePolicyDidChange()          // the test's way to ask for one
        harness.completeScene(1, with: .success(sceneDelivery(
            try identifiedSceneDocument(seq: 2, without: "System Folder"),
            seq: 2, for: key)))
        harness.joinCompletions[1](.init(
            scene: try XCTUnwrap(harness.joinedScenes.last),
            sentence: "content"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let second = try XCTUnwrap(engine.operations.records.last)
        XCTAssertEqual(second.outcome, .refused,
                       "not awaitingEvidenceAfterRefusal, which is how a "
                           + "click that did nothing came to be confirmed "
                           + "by another click's effect")
        XCTAssertTrue(second.reason?.contains("scene moved on") == true,
                      second.reason ?? "(no reason)")
        XCTAssertEqual(source.actTimeline.records.filter {
            $0.operationID == second.id
        }.first?.outcome, .refused)
        XCTAssertNotEqual(second.outcome, .confirmedAfterRefusal,
                          "a refusal this side raised can never be "
                              + "confirmed by a later scene: nothing was "
                              + "sent for that scene to be evidence of")
        /* The FIRST act keeps waiting and may still settle, and that is
           the other half of the rule: it reached a guest that never
           answered, so whether it landed is not this side's to say. */
        XCTAssertEqual(engine.operations.records.first?.outcome,
                       .confirmedAfterRefusal)
    }

    /// Activation names a window too, and it is the same question.
    func testActivationIsRereadLikeAnyOtherWindowAct() throws {
        let scene = try fixtureScene()
        XCTAssertEqual(
            NOWMirrorSource.windowReference(
                in: .activateWindow(psn: "0.1", ref: "now-window-9")),
            "now-window-9")
        XCTAssertNotNil(NOWMirrorSource.staleTargetComplaint(
            for: .activateWindow(psn: "0.1", ref: "now-window-9"),
            in: scene))
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

    func testFinderRosterScriptRequestsOneBoundedPageAndTotal() {
        let script = NOWMirrorSource.iconItemsScript(
            container: "window \"Control Panels\"", offset: 16, limit: 8)

        XCTAssertTrue(script.contains("set out to \"N\" & tab & totalCount"))
        XCTAssertTrue(script.contains("set firstIndex to 17"))
        XCTAssertTrue(script.contains("set lastIndex to 24"))
        XCTAssertTrue(script.contains("repeat with i from firstIndex to lastIndex"))
        XCTAssertFalse(script.contains("repeat with i from 1 to (count ns)"),
                       "one unbounded result can exceed the guest's 1 KiB cap")
    }

    func testLaterFinderPageKeepsDateAndTimeNameAndHitTarget() throws {
        let page = "\"N\t33\r"
            + "I\tDate & Time\t184\t221\tcontrol panel\r"
            + "I\tEnergy Saver\t280\t221\tcontrol panel\r\""

        XCTAssertEqual(NOWMirrorSource.iconPageTotal(page), 33)
        let parsed = NOWMirrorSource.parseIcons(page)
        let dateAndTime = try XCTUnwrap(parsed.first {
            $0.name == "Date & Time"
        })
        XCTAssertEqual(dateAndTime.x, 184)
        XCTAssertEqual(dateAndTime.y, 221)
        XCTAssertTrue(dateAndTime.placed,
                      "the bitmap may be absent; the named hit target may not")
    }

    func testVisibilityCensusIsBoundedAndKeepsFalseDistinctFromUnknown() {
        let script = NOWMirrorSource.visibilityScript(offset: 8, limit: 8)
        XCTAssertTrue(script.contains("set firstIndex to 9"))
        XCTAssertTrue(script.contains("set lastIndex to 16"))
        XCTAssertTrue(script.contains(
            "repeat with i from firstIndex to lastIndex"))

        let parsed = NOWMirrorSource.parseVisibility(
            "\"N\t2\rV\tFinder\tfalse\rV\tNew Old World\ttrue\r\"")
        XCTAssertEqual(parsed.total, 2)
        XCTAssertEqual(parsed.rowCount, 2)
        XCTAssertEqual(parsed.byName["Finder"], false)
        XCTAssertEqual(parsed.byName["New Old World"], true)
        XCTAssertTrue(parsed.unique)
    }

    /// The same "AppleScript fails a script WHOLE" family as the Finder art
    /// pass below, in the one place whose failure was silent. Reading
    /// `visible of candidate` straight into a `&` chain does not yield the
    /// boolean: the Finder returns an object specifier and the concatenation
    /// raises `-1700 Can't make visible of «class prcs» "tbt-worker" of
    /// application "Finder" into a string` — measured on Mac OS 9.1 (mac99,
    /// 2026-08-05), where it aborted the script before its first row. The
    /// census then delivered NOTHING, so `enrichVisibility` matched no name,
    /// every process read `visible: null`, and the coverage claim blamed
    /// name ambiguity. Bind the property first; a bound value coerces.
    func testVisibilityCensusBindsTheBooleanBeforeConcatenatingIt() {
        let script = NOWMirrorSource.visibilityScript(offset: 0)

        XCTAssertTrue(script.contains("set vis to visible of candidate"),
                      "the property must resolve into a variable first")
        XCTAssertTrue(script.contains("(vis as string)"),
                      "the bound boolean is what gets coerced")
        XCTAssertFalse(script.contains("(visible of candidate)"),
                       "an inline read is the specifier that raises -1700 "
                       + "and takes the whole census down with it")
    }

    /// The bytes Mac OS 9.1 actually returned for the corrected script
    /// (mac99, 2026-08-05), verbatim including the `\r` row endings and the
    /// SOURCE-form quotes. A census this side cannot parse is a census that
    /// settles nothing, and the fixture is the machine's own answer rather
    /// than one this test invented.
    func testVisibilityCensusParsesWhatMacOS9Answered() {
        let measured = "\"N\t7\r"
            + "V\tControl Strip Extension\tfalse\r"
            + "V\tDVD AutoLauncher\tfalse\r"
            + "V\tFBC Indexing Scheduler\tfalse\r"
            + "V\tFolder Actions\tfalse\r"
            + "V\ttbt-appe\tfalse\r"
            + "V\ttbt-worker\tfalse\r"
            + "V\tNew Old World\ttrue\r\""
        let parsed = NOWMirrorSource.parseVisibility(measured)

        XCTAssertEqual(parsed.total, 7)
        XCTAssertEqual(parsed.rowCount, 7)
        XCTAssertTrue(parsed.unique)
        XCTAssertEqual(parsed.byName["New Old World"], true)
        XCTAssertEqual(parsed.byName["tbt-worker"], false)
        XCTAssertNil(parsed.byName["Finder"],
                     "the Finder is absent from its own process list - "
                     + "measured `count of (every process whose name is "
                     + "\"Finder\")` = 0 on the same machine")
    }

    /// A guest that raises answers `ok: true` with an empty output row, so
    /// only `osaErr` distinguishes a refusal from an empty answer. An older
    /// guest omits the row entirely, and that silence must not be promoted
    /// into a failure it never reported.
    func testOnlyAReportedNonZeroOSACodeCountsAsAFailure() {
        XCTAssertTrue(NOWMirrorSource.isOSAFailure("-1753"))
        XCTAssertTrue(NOWMirrorSource.isOSAFailure(" -1700 "))
        XCTAssertFalse(NOWMirrorSource.isOSAFailure("0"))
        XCTAssertFalse(NOWMirrorSource.isOSAFailure(""),
                       "a guest that reports no code reported no failure")
        XCTAssertFalse(NOWMirrorSource.isOSAFailure("nonsense"))
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
