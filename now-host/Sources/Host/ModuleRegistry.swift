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
    var tier: ModuleTier = .core
    var domains: [String] = []
    var featureID: ProductFeatureID? = nil
}

@MainActor
struct ModuleRegistry {
    let definitions: [HostModuleDefinition]
    let modules: [ModuleDescriptor]

    init(modules: [ModuleDescriptor]) {
        precondition(Set(modules.map(\.id)).count == modules.count,
                     "Module identifiers must be unique")
        definitions = modules.map { HostModuleDefinition(descriptor: $0) }
        self.modules = modules
    }

    init(definitions: [HostModuleDefinition]) {
        let modules = definitions.map(\.descriptor)
        precondition(Set(modules.map(\.id)).count == modules.count,
                     "Module identifiers must be unique")
        self.definitions = definitions
        self.modules = modules
    }

    func module(id: String) -> ModuleDescriptor? {
        modules.first { $0.id == id }
    }

    func definition(id: String) -> HostModuleDefinition? {
        definitions.first { $0.descriptor.id == id }
    }

    /// Module ids that have been renamed, old name to new.
    ///
    /// The selected module is written to preferences by id, so renaming one
    /// silently retires whoever was last looking at it: their saved
    /// selection stops resolving and the next launch drops them on the
    /// first module with no explanation. A rename therefore leaves a
    /// forwarding address here rather than only in the descriptor.
    static let renamedIDs: [String: String] = [
        "agent": "mcp",
        "screenshots": "screen",
        "connections": "settings",
    ]

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

    /* The summaries below say WHICH machine each page is about, in the
       vocabulary MachineNaming carries: the machine being driven is the
       old world mac, the machine the app runs on is this Mac. They are
       written through those constants rather than spelled out, because a
       sidebar that says "the connected Mac" while every page under it says
       something else is how the copy drifted in the first place. */
    private static let standardDescriptors: [ModuleDescriptor] = [
        ModuleDescriptor(
            /* Not "Screenshots": the page took a still picture when it was
               named, and it now also carries the live stream and its
               recording. One noun for the subject both of those are about. */
            id: "screen",
            title: "Screen",
            symbol: "camera.viewfinder",
            summary: "Capture, stream and save "
                + "\(MachineNaming.possessive(nil)) screen"
        ),
        ModuleDescriptor(
            id: "files",
            title: "Files",
            symbol: "folder",
            summary: "Browse \(MachineNaming.possessive(nil)) share, and "
                + "move files both ways"
        ),
        /* Straight after Files because it is the same subject seen from
           this side: Files is what the two machines exchange, iCloud is
           what of THIS Mac's cloud joins that exchange. It is the one
           list page about this side rather than the machine being driven
           — kept in the list anyway, because it is a feature a person
           turns on, not the state of the link. */
        ModuleDescriptor(
            id: "icloud",
            title: "iCloud",
            symbol: "icloud",
            summary: "What of \(MachineNaming.thisMac)'s iCloud "
                + "\(MachineNaming.simpleReference) may browse",
            tier: .experimental
        ),
        ModuleDescriptor(
            id: "processes",
            title: "Processes",
            symbol: "cpu",
            summary: "What is running on \(MachineNaming.simpleReference), "
                + "and quit or raise it"
        ),
        /* Kept where the Mirror page has always been, and now beside
           Processes for a reason rather than by inheritance: it answers
           the next question about the same subject — Processes is what is
           running, Mirror is what those programs have on screen — and it
           sits above Console for the same reason Screen does: both are
           ways of LOOKING at the machine, and the pages that DO things to
           it come after.

           **This page DRAWS the other Macintosh.** It used to own only
           whether that machine was ready and one instance's lifecycle,
           explicitly "not the drawing" — the drawing lived in a window
           this page had a button for. It is the pane now, with the window
           kept as the detached container, so a person on this page is
           looking at the machine rather than at a button that opens it
           somewhere else. It is also the only module that owns a live
           poll, and that poll deliberately keeps running while another
           module is showing. */
        ModuleDescriptor(
            id: "mirror",
            title: "Mirror",
            symbol: "macwindow.on.rectangle",
            summary: "See and drive \(MachineNaming.simpleReference), "
                + "here or in its own window",
            tier: .experimental
        ),
        ConsoleHostModule.definition.descriptor,
        /* Beside Console because it is the same posture — a page that DOES
           things to the machine, through a model instead of a verb table.
           The provider configuration lives on this page too, per the
           no-preferences-window rule. */
        ModuleDescriptor(
            id: "chat",
            title: "Chat",
            symbol: "bubble.left.and.bubble.right",
            summary: "Talk to a model that can see and drive "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental
        ),
        ModuleDescriptor(
            id: "web",
            title: "Web",
            symbol: "globe",
            summary: "Translate modern pages for a browser on "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental
        ),
        ModuleDescriptor(
            id: "development",
            title: "Development",
            symbol: "hammer",
            summary: "Projects, toolchains, builds and runs for "
                + "\(MachineNaming.simpleReference)",
            tier: .experimental
        ),
        CensusHostModule.definition.descriptor,
        /* Immediately after Hardware, because it answers the same class of
           question by the other route: Hardware is what the machine IS, and
           this is what the machine can MEASURE about itself. A person
           chasing a slow transfer or a wrong-looking screenshot reads them
           together. */
        ModuleDescriptor(
            id: "diagnostics",
            title: "Diagnostics",
            symbol: "stethoscope",
            /* It measures the machine being driven, not this one. The old
               summary said "this Mac's screen reads", which named the
               wrong machine outright: nothing here reads this Mac. */
            summary: "Measure \(MachineNaming.possessive(nil)) screen "
                + "reads and file transfers",
            tier: .debug
        ),
        /* Beside Diagnostics rather than beside Connections: this page
           is what the machine being driven says about its own networking,
           which is a measurement of that machine - the footer's
           Connections page is about which machines this one is talking to.
           Different questions, and putting them together would suggest one
           answer. */
        NetworkingHostModule.definition.descriptor,
        ModuleDescriptor(
            id: "software",
            title: "Software",
            symbol: "shippingbox",
            summary: "What is installed on "
                + "\(MachineNaming.simpleReference), and launching it"
        ),
        /* In the footer rather than the list, and above Logs, because the
           list is what you can do to the machine being driven and the
           footer is the state of this side. This page is about this host: the server an
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
            summary: "The MCP server agents reach "
                + "\(MachineNaming.thisMac) through",
            placement: .footer,
            tier: .experimental
        ),
        ModuleDescriptor(
            id: "logs",
            title: "Logs",
            symbol: "text.alignleft",
            summary: "What \(MachineNaming.thisMac) has recorded happening",
            placement: .footer,
            tier: .debug
        ),
        /* The link, and who is on it — one page, formerly two rows.
           "Connections" sat in the list (the roster of machines) while this
           one sat in the footer (the port and the link state), and neither
           half stood up alone: the roster explained an empty page by naming
           the port, and this one explained the port by describing a machine
           that would dial into it. It keeps the FOOTER placement and the
           link dot, because the state of the link is what the footer is
           for; the roster came down to it. */
        ModuleDescriptor(
            /* The id is a preferences key and the ⌘, target, not a name: it
               is what a saved selection and the Settings menu item both
               spell, so it stays put while the title says what the page is
               about. */
            id: "settings",
            title: "Connections",
            symbol: "network",
            summary: "The port \(MachineNaming.thisMac) listens on, and "
                + "which \(MachineNaming.properNounPlural) are on it",
            placement: .footer,
            showsLinkStatus: true
        ),
    ]

    static let standard = ModuleRegistry(definitions:
        standardDescriptors.map {
            LegacyHostModuleDefinitions.definition(for: $0)
        })
}
