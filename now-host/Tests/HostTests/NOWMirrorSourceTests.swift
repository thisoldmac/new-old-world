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

    private final class PlanePolicyBox {
        var value: Set<MirrorPlaneID>
        init(_ value: Set<MirrorPlaneID>) { self.value = value }
    }

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

    func testFrontFinderWindowIsEnrichedBeforeBackgroundWindows() throws {
        var scene = try fixtureScene()
        var background = try XCTUnwrap(scene.windows.first {
            $0.app == "Finder" && $0.title != "Desktop"
        })
        var front = background
        background.title = "Background Folder"
        background.front = false
        front.title = "Front Folder"
        front.front = true
        scene.windows = [background, front]

        XCTAssertEqual(
            NOWMirrorSource.prioritizedFinderWindows(scene).map(\.title),
            ["Front Folder", "Background Folder"],
            "a slow background read must not hold the visible interior blank")
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
        let planes = PlanePolicyBox(Set(MirrorPlaneID.allCases))
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: testAct(listener), interval: 3_600,
            planePolicy: { _ in planes.value },
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1)

        planes.value.remove(.semantics)
        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "a held scene still owns the cycle")

        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        XCTAssertEqual(harness.joinedScenes.count, 1)
        planes.value.insert(.semantics)
        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "content completion is part of the same cycle")

        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined,
                                         sentence: "content held then done"))
        XCTAssertEqual(harness.sceneRequests.count, 2,
                       "all toggles coalesce into one follow-up scene")
    }

    // MARK: - What each surface arms on the Macintosh

    /// **Indexed through XCTUnwrap, because the mutation these tests are
    /// written against is "the request never went out".**
    ///
    /// Subscripting the harness for a request a mutation suppressed is a
    /// fatal index crash, and a crashed test process reports nothing about
    /// the rest of the run — a mutation that reads as a silent green
    /// elsewhere is exactly the failure mode this project has already paid
    /// for once.
    private func sceneRequest(_ index: Int, of harness: MirrorCycleHarness)
        throws -> (GuestKey, Bool, Bool) {
        try XCTUnwrap(harness.sceneRequests.indices.contains(index)
                      ? harness.sceneRequests[index] : nil,
                      "scene request #\(index) was never made")
    }

    private func completeScene(_ index: Int, of harness: MirrorCycleHarness,
                               for key: GuestKey) throws {
        _ = try sceneRequest(index, of: harness)
        harness.completeScene(index,
                              with: .success(try fixtureDelivery(for: key)))
    }

    /* The two mode-narrowing gates that lived here
       (testContinuityArmsOnlyTheStructuralPlane,
       testReturningToMirrorRearmsEveryPolicyPlane) died with Continuity
       Mode itself: screen-edge Continuity is its own module and arms no
       Mirror planes at all - its guest intake claims its one plane on its
       own wire. The cost they guarded against (planes paid for by the
       Macintosh and read by nobody) is now impossible by construction
       rather than enforced by intersection. The policy CEILING is still
       gated below. */

    /// **Policy is the ceiling.** The Mirror may never ask for a plane a
    /// person or the guest has refused, whatever it would like to render.
    /// (The other direction - a mode narrowing below policy - died with
    /// Continuity Mode; the module arms no Mirror planes at all.)
    func testTheArmedSetNeverExceedsPolicy() throws {
        let key = GuestKey.synthetic("armed-intersection")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let planes = PlanePolicyBox([.structure, .content])
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            planePolicy: { _ in planes.value },
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)
        defer { source.stop() }

        source.start()
        let narrowed = try sceneRequest(0, of: harness)
        XCTAssertFalse(narrowed.1, "Mirror may not widen the walk past policy")
        XCTAssertFalse(narrowed.2,
                       "Mirror may not arm the act plane past policy")
        try completeScene(0, of: harness, for: key)
        XCTAssertEqual(harness.joinedScenes.count, 1,
                       "content is allowed here, and Mirror reads it")
        harness.completeJoin(0)
    }

    /* testContinuityEndsTheTransitionTailItNoLongerReads is gone with the
       mode: no mode change hands the P5 tail back anymore, because
       Continuity never borrows the Mirror's planes. The tail still ends
       with the Mirror stopping, which its own lifecycle tests cover. */

    /// **THE CADENCE INVARIANT: a slow Finder may not slow the scene.**
    ///
    /// The anchor plane's owner lease is 600 ticks — ten seconds — and the
    /// only thing that renews it is a `scene.request`. So the poll's
    /// period is not a comfort setting: go quieter than the lease and
    /// every plane lapses between cycles, and every act that needs an
    /// anchor refuses `element-not-found: the anchor plane is absent or
    /// not armed`.
    ///
    /// It happened. Measured 2026-08-06 on the live session, guest build
    /// `711abdbd25ec`: the Finder complements ran INSIDE the structural
    /// cycle and held it open, so with a modal up starving the Finder the
    /// cycle's period went to 12.6 s. The log reads `requested=15
    /// active=8`, and Cancel on that modal refused five times running.
    ///
    /// This is that shape as a test. Both complements are given overrides
    /// that NEVER answer — the starved Finder, exactly — and the cycle
    /// must still close, publish, and let the next scene request go out.
    /// Put `refreshComplements` back inside the cycle and this hangs at
    /// one request, which is what the machine did.
    func testAStarvedFinderCannotHoldTheSceneCycleOpen() throws {
        let key = GuestKey.synthetic("starved-finder")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, _ in },
            visibilityRefreshOverride: { _, _, _ in },
            cycleIO: harness.io)

        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1)

        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined,
                                         sentence: "content joined"))

        XCTAssertEqual(source.cycleTimeline.records.count, 1,
                       "the cycle must be measured and closed once the "
                       + "scene is published — not when the Finder gets "
                       + "round to answering")
        source.planePolicyDidChange()
        XCTAssertEqual(harness.sceneRequests.count, 2,
                       "and the next scene request must go out, because it "
                       + "is the only thing that renews the anchor plane's "
                       + "ten-second lease")
    }

    /// Cancellation cannot recall the Apple event already inside the guest,
    /// but it must stop the multi-pass roster from sending another one after
    /// that reply arrives. Otherwise a stopped or replaced Mirror keeps
    /// querying whichever Mac the listener selects next.
    func testStoppingDuringAFinderReadSendsNoFollowUpScript() async throws {
        let key = GuestKey.synthetic("held-finder-read")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        var scripts = 0
        var firstArgs: [String: CommandArg]?
        var held: ((CommandResult) -> Void)?
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io,
            sendCommand: { verb, args, completion in
                guard verb == "script" else { return }
                scripts += 1
                if firstArgs == nil { firstArgs = args }
                held = completion
            })

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined, sentence: "joined"))

        for _ in 0..<20 where held == nil { await Task.yield() }
        let firstReply = try XCTUnwrap(held, "the desktop roster never began")
        XCTAssertEqual(scripts, 1)
        XCTAssertEqual(firstArgs?["purpose"],
                       .text("mirror-finder-complement"),
                       "automatic Finder work must be distinguishable from "
                       + "a deliberate Script command on the guest")
        XCTAssertEqual(firstArgs?["timeout"],
                       .number(NOWMirrorSource.finderSliceTimeoutMs),
                       "an automatic Finder page must never inherit the "
                       + "guest's generic 15-second script ceiling")

        source.stop()
        firstReply(.init(
            id: 1, ok: true,
            output: ["script": [["output", "\"N\\t0\\r\""],
                                ["osaErr", "0"],
                                ["truncated", "false"]]],
            error: nil))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(scripts, 1,
                       "a canceled roster sent its type/art pass after Stop")
    }

    func testGuestPolicyCanSuppressFinderComplementsBeforeAnyScript() throws {
        let key = GuestKey.synthetic("finder-policy-off")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        var complementStarted = false
        var scripts = 0
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderComplementPolicy: { _ in false },
            finderRefreshOverride: { _, _, _ in complementStarted = true },
            visibilityRefreshOverride: { _, _, _ in complementStarted = true },
            cycleIO: harness.io,
            sendCommand: { verb, _, _ in
                if verb == "script" { scripts += 1 }
            })

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        harness.completeJoin(0)

        XCTAssertFalse(complementStarted)
        XCTAssertEqual(scripts, 0)
    }

    /// The other half of the same repair, and the reason it is safe.
    ///
    /// The cycle-hold was buying one real thing: a Finder roster read for
    /// one layout could never land on a different one — a roster carries
    /// window-content-local, scroll-compensated positions, so applying a
    /// stale one puts a click on the wrong file. The bracket now records
    /// its own split so the next person reads where the time went instead
    /// of deriving it from a field called `decode`.
    func testTheCycleLineSplitsItsOwnWorkFromTheGuestsRoundTrip() throws {
        let key = GuestKey.synthetic("cycle-split")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined, sentence: "joined"))

        let record = try XCTUnwrap(source.cycleTimeline.records.first)
        XCTAssertNotNil(record.ownWork,
                        "decode/reduce/project must be measured separately: "
                        + "12,457ms once read as `decode_ms` and cost an "
                        + "evening aimed at a JSON parser that takes 4ms")
        XCTAssertNotNil(record.contentJoin)
        XCTAssertTrue(record.baselineLine.contains("dc_own_ms="),
                      record.baselineLine)
        XCTAssertTrue(record.baselineLine.contains("dc_content_ms="),
                      record.baselineLine)
    }

    /// **A REGRESSION BOUND ON THE CYCLE, in time and on a real
    /// document.**
    ///
    /// `MirrorDecodeCostTests` bounds this host's own CPU — 4 ms for the
    /// six-window scene — which is the half that was never the problem.
    /// This bounds the thing a person actually experiences: delivery to
    /// publish, with complements that take as long as the Finder really
    /// does. Each override sleeps 400 ms, which is what the live census
    /// measured at on a HEALTHY guest on 2026-08-06 (`dc_vis_ms` median
    /// 338, p90 401); the roster measured 1.3–1.6 s.
    ///
    /// The bound is 1 s against ~800 ms of deliberate Finder time, so it
    /// passes only while the complements are OUTSIDE the cycle. Put them
    /// back inside and it fails by the whole of that 800 ms — and on a
    /// starved machine, by the twelve seconds that started this.
    func testTheCycleIsBoundedEvenWhenTheFinderIsSlow() throws {
        let key = GuestKey.synthetic("cycle-bound")
        let harness = MirrorCycleHarness(activeKey: key)
        let slow: @MainActor (MirrorKit.Scene, Int, @escaping () -> Void)
            -> Void = { _, _, completion in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                completion()
            }
        }
        let source = NOWMirrorSource(
            listener: testListener(), engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(testListener()), interval: 3_600,
            finderRefreshOverride: slow, visibilityRefreshOverride: slow,
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined, sentence: "joined"))

        /* Waited for rather than read straight off, so the assertion that
           fails is the one about TIME. Reading it immediately would fail
           with "nil" the moment the complements moved back inside the
           cycle, which is a true failure that names the wrong thing. */
        let deadline = Date().addingTimeInterval(3)
        while source.cycleTimeline.records.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let record = try XCTUnwrap(
            source.cycleTimeline.records.first,
            "no cycle was recorded within three seconds of the scene being "
            + "published — the cycle is waiting on the Finder again")
        XCTAssertLessThan(
            record.total, 1.0,
            "the cycle took \(Int(record.total * 1000))ms with 800ms of "
            + "Finder work beside it. A cycle that waits for the Finder "
            + "lapses the guest's ten-second plane lease, and every act "
            + "needing an anchor then refuses element-not-found.")
    }

    /// **A frame published without its icons must SAY so.**
    ///
    /// The cycle no longer waits for the Finder roster, which means a
    /// folder window can be drawn before anyone has asked what is in it —
    /// and a window with no items reads as an empty folder rather than as
    /// an unanswered question. `meta.coverage` already carries typed
    /// status with a reason for `process-visibility`; `finder-items` uses
    /// the same words, and the status line says it in English.
    func testAFramePublishedBeforeItsIconsSaysTheyAreMissing() throws {
        let key = GuestKey.synthetic("icons-pending")
        let harness = MirrorCycleHarness(activeKey: key)
        let registry = MirrorStateEngineRegistry()
        let source = NOWMirrorSource(
            listener: testListener(), engineRegistry: registry,
            act: testAct(testListener()), interval: 3_600,
            /* Never answers: the roster is still in flight, which is the
               state this claim exists to describe. */
            finderRefreshOverride: { _, _, _ in },
            visibilityRefreshOverride: { _, _, _ in },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        let joined = try XCTUnwrap(harness.joinedScenes.first)
        harness.joinCompletions[0](.init(scene: joined, sentence: "joined"))

        let coverage = try XCTUnwrap(
            registry.engine(for: key).snapshot?.scene.meta.coverage)
        let claim = try XCTUnwrap(
            coverage.first { $0.scope == "finder-items" },
            "a frame published without its roster carries no claim at all; "
            + "absence with nothing said about it is the omission this "
            + "plan calls a fast lie")
        XCTAssertNotEqual(claim.status, .complete)
        XCTAssertNotNil(claim.reason,
                        "a typed status with no reason cannot be acted on")
        XCTAssertTrue(
            NOWMirrorSource.observationPhrase(1, replica: nil,
                                              coverage: coverage)
                .contains("awaiting icons"),
            "the one line a person reads has to carry it too")
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

    /// Stop is an end, not a pause. The last frame and the measurements
    /// that described its session must not remain available to a later run.
    func testStopEndsTheSessionAndClearsItsPublishedState() throws {
        let key = GuestKey.synthetic("stopped-session")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let registry = MirrorStateEngineRegistry()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        harness.completeJoin(0)
        XCTAssertNotNil(source.scene)
        XCTAssertEqual(source.cycleTimeline.records.count, 1)
        XCTAssertNotNil(registry.existing(for: key))

        source.stop()

        XCTAssertFalse(source.running)
        XCTAssertNil(source.pinnedGuestKey)
        XCTAssertNil(source.scene,
                     "a stopped Mirror publishes not-fetched, not the last frame")
        XCTAssertTrue(source.cycleTimeline.records.isEmpty,
                      "a later reproduction must not inherit old timings")
        XCTAssertTrue(source.actTimeline.records.isEmpty)
        XCTAssertEqual(source.actTimeline.depth, 0)
        XCTAssertNil(registry.existing(for: key),
                     "a later start must build a fresh session engine")
    }

    /// A lost wire ends the run immediately, but does not erase the person's
    /// persisted request to run. A successor connection starts from nothing.
    func testDisconnectEndsTheSessionAndReconnectStartsFresh() throws {
        let old = GuestKey.synthetic("disconnected-session")
        let next = GuestKey.synthetic("reconnected-session")
        let harness = MirrorCycleHarness(activeKey: old)
        let listener = testListener()
        let registry = MirrorStateEngineRegistry()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)
        let suiteName = "test.mirror.disconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let run = MirrorRunControl(source: source, defaults: defaults)

        run.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: old)))
        harness.completeJoin(0)
        XCTAssertNotNil(source.scene)

        harness.activeKey = nil
        run.activeGuestDidChange()

        XCTAssertTrue(run.wantsRunning,
                      "a dropped wire is not the person's Stop decision")
        XCTAssertFalse(source.running)
        XCTAssertNil(source.scene)
        XCTAssertNil(registry.existing(for: old))

        harness.activeKey = next
        run.activeGuestDidChange()

        XCTAssertTrue(source.running)
        XCTAssertEqual(source.pinnedGuestKey, next)
        XCTAssertNil(source.scene,
                     "the replacement has not published a frame yet")
        XCTAssertNil(registry.existing(for: old))
        XCTAssertNotNil(registry.existing(for: next))
    }

    /// Selecting another live guest is a replacement without an intervening
    /// nil connection. It must still cross the same teardown boundary.
    func testGuestReplacementStartsANewSessionWithoutOldState() throws {
        let old = GuestKey.synthetic("outgoing-guest")
        let next = GuestKey.synthetic("incoming-guest")
        let harness = MirrorCycleHarness(activeKey: old)
        let listener = testListener()
        let registry = MirrorStateEngineRegistry()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)
        let suiteName = "test.mirror.replacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let run = MirrorRunControl(source: source, defaults: defaults)

        run.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: old)))
        harness.completeJoin(0)
        harness.holdContentRelease = true

        run.activeGuestWillChange()
        XCTAssertFalse(source.running)
        XCTAssertEqual(harness.contentReleaseCompletions.count, 1,
                       "the outgoing guest gets an explicit content stop")
        harness.activeKey = next

        run.activeGuestDidChange()

        XCTAssertTrue(source.running)
        XCTAssertEqual(source.pinnedGuestKey, next)
        XCTAssertNil(source.scene)
        XCTAssertNil(registry.existing(for: old))
        XCTAssertNotNil(registry.existing(for: next))

        harness.completeScene(1, with: .success(try fixtureDelivery(for: next)))
        harness.completeJoin(1)
        let replacementScene = source.scene
        harness.contentReleaseCompletions[0]("late outgoing refusal")

        XCTAssertTrue(source.running)
        XCTAssertEqual(source.scene, replacementScene,
                       "the old release cannot clear the replacement")
        XCTAssertFalse(source.ambient.contains("late outgoing refusal"),
                       "the old release cannot relabel the replacement")
    }

    func testDelayedStopReleaseCannotChangeAnImmediateRestart() throws {
        let key = GuestKey.synthetic("stop-start-release")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        harness.completeJoin(0)
        harness.holdContentRelease = true

        source.stop()
        source.start()
        harness.completeScene(1, with: .success(try fixtureDelivery(for: key)))
        harness.completeJoin(1)
        let restartedScene = source.scene

        harness.contentReleaseCompletions[0]("late stop refusal")

        XCTAssertTrue(source.running)
        XCTAssertEqual(source.scene, restartedScene)
        XCTAssertFalse(source.ambient.contains("late stop refusal"))
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

    /// **A selection wants the Finder in front; an open does not always.**
    /// `activate` runs after the phrase, so an open that raises a NEW
    /// application's window is covered by the Finder the instant it
    /// appears — measured on a live machine 2026-08-05: control panels
    /// "open quickly, but still immediately push them behind Finder".
    func testTheFinderComesForwardForASelectionAndNotOverANewApplication() {
        let select = NOWMirrorSource.finderScript(
            "select item \"Macintosh HD\" of desktop")
        XCTAssertTrue(select.contains("select item \"Macintosh HD\""))
        XCTAssertTrue(select.contains("tell application \"Finder\""))
        XCTAssertTrue(select.hasSuffix("activate\nend tell"),
                      "a selection nobody can see is not a selection — and "
                          + "the line must be `activate` exactly, on its own")

        let ownApp = NOWMirrorSource.finderScript(
            "open item \"Date & Time\" of folder \"Control Panels\"",
            activate: false)
        XCTAssertFalse(ownApp.contains("activate"),
                       "the panel that just opened must stay in front")
        XCTAssertTrue(ownApp.contains("open item \"Date & Time\""))
        XCTAssertTrue(ownApp.hasSuffix("end tell"),
                      "dropping activate must not leave a dangling line")
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

    func testOnlyAReadBackShownCountsAsAShow() {
        XCTAssertNil(NOWMirrorSource.showDispatchOutcome("\"shown\""))
        XCTAssertNotNil(NOWMirrorSource.showDispatchOutcome("\"unconfirmed\""))
        XCTAssertNotNil(NOWMirrorSource.showDispatchOutcome(nil))
    }

    func testIconArtPassIsBoundedAndPaged() {
        let script = NOWMirrorSource.iconTypesScript(
            container: "desktop", offset: 8, limit: 8)
        XCTAssertTrue(script.contains("set firstIndex to 9"))
        XCTAssertTrue(script.contains("set lastIndex to 16"))
        XCTAssertTrue(script.contains("set totalCount to count fs"))
        XCTAssertFalse(script.contains("repeat with i from 1 to (count"))
    }

    func testDesktopCacheKeyDoesNotOscillateWithEnrichment() throws {
        var a = try fixtureScene()
        var b = a
        a.desktopItems = nil
        b.desktopItems = [.init(name: "Macintosh HD", kind: "disk",
                                type: nil, creator: nil, x: 10, y: 10,
                                placed: true, alias: false, invisible: false)]
        XCTAssertEqual(NOWMirrorSource.desktopIconLayoutKey(a),
                       NOWMirrorSource.desktopIconLayoutKey(b))
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

        let bulk = NOWMirrorSource.staleTargetComplaint(
            for: .finderSetSelection(
                items: ["Macintosh HD", "Date & Time"], container: .desktop),
            in: scene)
        XCTAssertEqual(bulk, "the Finder shows no item named Date & Time "
                          + "on the desktop, so the act was not sent. "
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
        let finderSuite = "NOWMirrorSourceTests.\(UUID().uuidString)"
        let finderDefaults = try XCTUnwrap(UserDefaults(suiteName: finderSuite))
        defer { finderDefaults.removePersistentDomain(forName: finderSuite) }
        finderDefaults.set(false, forKey: HostFinderSession.preferenceKey)
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: act, interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io, hostFinderDefaults: finderDefaults)

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

    /// **A cycle that failed must say WHICH failure, and must not carry
    /// the last good cycle's counts.**
    ///
    /// Measured on the live PowerBook on 2026-08-07:
    /// `mirror_read --intention metrics` returned 24 cycles, 14 of them
    /// `outcome: "failed", requestMs: 0, totalMs: 0` — and each of those
    /// 14 also carried a window and an element count, because the last
    /// PROVEN scene deliberately stands through a failure and the record
    /// read its counts off it. Two defects in one row: the word `failed`
    /// is a bucket holding at least five distinct conditions whose
    /// distinguishing sentence the host had already written and spent
    /// only on the window's status line, and the counts beside it
    /// described a different cycle.
    ///
    /// This drives both halves through the real source: one good cycle to
    /// establish a standing scene, then a failed one, then the projection
    /// the agent socket actually serves.
    func testAFailedCycleCarriesItsOwnReasonAndNoOtherCyclesCounts() throws {
        let key = GuestKey.synthetic("cycle-reason")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io)

        source.start()
        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        harness.completeJoin(0)

        let good = try XCTUnwrap(source.cycleTimeline.records.first)
        XCTAssertEqual(good.outcome, "ok")
        let seenWindows = try XCTUnwrap(good.windows)
        XCTAssertGreaterThan(seenWindows, 0,
                             "the good cycle must really have counted "
                             + "something, or the next assertion is vacuous")
        XCTAssertNil(good.reason, "an `ok` cycle has nothing to explain")

        /* The exact local refusal that produced the live reading: the lane
           answers synchronously, so every clock is zero and the word
           `failed` is all that is left of it. */
        let refusal = "A scene is already on its way. "
            + "Ask again when it arrives."
        source.planePolicyDidChange()
        harness.completeScene(1, with: .failure(.init(message: refusal)))

        let bad = try XCTUnwrap(source.cycleTimeline.records.last)
        XCTAssertEqual(bad.outcome, "failed")
        XCTAssertEqual(bad.reason, refusal,
                       "the sentence the host already wrote must ride "
                       + "beside the bucket word, verbatim")
        XCTAssertNil(bad.windows,
                     "the standing scene belongs to the cycle that proved "
                     + "it; this one published nothing and counted nothing")
        XCTAssertNil(bad.elements)

        /* And the same two facts through the projection the agent reads,
           because a value that survives to the record and dies at the
           socket is the defect this test was written for. */
        let metrics = source.actTimeline.projected(
            cycles: source.cycleTimeline, running: true)
        let projected = try XCTUnwrap(metrics.cycles.last)
        XCTAssertEqual(projected.outcome, "failed")
        XCTAssertEqual(projected.reason, refusal)
        XCTAssertNil(projected.windows)
        XCTAssertNil(projected.elements)
        XCTAssertEqual(metrics.cycles.first?.outcome, "ok")
        XCTAssertNil(metrics.cycles.first?.reason)

        /* The wire is JSON, and a field that is not encoded is a field
           that did not survive. */
        let encoded = try XCTUnwrap(String(
            data: try JSONEncoder().encode(projected), encoding: .utf8))
        XCTAssertTrue(encoded.contains("already on its way"), encoded)
    }

    func testInvalidationsCoalesceIntoOneFollowUpScene() throws {
        let key = GuestKey.synthetic("invalidation-follow-up")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        var commands: [(String, [String: CommandArg]?)] = []
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            finderRefreshOverride: { _, _, completion in completion() },
            visibilityRefreshOverride: { _, _, completion in completion() },
            cycleIO: harness.io,
            transitionInvalidation: true,
            sendCommand: { verb, args, completion in
                commands.append((verb, args))
                completion(.init(id: 1, ok: true))
            })
        source.start()
        XCTAssertEqual(harness.sceneRequests.count, 1)

        let first = MirrorInvalidate(
            session: "1", generation: 2,
            domains: .init(structure: 2), quality: .sampled,
            lost: 0, source: .transitions)
        listener.events.publish(.mirrorInvalidated(key, first))
        listener.events.publish(.mirrorInvalidated(key, first))
        listener.events.publish(.mirrorInvalidated(
            GuestKey.synthetic("another-mac"), first))
        XCTAssertEqual(harness.sceneRequests.count, 1,
                       "an active observation is never overlapped")

        harness.completeScene(0, with: .success(try fixtureDelivery(for: key)))
        XCTAssertEqual(commands.first?.0, "transitions")
        XCTAssertEqual(commands.first?.1?["op"], .text("start"))
        XCTAssertNotNil(commands.first?.1?["serialLo"],
                        "the sampled process is addressed by exact PSN")
        XCTAssertEqual(commands.first?.1?["ttlTicks"], .number(36_000),
                       "resident sampling remains leased, never always-on")
        harness.completeJoin(0)
        XCTAssertEqual(harness.sceneRequests.count, 2,
                       "newest matching generation earns one prompt repair")
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

    /// **What an alias points at, which its own fields never say.**
    /// Measured on the emulator 2026-08-07: the desktop's `Mail` is an
    /// alias whose original is an `APPL` named `Mail`, and opening it
    /// puts a process named `Mail` at the front. Without this join every
    /// alias was unclassifiable and opening one predicted a Finder window
    /// that no Finder ever makes — the 18-second false negative sweep A
    /// priced.
    func testAnAliasCarriesWhatItPointsAt() {
        let items = NOWMirrorSource.parseIcons(sample)
        let targets = Dictionary(
            NOWMirrorSource.parseAliasTargets(
                "\"A\tBrowse the Internet\tBrowse the Internet\t"
                + "«class APPL»\t«class aplt»\tapplication program\r"
                + "A\tFrom Claude.txt\tGone\t«class APPL»\t«class aplt»\t"
                + "application program\r\""),
            uniquingKeysWith: { first, _ in first })
        let joined = NOWMirrorSource.applyingArt(items, types: [:],
                                                 aliasTargets: targets)

        let alias = joined.first { $0.name == "Browse the Internet" }
        XCTAssertEqual(alias?.aliasTarget?.name, "Browse the Internet")
        XCTAssertEqual(alias?.aliasTarget?.type, "APPL")
        XCTAssertEqual(alias?.aliasTarget?.kind, "application")

        /* A row for a name the ROSTER did not call an alias is not
           joined: the two passes are separate scripts and a name
           collision must not hand a document a target. */
        XCTAssertNil(joined.first { $0.name == "From Claude.txt" }?
            .aliasTarget)
        /* An alias the pass could not resolve stays unresolved rather
           than acquiring a guess - `try` drops its row and nothing else
           invents one. */
        XCTAssertNil(joined.first { $0.name == "Trash" }?.aliasTarget)
    }

    /// The alias pass wraps every resolution, because `original item`
    /// raises for a broken alias and AppleScript fails a script whole.
    func testTheAliasScriptSurvivesOneBrokenAlias() {
        let script = NOWMirrorSource.aliasTargetsScript(container: "desktop")
        XCTAssertTrue(script.contains("every alias file of desktop"))
        XCTAssertTrue(script.contains("try"),
                      "one stale alias must not cost the whole pass")
        XCTAssertTrue(script.contains("original item of a"))
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

    /// **The list-view defect, at the one line that caused it.** `position of`
    /// is the Finder's live layout in an icon view and the SAVED icon grid in
    /// a list view, and this script could not tell which it was reading. It
    /// asks for the box the Finder drew instead — measured 2026-08-07 on
    /// mac99 / OS 9.1 beside a screendump.
    func testFinderRosterScriptAsksForTheBoxAndNotTheSavedGrid() {
        let script = NOWMirrorSource.iconItemsScript(
            container: "window \"Macintosh HD\"", offset: 0, limit: 8)

        XCTAssertTrue(script.contains("set ps to bounds of every item"))
        XCTAssertFalse(script.contains("position of"),
                       "in a list view `position` answers a three-column icon "
                       + "grid the window is not drawing, and every rect "
                       + "computed from it is a click on the wrong file")
        XCTAssertTrue(script.contains("(item 3 of p)"), "the box's right edge")
        XCTAssertTrue(script.contains("(item 4 of p)"), "and its bottom")
        XCTAssertTrue(script.contains("set viewWord to view of"))
        XCTAssertTrue(script.contains("set containerPath to (item of"))
        XCTAssertTrue(script.contains("name of every item of selection"))
        XCTAssertFalse(script.lowercased().contains("activate"),
                       "an observe-only complement must not front Finder")
        XCTAssertFalse(script.lowercased().contains("entire contents"),
                       "whole-disk browsing is bounded navigation, not search")
    }

    func testFinderPageCarriesWholeDiskPathViewAndSelection() {
        let page = "\"N\t2\rV\tname\r"
            + "P\tMacintosh HD:System Folder:\r"
            + "I\tExtensions\t22\t43\t38\t59\tfolder\ttrue\r"
            + "I\tFinder\t22\t62\t38\t78\tapplication\tfalse\r\""

        let metadata = NOWMirrorSource.finderPageMetadata(page)
        XCTAssertEqual(metadata.path, "Macintosh HD:System Folder:")
        XCTAssertEqual(metadata.view, .name)
        XCTAssertEqual(metadata.selectedNames, ["Extensions"])
        XCTAssertEqual(NOWMirrorSource.parseIcons(page).map(\.name),
                       ["Extensions", "Finder"])
    }

    func testFinderPageKeepsMacOS86ButtonsDistinctFromSmallIcons() {
        XCTAssertEqual(NOWMirrorSource.finderPageMetadata(
            "\"V\tbutton\rP\tMacintosh HD:\r\"").view, .button)
        XCTAssertEqual(NOWMirrorSource.finderPageMetadata(
            "\"V\tbuttons\rP\tMacintosh HD:\r\"").view, .button)
        XCTAssertEqual(NOWMirrorSource.finderPageMetadata(
            "\"V\tsmall icon\rP\tMacintosh HD:\r\"").view, .smallIcon)
    }

    /// The Macintosh HD list view, exactly as the Finder answered it: rows at
    /// a 19-px pitch, each icon 16x16, while `position` for the same two files
    /// claimed 194,42 and 386,42 on a saved icon grid.
    func testAListViewRosterCarriesTheRowBoxAndNotAnIconBox() throws {
        let page = "\"N\t10\r"
            + "I\tApplications (Mac OS 9)\t22\t43\t38\t59\tfolder\r"
            + "I\tDocuments\t22\t62\t38\t78\tfolder\r\""

        let parsed = NOWMirrorSource.parseIcons(page)
        let first = try XCTUnwrap(parsed.first)
        XCTAssertEqual(first.name, "Applications (Mac OS 9)")
        XCTAssertEqual(first.kind, "folder", "the kind moved to field 7")
        XCTAssertEqual(first.x, 22)
        XCTAssertEqual(first.y, 43)
        XCTAssertEqual(first.w, 16)
        XCTAssertEqual(first.h, 16)
        XCTAssertEqual(parsed.last?.y, 62, "the next row, 19 px down")
        XCTAssertLessThan(try XCTUnwrap(first.h), 19,
                          "a box as tall as the row pitch reaches the file "
                          + "below it")
    }

    /// A five-field row is a capture taken before the roster moved to
    /// `bounds`. It still reads, with no size — which every reader answers
    /// with the 32x32 it assumed before the field existed.
    func testAnOlderFiveFieldRosterRowStillReadsWithNoBox() throws {
        let page = "\"N\t1\rI\tDate & Time\t184\t221\tcontrol panel\r\""
        let item = try XCTUnwrap(NOWMirrorSource.parseIcons(page).first)
        XCTAssertEqual(item.x, 184)
        XCTAssertEqual(item.y, 221)
        XCTAssertNil(item.w)
        XCTAssertEqual(HitTester.targetSize(item).w, HitTester.iconSize)
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

    func testOrdinaryFinderPageStartsAtSixteenRows() {
        let script = NOWMirrorSource.iconItemsScript(
            container: "window \"Macintosh HD\"", offset: 0)

        XCTAssertTrue(script.contains("set lastIndex to 16"),
                      "18 root items should take two guest turns, not three")
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

    /// Every roster failure used to wear the same sentence, and only one
    /// of them was ever that sentence's truth.
    func testEachRosterRefusalSaysItsOwnReason() {
        XCTAssertEqual(
            NOWMirrorSource.rosterPageRefusal(
                error: "the guest's AppleScript raised osaErr -1728",
                truncated: true, total: nil, expected: nil),
            "the guest's AppleScript raised osaErr -1728",
            "a raise outranks the emptiness the raise caused")
        XCTAssertEqual(
            NOWMirrorSource.rosterPageRefusal(
                error: nil, truncated: true, total: 4, expected: 4),
            "guest result truncated")
        XCTAssertTrue(
            NOWMirrorSource.rosterPageRefusal(
                error: nil, truncated: false, total: nil, expected: nil)
                .contains("without an item total"),
            "an unparseable reply is not a changing roster")
        XCTAssertTrue(
            NOWMirrorSource.rosterPageRefusal(
                error: nil, truncated: false, total: 9, expected: 7)
                .contains("changed mid-read"))
        XCTAssertTrue(
            NOWMirrorSource.rosterPageRefusal(
                error: nil, truncated: false,
                total: FinderItems.maxItemsPerWindow + 1, expected: nil)
                .contains("cap"))
        XCTAssertEqual(
            NOWMirrorSource.rosterPageRefusal(
                error: nil, truncated: false, total: 7, expected: 7),
            "incomplete or changing item roster",
            "the generic line survives for the one case it describes")
    }
}

/// The roster read's account of a guest that REFUSED the question.
///
/// `desktopItems` has never read on any drive, and the matching symptom is
/// the Finder's own Desktop window publishing `itemTotal: 0` with
/// seventeen icons on screen (measured 2026-08-05, reconfirmed 2026-08-06
/// on guest build 1bff0bd2ca39). Whatever the cause, this side said
/// "incomplete or changing item roster" every time — because the guest's
/// `osaErr` was read, matched and then thrown away, so an AppleScript that
/// raised arrived here indistinguishable from a container that is empty.
@MainActor
final class NOWMirrorRosterReasonTests: XCTestCase {

    private func source(answering rows: [[String]]) -> NOWMirrorSource {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        return NOWMirrorSource(
            listener: listener,
            act: AgentIntegrationActControl(listener: listener,
                                            currentSessionID: { nil }),
            interval: 3_600,
            sendCommand: { _, _, completion in
                completion(.init(id: 1, ok: true, output: ["script": rows]))
            })
    }

    /// The guest's own code, all the way to the sentence a person reads.
    func testARaisedScriptReportsTheGuestsOSACodeNotTheCatchAll() async {
        /* What a raising script actually puts on the wire: ok, an EMPTY
           output row, and the reason in osaErr. -1728 is the Finder's
           "can't get", the shape the Desktop read is suspected of. */
        let src = source(answering: [["output", ""],
                                     ["osaErr", "-1728"],
                                     ["truncated", "false"]])

        let items = await src.readIcons(container: "desktop")

        XCTAssertNil(items, "a refusal is still a refusal")
        XCTAssertTrue(src.lastAct.contains("-1728"),
                      "the guest's own code must reach the person driving; "
                      + "got: \(src.lastAct)")
        XCTAssertFalse(src.lastAct.contains("incomplete or changing"),
                       "the catch-all hid every real reason: \(src.lastAct)")
    }

    func testSemanticRosterPublishesBeforeIconArtSettles() async throws {
        var replies: [(CommandResult) -> Void] = []
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let src = NOWMirrorSource(
            listener: listener,
            act: AgentIntegrationActControl(listener: listener,
                                            currentSessionID: { nil }),
            interval: 3_600,
            sendCommand: { _, _, completion in replies.append(completion) })
        var firstPaint: NOWMirrorSource.FinderSurfaceRead?
        var settled = false

        let read = Task { @MainActor in
            let result = await src.readFinderSurface(
                container: "window \"Macintosh HD\"",
                rosterReady: { firstPaint = $0 })
            settled = true
            return result
        }
        while replies.isEmpty { await Task.yield() }
        replies.removeFirst()(.init(
            id: 1, ok: true,
            output: ["script": [
                ["output", "\"N\t1\rV\ticon\rP\tMacintosh HD:\r"
                    + "I\tSystem Folder\t20\t30\t52\t62\tfolder\tfalse\r\""],
                ["osaErr", "0"], ["truncated", "false"],
            ]]))
        while replies.isEmpty { await Task.yield() }

        XCTAssertEqual(firstPaint?.items.map(\.name), ["System Folder"])
        XCTAssertFalse(settled,
                       "type/creator art is still outstanding and may not "
                           + "hold semantic first paint")

        replies.removeFirst()(.init(
            id: 2, ok: true,
            output: ["script": [["output", "\"\""],
                                 ["osaErr", "0"],
                                 ["truncated", "false"]]]))
        _ = await read.value
        XCTAssertTrue(settled)
    }

    func testEachRosterPagePublishesWithoutWaitingForTheDirectory() async {
        var replies: [(CommandResult) -> Void] = []
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let src = NOWMirrorSource(
            listener: listener,
            act: AgentIntegrationActControl(listener: listener,
                                            currentSessionID: { nil }),
            interval: 3_600,
            sendCommand: { _, _, completion in replies.append(completion) })
        var paints: [(count: Int, complete: Bool)] = []

        let read = Task { @MainActor in
            await src.readFinderSurface(
                container: "window \"Macintosh HD\"",
                rosterReady: {
                    paints.append(($0.items.count,
                                   $0.presentation.complete))
                })
        }
        while replies.isEmpty { await Task.yield() }
        let firstRows = (0..<16).map {
            "I\tItem \($0)\t20\t\(30 + $0 * 19)\t36\t"
                + "\(46 + $0 * 19)\tfolder\tfalse"
        }.joined(separator: "\r")
        replies.removeFirst()(.init(
            id: 1, ok: true,
            output: ["script": [
                ["output", "\"N\t17\rV\tname\rP\tMacintosh HD:\r"
                    + firstRows + "\r\""],
                ["osaErr", "0"], ["truncated", "false"],
            ]]))
        while replies.isEmpty { await Task.yield() }

        XCTAssertEqual(paints.map(\.count), [16])
        XCTAssertEqual(paints.map(\.complete), [false])

        replies.removeFirst()(.init(
            id: 2, ok: true,
            output: ["script": [
                ["output", "\"N\t17\rV\tname\rP\tMacintosh HD:\r"
                    + "I\tItem 16\t20\t334\t36\t350\tfolder\tfalse\r\""],
                ["osaErr", "0"], ["truncated", "false"],
            ]]))
        while replies.isEmpty { await Task.yield() }

        XCTAssertEqual(paints.map(\.count), [16, 17])
        XCTAssertEqual(paints.map(\.complete), [false, true])

        replies.removeFirst()(.init(
            id: 3, ok: true,
            output: ["script": [["output", "\"\""],
                                 ["osaErr", "0"],
                                 ["truncated", "false"]]]))
        _ = await read.value
    }

    /// The opposite half, so the fix cannot be "call everything an error".
    /// A guest that reports no failure reported no failure.
    func testAnEmptyContainerIsStillAnEmptyContainer() async {
        let src = source(answering: [["output", "\"N\t0\r\""],
                                     ["osaErr", "0"],
                                     ["truncated", "false"]])

        let items = await src.readIcons(container: "desktop")

        XCTAssertEqual(items?.count, 0,
                       "zero items is an answer, not a refusal")
    }
}
