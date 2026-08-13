import AppKit
import SwiftUI

/// The one native Settings window. The delegate retains this controller and
/// the controller retains its closed window, so Command-, always reopens the
/// same object instead of growing a hidden window fleet.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: AppearancePreferences) {
        let hosting = NSHostingController(
            rootView: HostSettingsView(preferences: preferences))
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 400))
        window.contentMinSize = NSSize(width: 460, height: 340)
        window.setFrameAutosaveName("now-settings-window")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
