import AppKit
import SwiftUI

/// The one native Settings window. The delegate retains this controller and
/// the controller retains its closed window, so Command-, always reopens the
/// same object instead of growing a hidden window fleet.
///
/// A pill switcher over `HostSettingsTab` now sits inside it — Appearance
/// alongside the preferences moved out of MCP, Web, Logs and the sidebar's
/// own context menu, plus a "Defaults for New Connections" tab for
/// Continuity. `navigation` is owned by the delegate and outlives this
/// controller being torn down and rebuilt, so a module's deep-link
/// (`select(_:)`) and a fresh construction both land on the same object.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let navigation: HostSettingsNavigation

    init(preferences: AppearancePreferences,
         navigation: HostSettingsNavigation,
         sidebar: SidebarPreferences,
         state: HostAppState,
         registry: ModuleRegistry,
         defaults: UserDefaults) {
        self.navigation = navigation
        let hosting = NSHostingController(
            rootView: HostSettingsView(preferences: preferences,
                                       navigation: navigation,
                                       sidebar: sidebar,
                                       state: state,
                                       registry: registry,
                                       defaults: defaults))
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 460))
        window.contentMinSize = NSSize(width: 560, height: 380)
        window.setFrameAutosaveName("now-settings-window")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The deep-link landing seam: a module's "Settings…" button and
    /// `AppDelegate.openSettings(selecting:)` both call this rather than
    /// touching `navigation` directly, so the window controller stays the
    /// one place that knows how selection is stored.
    func select(_ tab: HostSettingsTab) {
        navigation.selectedTab = tab
    }

    /// Test seam: which tab is showing, without inspecting SwiftUI view
    /// state.
    var selectedTab: HostSettingsTab { navigation.selectedTab }
}
