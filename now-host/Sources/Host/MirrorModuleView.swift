import SwiftUI

/// **The Mirror module: the other Macintosh, and the controls over it.**
///
/// The page used to be controls only, and said so in `ModuleRegistry`:
/// "this page owns whether that Mac is ready for it and one instance's
/// lifecycle, *not the drawing*." It draws now. A person on the Mirror
/// page is looking at the machine rather than at a button that opens a
/// window somewhere else.
///
/// Two states, and only two, because the Mirror has exactly two axes:
///
/// - **Attached** — the guest's screen fills the top of the pane and the
///   controls sit under it in a split a person can drag.
/// - **Detached** — the screen is in `NOWMirrorWindow` and this page is
///   the controls alone, saying where the picture went.
///
/// Whether it is *running* is the other axis and is orthogonal to both:
/// the poll keeps going while another module is showing, while the pane
/// is destroyed, and while nobody is looking at all — because
/// `now_mirror_drive` and the fidelity sweep read the same source with no
/// window in the picture, and a drive that starts refusing because
/// somebody clicked Console is a defect nothing on either machine names.
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
        Group {
            if presentation.isDetached {
                controls
            } else {
                VSplitView {
                    MirrorPaneView(source: source,
                                   presentation: presentation,
                                   container: .modulePane)
                        .frame(minHeight: 240, idealHeight: 480)
                    controls
                        .frame(minHeight: 120)
                }
            }
        }
        /* The window follows the persisted axis rather than the other way
           round, so a relaunch that restores `isDetached` puts the Mirror
           back in its window without anybody clicking Detach. */
        .onAppear { syncWindow() }
        .onChange(of: presentation.isDetached) { _ in syncWindow() }
    }

    private func syncWindow() {
        if presentation.isDetached {
            if !window.isOpen {
                window.show(title: "Mirror — \(connectedMachineName)")
            }
        } else if window.isOpen {
            window.close()
        }
    }

    private var controls: some View {
        MirrorControlView(model: model,
                          run: run,
                          presentation: presentation,
                          timeline: timeline,
                          cycles: cycles)
    }
}
