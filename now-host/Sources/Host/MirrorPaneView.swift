import AppKit
import SwiftUI
import MirrorKit
import MirrorKitUI

/// **The Mirror's drawn surface, in whichever container it is in.**
///
/// One view for both: the module's pane and the detached window render
/// this, over the same `NOWMirrorSource`. That is what makes "one model
/// behind both" a property of the code rather than a hope — there is no
/// second render path that could disagree, because there is no second
/// render path.
///
/// It owns two things and deliberately nothing else: the zoom stop, and
/// which keyboard policy `LiveMirrorView` runs under. **Zoom is a frame
/// around `LiveMirrorView` and never a parameter to `SceneView` or
/// `SceneRenderer`.** Those two take their size from the layout system
/// and hold no ambient state, which is the whole reason `RenderShot`
/// renders 1:1 whatever a person is looking at; a `zoom:` parameter
/// threaded down would break that at ~20 call sites — loudly, which is
/// the good kind of wrong, but it would still be wrong.
struct MirrorPaneView: View {

    /// Which container this instance is. It decides the keyboard policy
    /// and nothing else: everything visual is the same picture.
    enum Container: Equatable {
        /// One pane of NOW's main window, beside the sidebar and the
        /// host's own menu bar.
        case modulePane
        /// A window of its own, where the mirror is the only thing there
        /// is and may have the keyboard outright.
        case detachedWindow
    }

    @ObservedObject var source: NOWMirrorSource
    @ObservedObject var presentation: MirrorPresentation
    let container: Container

    var body: some View {
        VStack(spacing: 0) {
            surface
                .background(Color(nsColor: .windowBackgroundColor))
            /* **The pane has NO zoom bar.** Attached, the stop lives in
               the module's toolbar with the other controls a person
               reaches for — a second copy under the picture would be the
               same control in two places and half the pane's chrome. The
               detached window has no toolbar above it, so it keeps one. */
            if container == .detachedWindow {
                Divider()
                zoomBar
            }
        }
    }

    // MARK: - The picture

    @ViewBuilder
    private var surface: some View {
        if let factor = presentation.zoom.factor {
            /* A fixed frame inside a scroller. FitTransform computes
               scale == guest/view, so a frame of exactly guest × factor
               makes the renderer's own CTM scale equal `factor` — and
               because every stop is a power of two, each guest pixel
               lands on a whole number of host pixels. */
            ScrollView([.horizontal, .vertical]) {
                LiveMirrorView(controller: source, keyboard: keyboard)
                    .frame(width: guestSize.width * factor,
                           height: guestSize.height * factor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            /* **Fit costs nothing and is the default for a reason.**
               `LiveMirrorView` is already wrapped in a `GeometryReader`
               and `FitTransform` letterboxes to preserve the guest's
               aspect, so filling the box IS fitting it, with coordinates
               exact. An 832×624 guest at 100% does not fit the main
               window's default 820-point detail column, so a first run
               that opened at 100% would greet a person with a scrollbar
               where a Macintosh should be. */
            LiveMirrorView(controller: source, keyboard: keyboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /* **What the letterbox is made of.** `FitTransform` preserves the
       guest's aspect, so a pane taller than 4:3 has bands above and
       below the Macintosh. They were the window's own black, which read
       as a broken render rather than as empty space around a picture. */

    /// The guest's own screen, or the classic default until it says.
    private var guestSize: CGSize {
        guard let s = source.scene?.screen, s.w > 0, s.h > 0 else {
            return CGSize(width: 800, height: 600)
        }
        return CGSize(width: CGFloat(s.w), height: CGFloat(s.h))
    }

    // MARK: - The controls

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Picker("Zoom", selection: $presentation.zoom) {
                ForEach(MirrorZoom.allCases) { stop in
                    Text(stop.label).tag(stop)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
            if !source.running {
                Text("not running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - The keyboard

    private var keyboard: LiveMirrorView<NOWMirrorSource>.Keyboard {
        switch container {
        case .detachedWindow:
            return .ownsWindow
        case .modulePane:
            return .sharesWindow(hostReserved: Self.hostMenuCharacters())
        }
    }

    /// **Derived from the host's own menu, never remembered.**
    ///
    /// `KeyCaptureView` forwards nearly every ⌘ combination to the other
    /// Macintosh, which is right in a window of its own and catastrophic
    /// in a pane: ⌘⇧M, ⌘0, ⌘/ and the rest simply stop working, with
    /// nothing erroring. A hand-written list of the host's shortcuts
    /// would be a second place to be wrong and would rot the first time
    /// somebody added a menu item — so it is read off `NSApp.mainMenu`,
    /// the same object the shortcuts actually dispatch through.
    ///
    /// Matched on the character alone (see `KeyCaptureView.hostReserved`),
    /// so reserving ⌘⇧M reserves ⌘M with it. Over-reserving costs the
    /// guest a key; under-reserving costs the host a menu.
    static func hostMenuCharacters(_ menu: NSMenu? = NSApp?.mainMenu)
        -> Set<String> {
        var found = KeyCaptureView.hostReserved
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                let key = item.keyEquivalent.lowercased()
                if !key.isEmpty { found.insert(key) }
                if let sub = item.submenu { walk(sub) }
            }
        }
        if let menu { walk(menu) }
        return found
    }
}
