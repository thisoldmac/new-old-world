import SwiftUI

private enum MCPHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "MCP's host activity services are unavailable."
    }
}

/// Owns the MCP page's presentation boundary. The delegate still owns the
/// sockets, and the activity ledgers remain shared application services
/// because Chat and the transport implementations also write them.
@MainActor
final class MCPHostModuleRuntime: HostModuleRuntime {
    let activity: AgentActivityModel
    let companions: AgentCompanionModel
    let listener: GuestListener
    let transportSettings: MCPTransportSettingsModel
    /// May be a detached model on a host that never runs oauth mode; the
    /// page then simply has no consent rows to draw.
    let oauthConsent: MCPOAuthConsentModel
    /// The page's card arrangement, owned here so it persists through the
    /// same defaults every other module preference travels in.
    let cardLayout: MCPCardLayoutModel
    /// `{ context.showSettings(.mcp) }`, captured once at construction the
    /// same way `MirrorHostModule` captures `context.selectModule` — the
    /// page's "Settings…" button for the start-automatically toggles that
    /// moved out of it.
    let openSettings: () -> Void
    private(set) var startStdio: (() -> Void)?
    private(set) var stopStdio: (() -> Void)?
    private(set) var startHTTP: (() -> Void)?
    private(set) var stopHTTP: (() -> Void)?

    init(context: HostModuleContext) throws {
        guard let activity = context.agentActivity,
              let companions = context.agentCompanions else {
            throw MCPHostModuleError.missingServices
        }
        self.activity = activity
        self.companions = companions
        oauthConsent = context.mcpOAuthConsent ?? MCPOAuthConsentModel()
        cardLayout = MCPCardLayoutModel(defaults: context.defaults)
        listener = context.listener
        transportSettings = MCPTransportSettingsModel(
            defaults: context.defaults)
        openSettings = { context.showSettings(.mcp) }
    }

    func configureTransports(
        startStdio: @escaping () -> Void,
        stopStdio: @escaping () -> Void,
        startHTTP: @escaping () -> Void,
        stopHTTP: @escaping () -> Void
    ) {
        self.startStdio = startStdio
        self.stopStdio = stopStdio
        self.startHTTP = startHTTP
        self.stopHTTP = stopHTTP
    }

    func shutDown() {
        startStdio = nil
        stopStdio = nil
        startHTTP = nil
        stopHTTP = nil
    }
}

@MainActor
enum MCPHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "mcp",
            title: "MCP",
            symbol: "app.connected.to.app.below.fill",
            summary: "The MCP server agents reach "
                + "\(MachineNaming.thisMac) through",
            placement: .footer,
            tier: .experimental),
        makeRuntime: { try MCPHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? MCPHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The MCP runtime has the wrong type."))
            }
            return AnyView(MCPModuleView(
                model: runtime.activity,
                companions: runtime.companions,
                listener: runtime.listener,
                settings: runtime.transportSettings,
                oauthConsent: runtime.oauthConsent,
                openSettings: runtime.openSettings,
                startStdio: runtime.startStdio,
                stopStdio: runtime.stopStdio,
                startHTTP: runtime.startHTTP,
                stopHTTP: runtime.stopHTTP,
                layoutModel: runtime.cardLayout))
        })
}
