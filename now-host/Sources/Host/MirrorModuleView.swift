import SwiftUI

/// **The Mirror module: the other Macintosh, and chrome around it.**
///
/// The page used to be controls only, and said so in `ModuleRegistry`:
/// "this page owns whether that Mac is ready for it and one instance's
/// lifecycle, *not the drawing*." It draws now.
///
/// **The Mirror is this module's content, and it gets the pane.** The
/// first embedded version put it in a `VSplitView` with the old control
/// cluster underneath — which said "these two are peers and you apportion
/// them" about a picture of a Macintosh and a stack of diagnostics. They
/// are not peers. A document gets the window in every other module here,
/// and the classic Mac's screen is the document.
///
/// So the arrangement is the ordinary Mac one, grouped by how often a
/// control is reached rather than by what it belongs to:
///
/// - a **toolbar** across the top for the things a person acts with —
///   Start/Stop, Detach, and the zoom stop;
/// - the **Mirror** filling everything under it;
/// - a **trailing inspector**, closed by default, for the things a person
///   looks up when something is wrong: the planes, the resident's
///   lifecycle, the act and cycle clocks.
///
/// Whether it is *running* is orthogonal to all of this. The poll keeps
/// going while another module is showing, while this pane is destroyed,
/// and while nobody is looking at all — because `now_mirror_drive` and
/// the fidelity sweep read the same source with no window in the picture,
/// and a drive that starts refusing because somebody clicked Console is a
/// defect nothing on either machine names.
struct MirrorModuleView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var source: NOWMirrorSource
    @ObservedObject var run: MirrorRunControl
    @ObservedObject var presentation: MirrorPresentation
    @ObservedObject var window: NOWMirrorWindow
    let connectedMachineName: String
    @ObservedObject var timeline: MirrorActTimeline
    @ObservedObject var cycles: MirrorCycleTimeline

    var body: some View {
        VStack(spacing: 0) {
            MirrorToolbarView(model: model, run: run,
                              presentation: presentation,
                              setDetached: setDetached)
            Divider()
            HStack(spacing: 0) {
                /* `minWidth` on the CONTENT, not a maximum on the
                   inspector, and that ordering is the point: when the
                   pane is narrow the Mirror keeps its floor and the
                   inspector is what gives way. A fixed 300-point column
                   beside a 620-point pane took half of it, which is the
                   same "these are peers" mistake the split view made,
                   turned ninety degrees.

                   The two minimums must also SUM to no more than the
                   detail column's own floor — `HostRootView` declares
                   `minWidth: 480` — or the pair overflows the pane and
                   both ends are clipped, which is what 380 + 260 did. */
                content
                    .frame(minWidth: 280, maxWidth: .infinity,
                           maxHeight: .infinity)
                    .layoutPriority(1)
                if presentation.inspectorShown {
                    Divider()
                    /* A FIXED width, and the content takes the rest.
                       Two flexible columns split the pane between them,
                       which at 620 points gave the diagnostics as much
                       room as the Macintosh. */
                    MirrorControlView(model: model, run: run,
                                      presentation: presentation,
                                      timeline: timeline, cycles: cycles)
                        .frame(width: 260)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if presentation.isDetached {
            /* Not an empty pane. A module whose content has gone
               somewhere else must say where, or it reads as broken —
               and the way back is right here rather than in a menu. */
            VStack(spacing: 12) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("The Mirror is in its own window.")
                    .font(.title3.weight(.medium))
                Text("It is still running, and still being driven — "
                     + "detaching changes where you see it, not what it "
                     + "is doing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                Button("Bring it back here") { setDetached(false) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MirrorPaneView(source: source, presentation: presentation,
                           container: .modulePane)
        }
    }

    /// **One path for both directions.**
    ///
    /// `NOWMirrorWindow` owns whether its window is up and sets
    /// `isDetached` itself, so going through it means the axis and the
    /// window cannot disagree. Toggling the axis directly and letting a
    /// view react would be two mechanisms that have to stay in step — and
    /// the view-reaction version crashed `ImageRenderer` outright
    /// ("no current update to enqueue action to"), because showing a
    /// window from inside a view update is not a thing a view may do.
    private func setDetached(_ detached: Bool) {
        if detached {
            window.show(title: "Mirror — \(connectedMachineName)")
        } else {
            window.close()
        }
    }
}
