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

    /// Round two. B is the arrangement Michelle accepted and is rendered
    /// again as the control — with content in it this time, which is the
    /// comparison round one could not make.
    private static let candidates = ["B-accepted-inspector-open",
                                     "D-disclosure-sidebar",
                                     "E-bottom-event-drawer",
                                     "F-popup-panels-no-sheet"]

    func testTheMirrorModuleRendersAtBothPaneWidths() throws {
        let outDir = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["NOW_MIRROR_LAYOUT_OUT"]
                ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)

        for (label, size) in Self.sizes {
            for candidate in Self.candidates {
                let rig = try makeRig()
                    let view = AnyView(
                    arrangement(candidate, rig)
                        .frame(width: size.width, height: size.height))
                let image = try render(view, candidate: candidate,
                                       label: label)
                try write(image, to: outDir,
                          named: "mirror-module-\(candidate)-\(label).png")
            }
        }

        /* The sheet, separately and once. A sheet is presented by a
           window and there is no window here, so `.sheet` renders as
           nothing at all — which would have been a silently empty
           candidate D. Rendering the sheet's CONTENT at the size the
           sheet declares is the honest substitute, and it says plainly
           what is not being shown: the sheet's own chrome. */
        let rig = try makeRig()
        let sheet = AnyView(
            MirrorSettingsView(model: rig.model, dismiss: {})
                .frame(width: 460, height: 460))
        let image = try render(sheet, candidate: "settings-sheet",
                               label: "sheet")
        try write(image, to: outDir,
                  named: "mirror-module-settings-sheet.png")
    }

    // MARK: - The arrangements

    /// **Every candidate composes the SAME views** — the real toolbar,
    /// the real pane, the real cards, the real event stream. Only the
    /// container differs, which is what makes the pictures a question
    /// about arrangement rather than about drawing, and what keeps a
    /// candidate nobody picks from having cost a shipping code path.
    @ViewBuilder
    private func arrangement(_ candidate: String, _ rig: Rig) -> some View {
        switch candidate {
        case "B-accepted-inspector-open":
            let _ = (rig.presentation.inspectorShown = true)
            MirrorModuleView(model: rig.model, source: rig.source,
                             run: rig.run, presentation: rig.presentation,
                             window: rig.window,
                             connectedMachineName: "Power Mac G4",
                             timeline: rig.source.actTimeline,
                             cycles: rig.source.cycleTimeline)
        case "D-disclosure-sidebar":
            CandidateD(rig: rig)
        case "E-bottom-event-drawer":
            CandidateE(rig: rig)
        default:
            CandidateF(rig: rig)
        }
    }

    /// **D — one collapsible trailing sidebar, sectioned by disclosure.**
    ///
    /// Michelle's shape, with the switcher taken out. A segmented control
    /// was the first draft and it is wrong twice: it makes Events and
    /// Diagnostics mutually exclusive in a column tall enough for both,
    /// and `Picker(.segmented)` returns the prohibited placeholder in the
    /// offscreen renderer, so picking it would mean nobody can review
    /// this module again without sitting at the machine
    /// (`MirrorReviewRendering`). Disclosure sections are native, are
    /// what Xcode's own inspectors use, and let a person keep the two
    /// things open that they are correlating.
    ///
    /// Settings are a sheet off the toolbar's gear.
    private struct CandidateD: View {
        let rig: Rig
        @State private var eventsOpen = true
        @State private var detailsOpen = true
        @State private var filter = MirrorEventFilter()

        var body: some View {
            VStack(spacing: 0) {
                mockToolbar(rig, gear: true)
                Divider()
                HStack(spacing: 0) {
                    MirrorPaneView(source: rig.source,
                                   presentation: rig.presentation,
                                   container: .modulePane)
                        .frame(minWidth: 280, maxWidth: .infinity,
                               maxHeight: .infinity)
                        .layoutPriority(1)
                    Divider()
                    MirrorScrollBox {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup("Events", isExpanded: $eventsOpen) {
                                /* Bounded, because the stream has no
                                   length of its own and this section is
                                   inside a scroller. That bound is the
                                   candidate's cost, not a detail: it is
                                   a scrolling list inside a scrolling
                                   column, which macOS does badly and
                                   people do worse. */
                                MirrorEventStreamView(
                                    timeline: rig.source.actTimeline,
                                    cycles: rig.source.cycleTimeline,
                                    filter: $filter)
                                    .frame(height: 240)
                            }
                            Divider()
                            DisclosureGroup("Details", isExpanded: $detailsOpen) {
                                VStack(alignment: .leading, spacing: 12) {
                                    MirrorLifecycleCard(model: rig.model)
                                    MirrorPlanesCard(model: rig.model,
                                                     showsPolicy: false)
                                    MirrorSceneFactsCard(source: rig.source)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: 260)
                }
            }
        }
    }

    /// **E — the log gets the width it wants.** The trailing inspector
    /// keeps the diagnostics; the event stream is a full-width drawer
    /// under the picture, because a stream of labelled, timed rows reads
    /// as a table and a 260-point column is not one.
    ///
    /// A `VSplitView` would be the obvious way to let a person size it,
    /// and it is disqualified: it does not rasterize offscreen at all
    /// (round one found this), so a resizable drawer could only ever be
    /// reviewed by somebody sitting at the machine. Fixed height, and a
    /// disclosure to close it.
    private struct CandidateE: View {
        let rig: Rig
        @State private var eventsOpen = true
        @State private var filter = MirrorEventFilter()

        var body: some View {
            VStack(spacing: 0) {
                mockToolbar(rig, gear: true)
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        MirrorPaneView(source: rig.source,
                                       presentation: rig.presentation,
                                       container: .modulePane)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        HStack(spacing: 6) {
                            Button {
                                eventsOpen.toggle()
                            } label: {
                                Image(systemName: eventsOpen
                                      ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text("Events").font(.callout.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.bar)
                        if eventsOpen {
                            Divider()
                            MirrorEventStreamView(
                                timeline: rig.source.actTimeline,
                                cycles: rig.source.cycleTimeline,
                                filter: $filter)
                                .frame(height: 190)
                        }
                    }
                    .frame(minWidth: 280, maxWidth: .infinity)
                    .layoutPriority(1)
                    Divider()
                    diagnostics(rig, showsPolicy: false)
                        .frame(width: 260)
                }
            }
        }
    }

    /// **F — no modal at all.** One trailing sidebar, one pop-up naming
    /// which panel it is showing, and the plane switches stay beside the
    /// plane states they explain. The control for the other two: if a
    /// sheet turns out to buy nothing, this is the arrangement with the
    /// least new furniture in it.
    ///
    /// The switcher is a `Picker(.menu)` — a pop-up. It is the same
    /// choice the toolbar already makes for zoom, and unlike a segmented
    /// control it does not spend the column's whole width on three words
    /// nor vanish from the offscreen renderer.
    private struct CandidateF: View {
        let rig: Rig
        @State private var panel = 0
        @State private var filter = MirrorEventFilter()

        var body: some View {
            VStack(spacing: 0) {
                mockToolbar(rig, gear: false)
                Divider()
                HStack(spacing: 0) {
                    MirrorPaneView(source: rig.source,
                                   presentation: rig.presentation,
                                   container: .modulePane)
                        .frame(minWidth: 280, maxWidth: .infinity,
                               maxHeight: .infinity)
                        .layoutPriority(1)
                    Divider()
                    VStack(spacing: 0) {
                        HStack {
                            Picker("", selection: $panel) {
                                Text("Events").tag(0)
                                Text("Details").tag(1)
                                Text("Settings").tag(2)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        Divider()
                        switch panel {
                        case 0:
                            MirrorEventStreamView(
                                timeline: rig.source.actTimeline,
                                cycles: rig.source.cycleTimeline,
                                filter: $filter)
                        case 1:
                            diagnostics(rig, showsPolicy: false)
                        default:
                            MirrorSettingsView(model: rig.model)
                        }
                    }
                    .frame(width: 260)
                }
            }
        }
    }
}

// MARK: - Shared pieces of the mocks

@MainActor
private func mockToolbar(_ rig: MirrorModuleLayoutRenderTests.Rig,
                     gear: Bool) -> some View {
    HStack(spacing: 0) {
        MirrorToolbarView(model: rig.model, run: rig.run,
                          presentation: rig.presentation,
                          setDetached: { _ in })
        if gear {
            /* Drawn outside MirrorToolbarView rather than added to it:
               the gear only exists in the candidates that have a sheet,
               and a control added to the shipping toolbar for a candidate
               nobody picks is exactly the cost these mocks avoid. */
            Button { } label: { Image(systemName: "gearshape") }
                .help("Mirror Settings…")
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }
}

@MainActor
private func diagnostics(_ rig: MirrorModuleLayoutRenderTests.Rig,
                         showsPolicy: Bool) -> some View {
    MirrorScrollBox {
        VStack(alignment: .leading, spacing: 14) {
            MirrorLifecycleCard(model: rig.model)
            MirrorPlanesCard(model: rig.model, showsPolicy: showsPolicy)
            MirrorSceneFactsCard(source: rig.source)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
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

    private func makeRig() throws -> Rig {
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
        return Rig(model: model, source: source, run: run,
                   presentation: presentation,
                   window: NOWMirrorWindow(source: source,
                                           presentation: presentation))
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
