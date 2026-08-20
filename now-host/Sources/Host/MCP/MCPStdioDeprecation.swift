import Foundation

/// The compatibility-window message shared by the stdio process and the MCP
/// page. It intentionally contains neither the configured port nor a token:
/// the running app owns those values and shows a copyable, current recipe.
enum MCPStdioDeprecation {
    static let supportURL = "https://docs.newoldworldmac.com/"
        + "user-guide/reference/modules/mcp/"

    static let warning = "New Old World MCP Standard Input is deprecated. "
        + "Migrate to Streamable HTTP: open New Old World > MCP > HTTP and "
        + "copy the configured loopback URL. " + supportURL

    static func writeWarning(to output: FileHandle = .standardError) {
        output.write(Data((warning + "\n").utf8))
    }
}

/// Bounded, path-free presentation of the two different local-use signals.
/// The records store already sanitises caller-supplied client identity; this
/// type keeps date formatting and empty-state language out of the SwiftUI
/// control surface.
struct MCPStdioEvidencePresentation: Equatable {
    let lastInitialization: String
    let lastAction: String
    let scope: String

    init(
        initialization: MCPInitializationEvidence?,
        action: MCPActionRow?,
        stamp: (Date) -> String
    ) {
        if let initialization {
            lastInitialization = "\(initialization.agentName) · "
                + stamp(initialization.lastSeen)
        } else {
            lastInitialization = "None recorded"
        }
        if let action {
            lastAction = "\(action.agentName) · \(action.action.capability) · "
                + stamp(action.action.at)
        } else {
            lastAction = "None recorded"
        }
        scope = "This evidence is from this installation only."
    }
}
