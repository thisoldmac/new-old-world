import AppKit
import Combine
import SwiftUI

/// Owns the standalone window a broken-away Mirror pane lives in.
///
/// **One model, one window, one session.** This holds no state of its own
/// about the session or the scene — `MirrorModuleModel.isDetached` is the
/// one fact that has to travel in both directions, and this controller's
/// whole job is keeping it in sync with a real `NSWindow`:
///
/// - **Break Away → this window opens**, carrying the SAME model instance
///   the module page already has (never a second `MirrorModuleModel` — that
///   would double the guest traffic and give two panes fighting over the
///   same act plane).
/// - **The module page's own "Bring Back"** only flips `model.isDetached`
///   back — it has no reference to this controller or its window at all,
///   on purpose, so the placeholder view does not need one either. The
///   `$isDetached` watch below is what turns that flip into the real window
///   actually closing.
/// - **Closing the window by hand** (the titlebar button, ⌘W) is the other
///   direction: `windowWillClose` flips the model back so the module page
///   shows the pane again instead of a placeholder for a window that no
///   longer exists. The session is untouched either way — Stop is its own
///   button, and closing a window is not asking for that.
///
/// Constructed once per Mirror model and kept by whoever owns the
/// navigation (`HostRootView`), never per press — a second controller
/// watching the same model's `isDetached` would double-close on the first
/// flip.
@MainActor
final class MirrorDetachedWindowController: NSObject, NSWindowDelegate {
    private let model: MirrorModuleModel
    private var window: NSWindow?
    private var isDetachedWatch: AnyCancellable?

    init(model: MirrorModuleModel) {
        self.model = model
    }

    /// Opens the window, or raises the one already open.
    func show() {
        model.detach()
        if window == nil {
            let root = MirrorModuleView(model: model, isDetachedWindow: true)
            let controller = NSHostingController(rootView: root)
            /* Same reason `AppDelegate.openMainWindow` sets this: without it
               the window resizes to the pane's own preferred content size
               on every scene change, which for a scene taller than the
               display is a window nobody can drag back afterward. The
               drawing's own aspect ratio (`MirrorModuleView.drawing`'s
               `.aspectRatio`) is what sizes the guest's screen WITHIN
               whatever size this window is — that seam needs nothing new
               here to keep working. */
            controller.sizingOptions = []
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "Mirror"
            newWindow.setContentSize(NSSize(width: 720, height: 560))
            newWindow.contentMinSize = NSSize(width: 420, height: 340)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if isDetachedWatch == nil {
            isDetachedWatch = model.$isDetached
                .sink { [weak self] detached in
                    guard let self, !detached else { return }
                    self.window?.close()
                }
        }
    }

    /// The window closed by hand. Returns the pane to the module page
    /// rather than ending the session.
    func windowWillClose(_ notification: Notification) {
        window = nil
        model.reattach()
    }
}
