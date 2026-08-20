import Foundation

/// A transport-free failure for stale pre-alpha client configurations.
/// stdout stays empty so no caller can mistake the diagnostic for MCP.
enum MCPStdioTombstone {
    static let supportURL = "https://docs.newoldworldmac.com/"
        + "user-guide/reference/modules/mcp/"

    static let diagnostic = "New Old World no longer supports MCP over "
        + "Standard Input. Configure Streamable HTTP in New Old World > MCP. "
        + supportURL

    static func writeDiagnostic(to output: FileHandle = .standardError) {
        output.write(Data((diagnostic + "\n").utf8))
    }
}
