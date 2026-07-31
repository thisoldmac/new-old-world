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
        /* Immediately after Hardware, because it answers the same class of
           question by the other route: Hardware is what the machine IS, and
           this is what the machine can MEASURE about itself. A person
           chasing a slow transfer or a wrong-looking screenshot reads them
           together. */
        ModuleDescriptor(
            id: "diagnostics",
            title: "Diagnostics",
            symbol: "stethoscope",
            summary: "Measure this Mac's screen reads and transfers"
        ),
        ModuleDescriptor(
            id: "software",
            title: "Software",
            symbol: "shippingbox",
            summary: "What is installed on the connected Mac"
        ),
        /* In the footer rather than the list, and above Logs, because the
           list is what you can do to the OTHER Mac and the footer is the
           state of this side. This page is about this host: who has been
           driving it and what they did. It sits beside Logs because it is
           the same record read a different way — Logs is everything that
           happened, this is the part of it somebody else caused. */
        ModuleDescriptor(
            id: "agent",
            title: "Agent",
            symbol: "person.badge.shield.checkmark",
            summary: "What an agent has done to this Mac",
            placement: .footer
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

