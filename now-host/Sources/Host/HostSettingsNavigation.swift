import Foundation

/// One tab per settings surface behind the pill switcher in
/// `HostSettingsView`. Distinct from the `"settings"` MODULE id — that one
/// is Connections (`SettingsHostModule.swift`); this window sits outside
/// the module registry entirely and is reached by Cmd-, or a module's own
/// "Settings…" button.
enum HostSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case appearance
    case sidebar
    case mcp
    case web
    case logs
    case newConnections

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .sidebar: return "Sidebar"
        case .mcp: return "MCP"
        case .web: return "Web"
        case .logs: return "Logs"
        case .newConnections: return "New Connections"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .sidebar: return "sidebar.left"
        case .mcp: return "app.connected.to.app.below.fill"
        case .web: return "globe"
        case .logs: return "text.alignleft"
        case .newConnections: return "cursorarrow.motionlines"
        }
    }
}

/// The Settings window's own selection state, held once by the app
/// delegate alongside `AppearancePreferences` so it survives across
/// `showWindow` calls the same way the window controller itself does — see
/// `SettingsWindowController`'s own comment on why Cmd-, always reopens the
/// same object. A module's "Settings…" button and `showSettings(selecting:)`
/// both write `selectedTab`; the pill reads it.
@MainActor
final class HostSettingsNavigation: ObservableObject {
    @Published var selectedTab: HostSettingsTab = .appearance
}
