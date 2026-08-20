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
/// control is reached rather than by what it belongs to — and then, in a
/// second round, by **what SHAPE each piece of content is**:
///
/// - a **toolbar** across the top for the things a person acts with —
///   Start/Stop, Detach, the zoom stop, and the two drawers;
/// - the **Mirror** filling everything under it;
/// - an **event drawer** beneath the picture, full width, closed by
///   default. The acts and scene cycles are a time-ordered TABLE — glyph,
///   label, duration, outcome — and a 260-point column cannot hold one
///   without truncating the label, which is the one part a person reads.
///   `drag "Read Me" to the Trash` fits whole here and does not in a
///   sidebar; that is the whole argument.
/// - a **trailing inspector**, also closed by default, for labelled
///   facts: the resident's lifecycle, the planes with their switches, the
///   last scene's counts, the cycle baselines. These are names and values
///   and are perfectly happy narrow.
///
/// **Both closed by default, and the pair of defaults is the decision.**
/// With both shut this module is exactly the toolbar and the Macintosh
/// that was already accepted, so neither drawer can ever be something a
/// person did not ask for.
///
/// Whether it is *running* is orthogonal to all of this. The poll keeps
/// going while another module is showing, while this pane is destroyed,
/// and while nobody is looking at all — because `now_semantic_ui_act` and
/// the fidelity sweep read the same source with no window in the picture,
/// and a drive that starts refusing because somebody clicked Console is a
/// defect nothing on either machine names.
struct MirrorModuleView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var source: NOWMirrorSource
    @ObservedObject var run: MirrorRunControl
    @ObservedObject var presentation: MirrorPresentation
    @ObservedObject var window: NOWMirrorWindow
    @ObservedObject var fileTransfer: MirrorFileTransferModel
    let connectedMachineName: String
    @ObservedObject var timeline: MirrorActTimeline
    @ObservedObject var cycles: MirrorCycleTimeline
    /// Optional so the layout render tests, which have no wire, keep
    /// constructing this view unchanged.
    var assetIngestion: MirrorAssetIngestion?

    /// The event drawer's height. Fixed rather than draggable, and the
    /// reason is the review loop rather than taste: a `VSplitView` is the
    /// obvious way to let a person size it and **does not rasterize
    /// offscreen at all** (`MirrorReviewRendering`), so a resizable
    /// drawer could only ever be reviewed by somebody sitting at the
    /// machine. 190 points is six rows and the header.
    private static let drawerHeight: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            MirrorToolbarView(model: model, source: source, run: run,
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
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transferStatus
                    if !presentation.isDetached {
                        eventDrawer
                    }
                }
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
                                      source: source, cycles: cycles,
                                      ingestion: assetIngestion,
                                      machineName: connectedMachineName)
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
                Text("Still running and still being driven. Detaching "
                     + "changes where it is displayed, nothing else.")
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
                           fileTransfer: fileTransfer,
                           container: .modulePane)
        }
    }

    @ViewBuilder
    private var transferStatus: some View {
        if let activity = fileTransfer.activity {
            Divider()
            HStack(spacing: 10) {
                Text(activity.label)
                    .font(.caption)
                    .lineLimit(1)
                if activity.expected > 0 && !activity.awaitingSettlement {
                    ProgressView(value: Double(activity.received),
                                 total: Double(activity.expected))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 180)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                if activity.awaitingSettlement {
                    Text("finishing on the other Mac…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        } else if let notice = fileTransfer.notice {
            Divider()
            HStack(spacing: 8) {
                Text(notice).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    fileTransfer.clearNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Dismiss file transfer status")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// **The drawer, and its own header even when it is shut.**
    ///
    /// The closed state is a one-line strip rather than nothing at all.
    /// A drawer with no handle is a feature a person has to be told
    /// about, and the toolbar toggle alone would make the events
    /// something you have to already know exist.
    @ViewBuilder
    private var eventDrawer: some View {
        Divider()
        Button {
            presentation.eventsShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.eventsShown
                      ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Events").font(.callout.weight(.medium))
                Spacer()
                /* The lane, on the closed strip too. It is the one fact
                   the drawer holds that a person needs WITHOUT opening
                   it: a gesture that appears to have done nothing is
                   either a slow Mac or a queue, and this says which. */
                if !presentation.eventsShown, timeline.depth > 0 {
                    Text(MirrorLaneDepth.sentence(timeline.depth))
                        .font(.caption)
                        .foregroundStyle(timeline.depth > 1
                                         ? .primary : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .help("Request history and outcomes")
        if presentation.eventsShown {
            Divider()
            MirrorEventStreamView(timeline: timeline, cycles: cycles,
                                  filter: $presentation.eventFilter)
                .frame(height: Self.drawerHeight)
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
