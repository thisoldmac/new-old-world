import AppKit
import SwiftUI
import MirrorKit
import MirrorKitUI

/// The mirror's own window, drawn by NOW.
///
/// A separate window rather than a Workshop pane, and that is a decision
/// rather than an inheritance: a mirror is a whole other Macintosh's
/// screen, and putting it in a detail pane beside a sidebar means every
/// coordinate a person aims at is scaled into a box a third the size.
/// `FitTransform` letterboxes to preserve the guest's aspect, so the
/// mapping stays exact at any size — but only a window can be given the
/// size that makes the target big enough to hit.
///
/// It is deliberately thin. Everything a person does lives in
/// `LiveMirrorView`, and everything the machine answers lives in
/// `NOWMirrorSource`; this owns a window and its lifetime.
@MainActor
final class NOWMirrorWindow: NSObject, ObservableObject, NSWindowDelegate {

    private var window: NSWindow?
    @Published private(set) var isOpen = false
    private var didFit = false
    private let source: NOWMirrorSource
    private let screen: MirrorKit.Scene.ScreenSize
    private let requestedScale: CGFloat?

    init(source: NOWMirrorSource,
         screen: MirrorKit.Scene.ScreenSize = .init(w: 800, h: 600),
         launchOptions: MirrorLaunchOptions = .parse(
            ProcessInfo.processInfo.arguments)) {
        self.source = source
        self.screen = screen
        requestedScale = launchOptions.scale
        openAtLaunch = launchOptions.openAtLaunch
    }

    private let openAtLaunch: Bool

    /// Opens the Mirror once a Mac is connected, when the launch asked for
    /// it. Called on every connection state change and guarded by `isOpen`,
    /// because a guest that dials in, drops and redials must not stack
    /// windows — and because the request arrives before any guest does.
    func openIfLaunchAsked(title: String) {
        guard openAtLaunch else { return }
        guard !isOpen else {
            /* **AN OPEN WINDOW IS NOT A RUNNING POLL.** `show` calls
               `source.start()`, and start REFUSES when no Mac is active
               yet — it has nothing to poll. At launch that is the
               ordinary order of events: the window request arrives with
               the first connection change, before the listener has an
               active key. The guard used to end here, so the window
               stood open over a source that never ran: scenes frozen at
               whatever the connect walk produced, `mirror_drive`
               refusing with "no pinned Mac", and nothing on the window
               saying why. Watched 2026-08-06.

               Every later connection change comes through this same
               door, so asking again costs nothing and is the only place
               that can. `start()` is idempotent while running. */
            if !source.running { source.start() }
            return
        }
        show(title: title)
    }

    func show(title: String) {
        if window == nil {
            let controller = NSHostingController(
                rootView: LiveMirrorView(controller: source))
            /* The WINDOW owns its size, not the scene inside it. Without
               this an arriving scene republishes its own ideal size as a
               window constraint, so the window jumps every time the guest
               opens something - the same defect the main window was fixed
               for on 2026-07-31. */
            controller.sizingOptions = []
            let w = NSWindow(contentViewController: controller)
            w.title = title
            let scale = requestedScale ?? 1
            w.setContentSize(NSSize(width: CGFloat(screen.w) * scale,
                                    height: CGFloat(screen.h) * scale))
            /* A floor rather than a fixed size: below roughly half the
               guest's own screen the Platinum chrome a person aims at -
               a 16-point scroll arrow, an 11-point close box - stops
               being reliably clickable with a real mouse. */
            w.contentMinSize = NSSize(width: screen.w / 2, height: screen.h / 2)
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
        source.start()
        /* **AND AGAIN UNTIL IT TAKES.** `start()` REFUSES when no Mac is
           active yet — it has nothing to poll — and at launch that is the
           ordinary order of events: `--open-mirror` fires on the first
           connection change, before the listener has an active key. The
           window then stood open over a source that never ran: scenes
           frozen at whatever the connect walk produced, `mirror_drive`
           refusing with "no pinned Mac", and nothing on the window saying
           why. Watched 2026-08-06 while relaunching a live session.

           Bounded and cheap, like `fitToGuestScreen` beside it: a poll
           that has already started returns immediately, and a launch with
           no Mac at all gives up after ten seconds exactly as before. */
        if !source.running { retryStart() }
        isOpen = true
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

    private func retryStart() {
        Task { @MainActor [weak self] in
            for _ in 0..<40 {                          // ~10s
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.isOpen else { return }
                if self.source.running { return }
                self.source.start()
            }
        }
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
                if let s = self.source.scene?.screen, s.w > 0, s.h > 0 {
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

    func close() {
        source.stop()
        window?.orderOut(nil)
        isOpen = false
    }

    /// Captures only the pixels NOW drew for the Mirror, paired with the exact
    /// immutable engine snapshot. It refuses while shadow and visible paths
    /// disagree or if either changes during AppKit's display capture.
    func exportEvidence(to directory: URL) throws
        -> MirrorEvidenceExporter.Export {
        guard let engine = source.shadowEngine else {
            throw MirrorEvidenceExporter.ExportError.noSnapshot
        }
        return try MirrorEvidenceExporter(
            engine: engine, visibleScene: { [weak source] in source?.scene })
            .export(to: directory) { [weak self] in
                guard let view = self?.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(
                        in: view.bounds) else {
                    throw MirrorEvidenceExporter.ExportError.emptyFrame
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                return rep.representation(using: .png,
                                          properties: [:]) ?? Data()
            }
    }

    /// Closing the window stops the poll. A mirror nobody is looking at
    /// should not keep taking the guest's one transfer lane — the machine
    /// is cooperatively scheduled and every walk is time it is not doing
    /// what its user asked.
    func windowWillClose(_ notification: Notification) {
        source.stop()
        isOpen = false
    }
}
