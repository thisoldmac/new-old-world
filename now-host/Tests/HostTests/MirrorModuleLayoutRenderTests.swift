import XCTest
import SwiftUI
import AppKit
import MirrorKit
@testable import Host

/// **Eyes on the module's own layout, without a screen grant and without
/// a VM.**
///
/// The 019 embed lane shipped a module that every gate called correct and
/// that nobody had looked at — and the first human to look said the
/// layout was bad. The gap was not a missing test; it was that "does this
/// read well at 600 points wide" is not a question a structural assertion
/// can be asked. `ImageRenderer` can render a SwiftUI view offscreen, so
/// it can be asked in half a second.
///
/// This writes PNGs rather than asserting on them, deliberately. The
/// judgement is a person's; what a gate can hold is that the picture can
/// still be TAKEN — a module that stops rendering offscreen has usually
/// grown a dependency on a real window, which is worth knowing.
///
/// **A rig that renders empty is worse than no rig**, and that is the
/// defect this file shipped with. Round one's three candidates were all
/// rendered against a source with no wire facts, no acts and no cycles,
/// so the inspector column came out BLANK in every picture — and the
/// person reviewing them was asked to judge an arrangement of content
/// that was not in the frame. She said so: the candidates "didnt account
/// for the actual content". So `makeRig` now fills every readout the
/// module has, and `assertHasContent` fails the run if the rendered image
/// is a flat colour, because a blank picture must never again read as an
/// opinion about a layout.
///
/// `NOW_MIRROR_LAYOUT_OUT` names where they go. Unset, they go to the
/// system temporary directory and the run is a smoke test.
@MainActor
final class MirrorModuleLayoutRenderTests: XCTestCase {

    /// A pane is not one width. A layout that is merely cramped at 600
    /// points is a different defect from one that is wrong at 1400, and
    /// rendering one size hides which of the two you have.
    private static let sizes: [(String, CGSize)] = [
        ("narrow", CGSize(width: 620, height: 720)),
        ("wide", CGSize(width: 1400, height: 900)),
    ]

    /// **Round three renders the SHIPPING module, not mocks.**
    ///
    /// Rounds one and two put candidates in front of a person and one was
    /// chosen — a full-width event drawer under the picture, labelled
    /// facts in the trailing column, both closed by default. So there is
    /// nothing left to compare: what wants looking at now is the real
    /// `MirrorModuleView` in each of the states a person can put it in.
    ///
    /// The resting state comes FIRST on purpose. Both drawers shut is
    /// what the module looks like on launch, and it is deliberately the
    /// arrangement that was already accepted — so if the drawers turn out
    /// to be wrong, closing them is the whole of the retreat.
    private static let states: [(String, Bool, Bool)] = [
        // label, events open, inspector open
        ("closed", false, false),
        ("events", true, false),
        ("inspector", false, true),
        ("both", true, true),
    ]

    func testTheMirrorModuleRendersAtBothPaneWidths() throws {
        let outDir = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["NOW_MIRROR_LAYOUT_OUT"]
                ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)

        for (label, size) in Self.sizes {
            for (state, events, inspector) in Self.states {
                let rig = try makeRig()
                rig.presentation.eventsShown = events
                rig.presentation.inspectorShown = inspector
                let view = AnyView(
                    MirrorModuleView(model: rig.model, source: rig.source,
                                     run: rig.run,
                                     presentation: rig.presentation,
                                     window: rig.window,
                                     fileTransfer: rig.fileTransfer,
                                     connectedMachineName: "Power Mac G4",
                                     timeline: rig.source.actTimeline,
                                     cycles: rig.source.cycleTimeline)
                        .frame(width: size.width, height: size.height))
                let image = try render(view, candidate: state, label: label)
                try write(image, to: outDir,
                          named: "mirror-module-\(state)-\(label).png")
            }
        }
    }

    func testContinuityModeRendersTheLayoutInsteadOfTheMirror() throws {
        let rig = try makeRig()
        rig.source.surfaceMode = .continuity
        defer { rig.source.stop() }
        let view = AnyView(
            MirrorModuleView(model: rig.model, source: rig.source,
                             run: rig.run,
                             presentation: rig.presentation,
                             window: rig.window,
                             fileTransfer: rig.fileTransfer,
                             connectedMachineName: "Power Mac G4",
                             timeline: rig.source.actTimeline,
                             cycles: rig.source.cycleTimeline)
                .frame(width: 900, height: 720))

        _ = try render(view, candidate: "continuity", label: "wide")
    }
}

// MARK: - Rendering, and refusing to render nothing

extension MirrorModuleLayoutRenderTests {

    private func render(_ view: AnyView, candidate: String,
                        label: String) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view.environment(\.mirrorRenderingForReview, true))
        renderer.scale = 1
        let image = try XCTUnwrap(
            renderer.cgImage,
            "the Mirror module no longer renders offscreen at "
            + "\(label) (\(candidate)); that usually means it has grown a "
            + "dependency on a real window")
        try assertHasContent(image, candidate: candidate, label: label)
        return image
    }

    /// **A picture that is one colour is not a layout.**
    ///
    /// Round one's inspector rendered completely blank and every gate
    /// passed, because "did `ImageRenderer` return an image" is a
    /// different question from "is there anything in it". This samples a
    /// grid and fails when everything matches — which is the cheapest
    /// possible guard against reviewing an empty frame, and the one that
    /// would have caught the defect Michelle caught by eye.
    private func assertHasContent(_ image: CGImage, candidate: String,
                                  label: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        var seen = Set<UInt32>()
        let stepX = max(1, image.width / 40)
        let stepY = max(1, image.height / 40)
        for x in stride(from: 0, to: image.width, by: stepX) {
            for y in stride(from: 0, to: image.height, by: stepY) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let packed = UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                seen.insert(packed)
            }
        }
        XCTAssertGreaterThan(
            seen.count, 3,
            "\(candidate) at \(label) rendered \(seen.count) distinct "
            + "colours across the whole frame — that is a blank picture, "
            + "not a layout, and judging it would be judging nothing")
    }

    private func write(_ image: CGImage, to dir: URL,
                       named name: String) throws {
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent(name))
    }
}

// MARK: - A rig with every readout filled

extension MirrorModuleLayoutRenderTests {

    struct Rig {
        let model: MirrorControlModel
        let source: NOWMirrorSource
        let run: MirrorRunControl
        let presentation: MirrorPresentation
        let window: NOWMirrorWindow
        let fileTransfer: MirrorFileTransferModel
    }

    /// A probe that answers with facts rather than with a connection.
    /// Round one used the real wire probe against a listener no Mac had
    /// ever spoken to, so `wireFacts` stayed nil and the lifecycle and
    /// planes cards drew their empty states — in a picture whose whole
    /// purpose was to show what those cards look like.
    private final class StubProbe: MirrorGuestProbing {
        let facts: MirrorWireFacts
        var activeGuest: ConnectedGuest?
        init(facts: MirrorWireFacts, activeGuest: ConnectedGuest?) {
            self.facts = facts
            self.activeGuest = activeGuest
        }
        func readMirrorFacts(
            completion: @escaping (Result<MirrorWireFacts,
                                          MirrorProbeFailure>) -> Void) {
            completion(.success(facts))
        }
    }

    /// The same rig, for the panel test in this file.
    static func sharedRig() throws -> Rig {
        try MirrorModuleLayoutRenderTests().makeRig()
    }

    fileprivate func makeRig() throws -> Rig {
        let key = GuestKey.synthetic("layout-\(UUID().uuidString)")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let registry = MirrorStateEngineRegistry()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: registry,
            act: AgentIntegrationActControl(listener: listener,
                                            currentSessionID: { nil }),
            interval: 3_600,
            finderRefreshOverride: { _, _, done in done() },
            visibilityRefreshOverride: { _, _, done in done() },
            cycleIO: harness.io)

        source.start()
        /* A real scene, so the pane draws a Macintosh rather than
           "waiting for the first scene…" — which is the one state whose
           layout tells you nothing. */
        harness.completeScene(0, with: .success(.init(
            document: try identifiedSceneDocument(seq: 1), irVersion: 2,
            seq: 1, capturedAt: 1, source: "test", walkMs: 1,
            settlements: nil, transferMs: 1,
            guestName: "Power Mac G4", guestKey: key)))
        if !harness.joinedScenes.isEmpty { harness.completeJoin(0) }

        fillTimelines(source)

        let suiteName = "test.mirror.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let presentation = MirrorPresentation(defaults: defaults)
        let run = MirrorRunControl(source: source, defaults: defaults)
        let model = MirrorControlModel(guestProbe: StubProbe(
            facts: Self.facts, activeGuest: Self.guest(key: key)),
                                       defaults: defaults)
        model.connection = .connected(name: "Power Mac G4", key: key)
        model.refreshLifecycle()
        let fileTransfer = MirrorFileTransferModel(listener: listener)
        fileTransfer.connection = model.connection
        return Rig(model: model, source: source, run: run,
                   presentation: presentation,
                   window: NOWMirrorWindow(source: source,
                                           presentation: presentation,
                                           fileTransfer: fileTransfer),
                   fileTransfer: fileTransfer)
    }

    /// Acts and cycles a drive would actually have produced: a couple
    /// that worked, one that queued behind something, one that never
    /// settled. The last is the row the whole drawer exists for, so a
    /// candidate that cannot make it stand out has failed at its job.
    private func fillTimelines(_ source: NOWMirrorSource) {
        let t0 = Date().addingTimeInterval(-90)
        func act(_ offset: TimeInterval, _ label: String,
                 _ outcome: MirrorOperationOutcome, waited: TimeInterval,
                 dispatch: TimeInterval, settle: TimeInterval?,
                 depth: Int) -> MirrorActClocks {
            let enqueued = t0.addingTimeInterval(offset)
            let started = enqueued.addingTimeInterval(waited)
            let returned = started.addingTimeInterval(dispatch)
            return MirrorActClocks(
                kind: .released, operationID: "op-\(Int(offset))",
                label: label, outcome: outcome, queueDepthAtEntry: depth,
                enqueuedAt: enqueued, dispatchStartedAt: started,
                dispatchReturnedAt: returned,
                settledAt: settle.map { returned.addingTimeInterval($0) },
                releasedAt: returned.addingTimeInterval(settle ?? 15))
        }
        for clocks in [
            act(0, "click System Folder", .confirmed, waited: 0.01,
                dispatch: 0.31, settle: 0.62, depth: 0),
            act(12, "double-click Applications", .confirmed, waited: 0.02,
                dispatch: 0.28, settle: 0.71, depth: 0),
            act(21, "drag \"Read Me\" to the Trash", .refused, waited: 0.9,
                dispatch: 0.20, settle: nil, depth: 1),
            act(33, "menu File ▸ New Folder", .confirmed, waited: 1.4,
                dispatch: 0.33, settle: 0.90, depth: 2),
            act(48, "type into \"untitled folder\"", .timedOut, waited: 0.02,
                dispatch: 15.0, settle: nil, depth: 0),
            act(70, "click the desktop", .confirmed, waited: 0.01,
                dispatch: 0.22, settle: 0.55, depth: 0),
        ] {
            source.actTimeline.record(clocks)
        }
        source.actTimeline.depth = 2

        func cycle(_ offset: TimeInterval, semantics: Bool,
                   interaction: Bool, request: TimeInterval,
                   outcome: String = "ok") -> MirrorCycleClocks {
            let requested = t0.addingTimeInterval(offset)
            let delivered = requested.addingTimeInterval(request)
            return MirrorCycleClocks(
                requestedAt: requested, deliveredAt: delivered,
                publishedAt: delivered.addingTimeInterval(0.004),
                idleBefore: 0.5, semantics: semantics,
                interaction: interaction, outcome: outcome,
                windows: 3, elements: 41, phases: nil,
                ownWork: 0.004, contentJoin: nil, guestTimeouts: nil)
        }
        for clocks in [
            cycle(5, semantics: false, interaction: false, request: 0.42),
            cycle(18, semantics: true, interaction: false, request: 0.88),
            cycle(30, semantics: false, interaction: true, request: 0.79),
            cycle(44, semantics: true, interaction: true, request: 1.63),
            cycle(60, semantics: false, interaction: false, request: 0.39),
            cycle(75, semantics: true, interaction: true, request: 2.10,
                  outcome: "guest timed out"),
        ] {
            source.cycleTimeline.record(clocks)
        }
    }

    private static var facts: MirrorWireFacts {
        MirrorWireFacts(
            schema: 1,
            resident: MirrorWireExtension(
                selector: "NWex", lifecycle: .active, expectedMajor: 1,
                residentMajor: 1, residentMinor: 4, tableLength: 96,
                capabilities: 31, requested: 15, active: 15,
                heartbeat: 4821, sourceManifest: nil,
                buildFingerprint: "ext-2026-08-07-a41c9f",
                reason: nil),
            planes: [
                plane(.structure, purpose: "Windows, menus and controls",
                      generation: 812),
                plane(.semantics, purpose: "Titles, values and states",
                      generation: 806),
                plane(.content, purpose: "What each window has drawn",
                      generation: 0, active: false,
                      state: .requested,
                      reason: "the resident carries this plane dark"),
                plane(.interaction, purpose: "Where a click may land",
                      generation: 799),
                plane(.transitions, purpose: "What changed since last look",
                      generation: 0, supported: false, requested: false,
                      active: false, state: .unsupported),
            ])
    }

    private static func plane(_ id: MirrorPlaneID, purpose: String,
                              generation: Int, supported: Bool = true,
                              requested: Bool = true, active: Bool = true,
                              state: MirrorGuestPlaneState = .activeCurrent,
                              reason: String? = nil) -> MirrorWirePlane {
        MirrorWirePlane(id: id, purpose: purpose, capability: 1,
                        supported: supported, format: supported ? 1 : 0,
                        requested: requested, active: active,
                        freshness: active ? .current : .unavailable,
                        state: state, generation: generation,
                        reason: reason)
    }

    private static func guest(key: GuestKey) -> ConnectedGuest {
        ConnectedGuest(key: key, id: GuestID("g4")!,
                       idIsAutoAssigned: false, idIsAnchored: true,
                       name: "Power Mac G4",
                       address: GuestAddress(text: "10.0.2.2"),
                       version: "0.7", build: "now-2026-08-07",
                       operatingSystem: "Mac OS 9.2.2",
                       connectedAt: Date(), isActive: true)
    }
}

/// **Each piece of content, alone, proved to draw.**
///
/// `assertHasContent` on a whole candidate is weaker than it sounds: a
/// frame containing a Macintosh and an empty 260-point column is not one
/// colour, so a swallowed inspector passes it. That is exactly the defect
/// round one shipped — and it would have shipped again.
///
/// So every panel is also rendered on its own, at the width it actually
/// gets, where "blank" and "one colour" are the same thing. Watched
/// failing by mutation on 2026-08-07: making `MirrorScrollBox` return a
/// `ScrollView` under review too fails all three of these and passes the
/// whole-module test, which is the asymmetry this exists for.
@MainActor
final class MirrorPanelRenderTests: XCTestCase {

    private func colours(_ view: some View, _ size: CGSize) throws -> Int {
        let renderer = ImageRenderer(
            content: AnyView(view
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                .environment(\.mirrorRenderingForReview, true)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: image.width, by: 2) {
            for y in stride(from: 0, to: image.height, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16
                            | UInt32(c.greenComponent * 255) << 8
                            | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    func testEveryMirrorPanelDrawsSomething() throws {
        let rig = try MirrorModuleLayoutRenderTests.sharedRig()
        var filter = MirrorEventFilter()
        let binding = Binding(get: { filter }, set: { filter = $0 })
        let column = CGSize(width: 260, height: 600)

        /* **Differential, not a magic number.** A swallowed list still
           draws the panel's header strip, so "more than a few colours"
           passes it — measured 84 with the rows gone against 223 with
           them. The honest guard is the same panel with nothing in it:
           whatever the header costs, six rows must cost visibly more,
           and that survives a font or a padding change in a way a
           threshold of 150 would not. */
        let bare = MirrorActTimeline(log: { _ in })
        let bareCycles = MirrorCycleTimeline(log: { _ in })
        let empty = try colours(
            MirrorEventStreamView(timeline: bare, cycles: bareCycles,
                                  filter: binding), column)
        let events = try colours(
            MirrorEventStreamView(timeline: rig.source.actTimeline,
                                  cycles: rig.source.cycleTimeline,
                                  filter: binding), column)
        XCTAssertGreaterThan(events, empty + 40,
            "the event stream drew \(events) colours at 260×600 against "
            + "\(empty) for the same panel with no events in it — six "
            + "rows cannot cost that little, so its container is "
            + "swallowing them")

        let cards = try colours(
            MirrorControlView(model: rig.model, run: rig.run,
                              presentation: rig.presentation,
                              source: rig.source,
                              cycles: rig.source.cycleTimeline), column)
        XCTAssertGreaterThan(cards, 8,
            "the diagnostics column drew \(cards) colours at 260×600")
    }
}
