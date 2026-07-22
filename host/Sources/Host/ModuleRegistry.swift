import Foundation

/// Where a module sits in the sidebar. Everything is still one ordered list
/// — this only says which end of it a module belongs to.
enum ModulePlacement: Equatable, Sendable {
    /// A feature, listed in order.
    case list
    /// Pinned below a divider at the foot of the sidebar. Not a feature but
    /// the state of the link the features run over.
    case footer
}

struct ModuleDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    var placement: ModulePlacement = .list
    /// A footer row shows the live link state (dot + wire status) only for
    /// the module that IS the link. Others — Logs — show their summary.
    var showsLinkStatus: Bool = false
}

struct ModuleRegistry: Sendable {
    let modules: [ModuleDescriptor]

    init(modules: [ModuleDescriptor]) {
        precondition(Set(modules.map(\.id)).count == modules.count,
                     "Module identifiers must be unique")
        self.modules = modules
    }

    func module(id: String) -> ModuleDescriptor? {
        modules.first { $0.id == id }
    }

    /// The two halves of the sidebar, derived rather than stored, so id
    /// uniqueness, `module(id:)`, and the persisted selection keep reading
    /// from the one array no matter where a module is drawn.
    var listModules: [ModuleDescriptor] {
        modules.filter { $0.placement == .list }
    }

    var footerModules: [ModuleDescriptor] {
        modules.filter { $0.placement == .footer }
    }

    static let standard = ModuleRegistry(modules: [
        ModuleDescriptor(
            id: "screenshots",
            title: "Screenshots",
            symbol: "camera.viewfinder",
            summary: "Capture, browse, and save images from a classic Mac"
        ),
        ModuleDescriptor(
            id: "files",
            title: "Files",
            symbol: "folder",
            summary: "Browse and download from the classic Mac's share"
        ),
        ModuleDescriptor(
            id: "processes",
            title: "Processes",
            symbol: "cpu",
            summary: "What is running on the connected Mac"
        ),
        ModuleDescriptor(
            id: "console",
            title: "Console",
            symbol: "terminal",
            summary: "A shell into the connected Mac"
        ),
        ModuleDescriptor(
            id: "census",
            title: "Hardware",
            symbol: "cpu",
            summary: "Run and read the connected Mac's hardware census"
        ),
        ModuleDescriptor(
            id: "logs",
            title: "Logs",
            symbol: "text.alignleft",
            summary: "This Mac's event log",
            placement: .footer
        ),
        ModuleDescriptor(
            id: "settings",
            title: "Connection",
            symbol: "network",
            summary: "Listening port and connection status",
            placement: .footer,
            showsLinkStatus: true
        ),
    ])
}

