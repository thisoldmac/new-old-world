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

    /// Module ids that have been renamed, old name to new.
    ///
    /// The selected module is written to preferences by id, so renaming one
    /// silently retires whoever was last looking at it: their saved
    /// selection stops resolving and the next launch drops them on
    /// Screenshots with no explanation. A rename therefore leaves a
    /// forwarding address here rather than only in the descriptor.
    static let renamedIDs: [String: String] = ["agent": "mcp"]

    /// The module a saved selection means today, following one rename.
    func resolvingRenames(id: String) -> ModuleDescriptor? {
        module(id: id)
            ?? Self.renamedIDs[id].flatMap { module(id: $0) }
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
        /* Straight after Files because it is the same subject seen from
           this side: Files is what the two machines exchange, iCloud is
           what of THIS Mac's cloud joins that exchange. It is the one
           list page about this side rather than the other Mac — kept in
           the list anyway, because it is a feature a person turns on,
           not the state of the link. */
        ModuleDescriptor(
            id: "icloud",
            title: "iCloud",
            symbol: "icloud",
            summary: "What of this Mac's iCloud the classic Mac may browse"
        ),
        ModuleDescriptor(
            id: "processes",
            title: "Processes",
            symbol: "cpu",
            summary: "What is running on the connected Mac"
        ),
        /* Straight after Processes, because it answers the next question
           about the same subject: Processes is what is running, Mirror is
           what those programs have on screen. It sits above Console for the
           same reason Screenshots does — both are ways of LOOKING at the
           machine, and the pages that DO things to it come after. */
        ModuleDescriptor(
            id: "mirror",
            title: "Mirror",
            symbol: "macwindow.on.rectangle",
            summary: "The other Mac's screen, drawn from what it says is there"
        ),
        ModuleDescriptor(
            id: "console",
            title: "Console",
            symbol: "terminal",
            summary: "A shell into the connected Mac"
        ),
        /* Beside Console because it is the same posture — a page that DOES
           things to the machine, through a model instead of a verb table.
           The provider configuration lives on this page too, per the
           no-preferences-window rule. */
        ModuleDescriptor(
            id: "chat",
            title: "Chat",
            symbol: "bubble.left.and.bubble.right",
            summary: "Talk to a model that can see and drive the connected Mac"
        ),
        /* Above the machine-describing pages on purpose: this one is about
           the OTHER Macs - which are connected and which is being driven -
           where Census and Software describe the one already chosen. The
           footer's Connection row keeps its own job (this side's port and
           link state) and is a different question. */
        ModuleDescriptor(
            id: "connections",
            title: "Connections",
            symbol: "desktopcomputer.and.arrow.down",
            summary: "Which Macs are connected, and which one is being driven"
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
        /* Beside Diagnostics rather than beside Connections: this page
           is what the OTHER Mac says about its networking, which is a
           measurement of that machine - the footer's Connections page is
           about which Macs this host is talking to. Different questions,
           and putting them together would suggest one answer. */
        ModuleDescriptor(
            id: "networking",
            title: "Networking",
            symbol: "network",
            summary: "The connected Mac's link, address and network hardware"
        ),
        ModuleDescriptor(
            id: "software",
            title: "Software",
            symbol: "shippingbox",
            summary: "What is installed on the connected Mac"
        ),
        /* In the footer rather than the list, and above Logs, because the
           list is what you can do to the OTHER Mac and the footer is the
           state of this side. This page is about this host: the server an
           agent reaches it through, and what came in that way. It sits
           beside Logs because part of it is the same record read a
           different way — Logs is everything that happened, this is the
           part of it somebody else caused.

           Named for the TRANSPORT rather than for the caller, because that
           is what the page now controls: MCP is the server this host runs
           and this side owns its lifecycle. The audit model underneath is
           deliberately NOT named that — see MCPModuleView. */
        ModuleDescriptor(
            id: "mcp",
            title: "MCP",
            symbol: "app.connected.to.app.below.fill",
            summary: "The MCP server agents reach this Mac through",
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

