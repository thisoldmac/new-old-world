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

    func testTheMirrorModuleRendersAtBothPaneWidths() throws {
        let outDir = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["NOW_MIRROR_LAYOUT_OUT"]
                ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)

        for (label, size) in Self.sizes {
            for candidate in ["A-toolbar-inspector-open",
                              "B-toolbar-inspector-closed",
                              "C-floating-controls"] {
                let rig = try makeRig()
                rig.presentation.inspectorShown = candidate.hasPrefix("A")
                let view = AnyView(
                    candidate.hasPrefix("C")
                        ? AnyView(floatingCandidate(rig))
                        : AnyView(MirrorModuleView(
                            model: rig.model,
                            source: rig.source,
                            run: rig.run,
                            presentation: rig.presentation,
                            window: rig.window,
                            connectedMachineName: "Power Mac G4",
                            timeline: rig.source.actTimeline,
                            cycles: rig.source.cycleTimeline)))
                    .frame(width: size.width, height: size.height)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try XCTUnwrap(
                    renderer.cgImage,
                    "the Mirror module no longer renders offscreen at "
                    + "\(label); that usually means it has grown a "
                    + "dependency on a real window")
                let png = try XCTUnwrap(
                    NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:]))
                let name = "mirror-module-\(candidate)-\(label).png"
                try png.write(to: outDir.appendingPathComponent(name))
            }
        }
    }

    /// **Candidate C, and it is a MOCK — deliberately.**
    ///
    /// It composes the REAL `MirrorToolbarView` over the REAL
    /// `MirrorPaneView`, so what is being judged is the arrangement
    /// rather than a drawing of one; only the container is local. That is
    /// the cheap way to put a third option in front of somebody without
    /// building a layout that may not be chosen — "polish later" cuts
    /// both ways, and a candidate nobody picks should not have cost a
    /// shipping code path.
    @ViewBuilder
    private func floatingCandidate(_ rig: Rig) -> some View {
        ZStack(alignment: .top) {
            MirrorPaneView(source: rig.source,
                           presentation: rig.presentation,
                           container: .modulePane)
            MirrorToolbarView(model: rig.model, run: rig.run,
                              presentation: rig.presentation,
                              setDetached: { _ in })
                .fixedSize(horizontal: true, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(radius: 6, y: 2)
                .padding(.top, 10)
        }
    }

    // MARK: - A source with a real scene in it

    private struct Rig {
        let model: MirrorControlModel
        let source: NOWMirrorSource
        let run: MirrorRunControl
        let presentation: MirrorPresentation
        let window: NOWMirrorWindow
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

        let suiteName = "test.mirror.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let presentation = MirrorPresentation(defaults: defaults)
        let run = MirrorRunControl(source: source, defaults: defaults)
        let model = MirrorControlModel(
            guestProbe: MirrorGuestWireProbe(listener: listener))
        return Rig(model: model, source: source, run: run,
                   presentation: presentation,
                   window: NOWMirrorWindow(source: source,
                                           presentation: presentation))
    }
}
