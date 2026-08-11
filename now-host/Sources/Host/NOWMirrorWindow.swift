import AppKit
import SwiftUI
import MirrorKit
import MirrorKitUI

/// **The mirror's detached container.** One of two; the other is
/// `MirrorPaneView` inside the main window, and they draw the same view
/// over the same source.
///
/// This used to argue that a window was the *only* right container,
/// because a detail pane beside a sidebar scales every coordinate a
/// person aims at into a box a third the size. The objection was real and
/// the answer is the zoom stops: `FitTransform` keeps the mapping exact
/// at any size, so what a pane was missing was never accuracy but room,
/// and a person who needs room can pick 200% — or take the whole thing
/// out into this window, which is what detaching is for.
///
/// It is deliberately thin, and thinner than it was. Everything a person
/// does lives in `LiveMirrorView`, everything the machine answers lives
/// in `NOWMirrorSource`, and **the poll is no longer this object's
/// business at all** — `MirrorRunControl` owns it. This owns a window and
/// its lifetime.
@MainActor
final class NOWMirrorWindow: NSObject, ObservableObject, NSWindowDelegate {

    private var window: NSWindow?
    @Published private(set) var isOpen = false
    private var didFit = false
    private let source: NOWMirrorSource
    private let presentation: MirrorPresentation
    /// The guest's screen, when something already knows it. Normally
    /// nothing does at this point — the window opens before the first
    /// scene arrives — and `fitToGuestScreen` corrects the window once
    /// the guest says. It used to default to 800×600, which is a claim
    /// about somebody else's machine made by the one object that never
    /// asks it anything.
    private let screen: MirrorKit.Scene.ScreenSize?
    private let requestedScale: CGFloat?

    init(source: NOWMirrorSource,
         presentation: MirrorPresentation,
         screen: MirrorKit.Scene.ScreenSize? = nil,
         launchOptions: MirrorLaunchOptions = .parse(
            ProcessInfo.processInfo.arguments)) {
        self.source = source
        self.presentation = presentation
        self.screen = screen
        requestedScale = launchOptions.scale
    }

    /// The window's own size while the guest's screen is unknown. Not a
    /// screen size and never used as one — see `show`.
    ///
    /// `openIfLaunchAsked` used to live beside this and does not any more:
    /// the round-3 integration moved that question to
    /// `HostAppState.mirrorFollowsTheConnection`, because with the Mirror
    /// embedded as a module there may be no window to ask. 019-one-screen
    /// edited the old function without seeing that; the constant it added
    /// is kept and the function is not.
    private static let beforeTheGuestSpeaks = NSSize(width: 720, height: 460)

    func show(title: String) {
        if window == nil {
            let controller = NSHostingController(
                rootView: MirrorPaneView(source: source,
                                         presentation: presentation,
                                         container: .detachedWindow))
            /* The WINDOW owns its size, not the scene inside it. Without
               this an arriving scene republishes its own ideal size as a
               window constraint, so the window jumps every time the guest
               opens something - the same defect the main window was fixed
               for on 2026-07-31. */
            controller.sizingOptions = []
            let w = NSWindow(contentViewController: controller)
            w.title = title
            let scale = requestedScale ?? 1
            if let screen = screen?.known {
                w.setContentSize(NSSize(width: CGFloat(screen.w) * scale,
                                        height: CGFloat(screen.h) * scale))
                /* A floor rather than a fixed size: below roughly half the
                   guest's own screen the Platinum chrome a person aims at -
                   a 16-point scroll arrow, an 11-point close box - stops
                   being reliably clickable with a real mouse. */
                w.contentMinSize = NSSize(width: screen.w / 2,
                                          height: screen.h / 2)
            } else {
                /* **A HOST WINDOW SIZE, NOT A GUEST SCREEN.** Nothing has
                   said how big the other machine's screen is, so this
                   claims nothing about it: it is a rectangle to put the
                   "screen size unknown" surface in until the first scene
                   lands, at which point `fitToGuestScreen` sizes the
                   window to the truth and sets the aspect and the floor.
                   Deliberately not 4:3 — a plausible aspect is what made
                   the old guess invisible. */
                w.setContentSize(Self.beforeTheGuestSpeaks)
            }
            w.setFrameAutosaveName("NOWMirrorWindow")
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        /* BEFORE it is shown, and again after the fit. A restored frame
           can already be off every display - the fit only moves corners
           further - and checking only afterwards left the window
           invisible for as long as the first scene took to arrive, which
           on a just-booted guest is many seconds of "Open Mirror did
           nothing". */
        if let w = window { Self.ensureOnScreen(w) }
        /* **NO `source.start()` HERE, and that is the point of the whole
           change rather than an omission.** An open window is not a
           running poll and never was — the two were merely welded
           together, and the weld is what let `--open-mirror` leave a
           window standing over a source that never ran (2026-08-06).
           `MirrorRunControl` owns starting, every face goes through
           `HostAppState.showMirror()`, and that function starts first and
           shows second. */
        isOpen = true
        presentation.isDetached = true
        /* NO NSApp.activate HERE, and that is the fix rather than an
           omission. Activating trips `applicationShouldHandleReopen`,
           whose job is to bring the MAIN window up - so asking for the
           mirror ended with the main window on top of it, looking
           exactly like the window had never opened. Three rounds went
           into an off-screen frame that was never the problem.
           A person clicking Open Mirror has this app frontmost already. */
        /* DEFERRED PAST THIS EVENT. The raise runs inside the button's
           own click, and the main window takes key back when that event
           finishes - so the mirror ended up behind it, on-screen and
           invisible, which read as "the window never opened". Its saved
           frame was 624,367 800x632 on a 2048x1122 screen the whole
           time; three fixes went into an off-screen frame that was never
           the problem, and reading the frame settled it in one step. */
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
        fitToGuestScreen()
    }

    /// **Size to the guest's own screen, once it says what that is.**
    ///
    /// The window opens before the first scene arrives, so its initial
    /// size is a guess. A mirror at the wrong aspect is not merely ugly:
    /// FitTransform letterboxes to keep coordinates exact, so a guessed
    /// 4:3 around a 832x624 desktop wastes a band a person keeps trying
    /// to click in. This corrects it once, on the first scene, and then
    /// leaves the window alone - it is the person's to size after that.
    private func fitToGuestScreen() {
        guard !didFit else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<40 {                      // ~10s of first scenes
                guard let self, let w = self.window else { return }
                if let s = self.source.scene?.screen.known {
                    self.didFit = true
                    let screenFit = min(1.0,
                                   min((w.screen?.visibleFrame.width ?? 1200)
                                       * 0.9 / CGFloat(s.w),
                                       (w.screen?.visibleFrame.height ?? 800)
                                       * 0.9 / CGFloat(s.h)))
                    let fits = min(self.requestedScale ?? screenFit,
                                   screenFit)
                    w.setContentSize(NSSize(width: CGFloat(s.w) * fits,
                                            height: CGFloat(s.h) * fits))
                    w.contentAspectRatio = NSSize(width: s.w, height: s.h)
                    w.contentMinSize = NSSize(width: CGFloat(s.w) / 2,
                                              height: CGFloat(s.h) / 2)
                    Self.ensureOnScreen(w)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// **A window a person cannot see is a window that does not work.**
    ///
    /// `setFrameAutosaveName` restores where this was last left, and
    /// resizing it to the guest's screen moves its corners - so a frame
    /// that was fine at one size can end up past the edge of every
    /// display. Seen once during this build: "Open Mirror" appeared to do
    /// nothing at all, and the window was live, key, polling and drawing
    /// somewhere nobody could look at.
    ///
    /// So after any programmatic resize, if the title bar is not
    /// reachable on some screen, it comes back to the middle of one.
    private static func ensureOnScreen(_ w: NSWindow) {
        let frame = w.frame
        /* The title bar specifically: a window whose body overlaps a
           screen but whose bar does not cannot be moved by hand, which
           is the same problem wearing a hat. */
        let bar = NSRect(x: frame.minX, y: frame.maxY - 24,
                         width: frame.width, height: 24)
        let reachable = NSScreen.screens.contains {
            $0.visibleFrame.intersects(bar)
        }
        if !reachable { w.center() }
    }

    /// **Closing re-attaches. It does not stop the machine.**
    ///
    /// This used to call `source.stop()` and the docstring below argued
    /// for it convincingly: a mirror nobody is looking at should not keep
    /// taking the guest's one transfer lane. The argument was right about
    /// cost and wrong about who was looking — an agent on the MCP socket
    /// is looking, and it never opens a window. Under two axes, closing
    /// this window says something about this Mac's screen and nothing
    /// about the classic Mac, so the Mirror simply comes back into the
    /// module's pane. Stopping is `MirrorRunControl.stop()`, and it has
    /// its own control on that page.
    func close() {
        window?.orderOut(nil)
        isOpen = false
        presentation.isDetached = false
    }

    /// Captures only the pixels NOW drew for the Mirror, paired with the exact
    /// immutable engine snapshot. It refuses while shadow and visible paths
    /// disagree or if either changes during AppKit's display capture.
    ///
    /// **Through `RenderShot`, not through the window's content view.**
    /// It used to call `bitmapImageRepForCachingDisplay` on
    /// `window?.contentView`, which was correct while a window was the
    /// only container and silently wrong the moment there were two: with
    /// the Mirror attached, `window` is nil and the export threw
    /// `emptyFrame` — an error naming a blank capture rather than a
    /// missing window, which is exactly the kind of misattributed failure
    /// this project keeps paying for.
    ///
    /// `RenderShot` is the better source anyway and by construction, not
    /// by luck: `SceneView.swift:5-6` states that the drawn pixels are
    /// exactly `RenderShot`'s, it takes its size as a parameter and sets
    /// `scale = 1`, so the evidence is 1:1 guest pixels whatever container
    /// or zoom stop a person happens to be looking at.
    func exportEvidence(to directory: URL) throws
        -> MirrorEvidenceExporter.Export {
        guard let engine = source.shadowEngine else {
            throw MirrorEvidenceExporter.ExportError.noSnapshot
        }
        return try MirrorEvidenceExporter(
            engine: engine, visibleScene: { [weak source] in source?.scene })
            .export(to: directory) { [weak source] in
                guard let scene = source?.scene else {
                    throw MirrorEvidenceExporter.ExportError.emptyFrame
                }
                return try RenderShot.png(scene: scene)
            }
    }

    /// The red button and `close()` mean the same thing, so they do the
    /// same thing: re-attach. **Emphatically no `source.stop()` here** —
    /// see `close()`. This is the single edit in the whole change most
    /// likely to be reverted by a reader who finds the old docstring
    /// persuasive, so the reason lives beside both.
    func windowWillClose(_ notification: Notification) {
        isOpen = false
        presentation.isDetached = false
    }
}
