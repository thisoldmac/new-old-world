import Foundation

/// Copyable client configuration without custody of the credential itself.
/// Bearer recipes name an environment variable; OAuth recipes let the client
/// discover NOW's loopback authorization server and ask the person to consent.
/// These describe supported configuration shapes; successful connection is
/// reported by the HTTP diagnostic rather than implied by showing a recipe.
struct MCPHTTPClientRecipes: Equatable {
    struct Recipe: Equatable, Identifiable {
        let client: String
        let configuration: String
        var id: String { client }
    }

    let endpoint: String

    var bearer: [Recipe] {
        [
            .init(client: "Codex", configuration: """
                [mcp_servers.now]
                url = "\(endpoint)"
                bearer_token_env_var = "NOW_MCP_BEARER_TOKEN"
                """),
            .init(client: "Claude Code", configuration: """
                {
                  "mcpServers": {
                    "now": {
                      "type": "http",
                      "url": "\(endpoint)",
                      "headers": {
                        "Authorization": "Bearer ${NOW_MCP_BEARER_TOKEN}"
                      }
                    }
                  }
                }
                """),
            .init(client: "Agentis", configuration: """
                Name: New Old World
                Transport: Streamable HTTP
                URL: \(endpoint)
                Authentication: Bearer token
                Token source: NOW_MCP_BEARER_TOKEN
                """),
        ]
    }

    var oauth: [Recipe] {
        [
            .init(client: "Codex", configuration: """
                [mcp_servers.now]
                url = "\(endpoint)"
                """),
            .init(client: "Claude Code", configuration: """
                {
                  "mcpServers": {
                    "now": {
                      "type": "http",
                      "url": "\(endpoint)"
                    }
                  }
                }
                """),
        ]
    }
}
