import Foundation
import NOWAgentIntegration

/// Who invoked something, carried BESIDE the audit event rather than inside
/// it: `HostProjectionAuditEvent` deliberately stays argument-free and
/// identity-free, and this rides the same seams without changing its shape.
/// The presence ledger (`AgentCompanionActivity`) is untouched — the records
/// store is a separate answer to a separate question.
struct MCPAgentIdentity: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case api
        case mcpHTTP
        case mcpStdio
        case chat
        case appIntent
        /// A row written by a newer or retired face. Keep its spelling so
        /// opening an old database never rewrites history into a known kind.
        case unknown(String)

        init(databaseValue: String) {
            switch databaseValue {
            case "api": self = .api
            case "mcp-http": self = .mcpHTTP
            case "mcp-stdio": self = .mcpStdio
            case "chat": self = .chat
            case "intent": self = .appIntent
            default: self = .unknown(databaseValue)
            }
        }

        var databaseValue: String {
            switch self {
            case .api: return "api"
            case .mcpHTTP: return "mcp-http"
            case .mcpStdio: return "mcp-stdio"
            case .chat: return "chat"
            case .appIntent: return "intent"
            case .unknown(let raw): return raw
            }
        }
    }

    let kind: Kind
    /// From MCP `initialize`'s clientInfo where a transport has one; empty
    /// means unknown, and unknowns of one kind share one agent row.
    var clientName: String = ""
    var clientVersion: String = ""
    /// HTTP: the `Mcp-Session-Id`. stdio: `pid:<n>`. Nil where the face has
    /// no session (chat, intents).
    var sessionKey: String? = nil

    /// ClientInfo strings are caller-supplied; bound and strip control
    /// characters before they reach a row a person reads.
    static func bounded(_ raw: String?) -> String {
        guard let raw else { return "" }
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(200))
    }
}

struct MCPAgentRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let kind: MCPAgentIdentity.Kind
    let clientName: String
    let clientVersion: String
    let firstSeen: Date
    let lastSeen: Date

    /// What a row or a modal calls this agent.
    var displayName: String {
        if clientName.isEmpty {
            switch kind {
            case .api: return "NOW API client"
            case .mcpHTTP: return "Unknown HTTP client"
            case .mcpStdio: return "Unknown stdio client"
            case .chat: return "Chat"
            case .appIntent: return "App Intent"
            case .unknown: return "Unknown legacy client"
            }
        }
        return clientVersion.isEmpty
            ? clientName : "\(clientName) \(clientVersion)"
    }
}

struct MCPSessionRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let agentID: Int64
    let sessionKey: String?
    let startedAt: Date
    let lastSeen: Date
    let firstInitializedAt: Date?
    let lastInitializedAt: Date?
}

/// The latest successful initialize for one transport, separate from what
/// that client later asked the host to do. These facts never leave this
/// installation.
struct MCPInitializationEvidence: Equatable, Sendable {
    let kind: MCPAgentIdentity.Kind
    let agentName: String
    let clientName: String
    let clientVersion: String
    let sessionKey: String
    let firstSeen: Date
    let lastSeen: Date
}

struct MCPTargetRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let machineID: String
    let firstSeen: Date
    let lastSeen: Date
}

struct MCPActionRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let at: Date
    let agentID: Int64
    let sessionID: Int64?
    let targetID: Int64?
    let capability: String
    let face: HostInvokingFace
    let outcome: HostProjectionAuditEvent.Outcome
    let reason: String?
}

/// An action joined with the names the UI shows beside it.
struct MCPActionRow: Identifiable, Equatable, Sendable {
    let action: MCPActionRecord
    let agentName: String
    let targetMachine: String?

    var id: Int64 { action.id }
}

/// The history card's filter and paging. Everything optional; nothing set
/// means "the newest actions, whoever did them, wherever they landed".
struct MCPActionQuery: Equatable, Sendable {
    var outcome: HostProjectionAuditEvent.Outcome?
    var agentID: Int64?
    var targetID: Int64?
    var sessionID: Int64?
    var limit = 50
    var beforeActionID: Int64?
}

/// Per-entity tallies the modal's facts grid shows.
struct MCPOutcomeCounts: Equatable, Sendable {
    var answered = 0
    var refused = 0
    var denied = 0

    var total: Int { answered + refused + denied }
}
