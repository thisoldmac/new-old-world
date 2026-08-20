import Foundation

/* The chat harness's own vocabulary — provider-neutral. Anthropic and
   the OpenAI-compatible dialects both translate to and from these
   shapes inside their providers; nothing outside a provider ever sees
   a wire-format detail. The refusal codes are the contract's
   chat.result enum, stated there once; this file mirrors the spelling
   because the harness is what produces them. */

/// A refusal with the contract's own code vocabulary — CloudFault's
/// shape, for the same reason: the code travels, the reason is shown.
enum ChatFault: Error {
    case refuse(code: String, reason: String)

    static func from(_ error: Error) -> (code: String, reason: String) {
        if case .refuse(let code, let reason) = error as? ChatFault {
            return (code, reason)
        }
        if let urlError = error as? URLError {
            return ("unreachable", urlError.localizedDescription)
        }
        return ("provider-error", "\(error)")
    }
}

/// One model a provider offers. `wireID` is what the guest's catalog
/// carries and what chat.send hands back — provider-prefixed so a
/// choice is unambiguous across providers.
struct ChatModel: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let displayName: String

    var wireID: String { "\(providerID)/\(modelID)" }
}

/// How far a provider's turn can reach past its own words.
///
/// Declared by the provider rather than assumed by the harness, because
/// two of the six cannot use tools at all and used to present in the
/// model popup exactly like the four that can — so choosing a model was
/// silently choosing between an agent and a chatbot, and the person
/// found out from the model's own apology a turn later.
///
/// The reason travels: it becomes part of the provider entry's `detail`,
/// which the guest's popup already draws.
enum ChatToolReach: Equatable, Sendable {
    /// The harness renders the projection registry into the request and
    /// runs the tool loop itself. The four API-speaking providers.
    case harness
    /// The provider runs its OWN agentic loop with its own tools, and
    /// reaches New Old World's capabilities through MCP rather than
    /// through this harness. The workspace lane; `summary` is what the
    /// person is told it can touch.
    case workspace(summary: String)
    /// No tools this turn, with the reason in the person's words.
    case none(reason: String)

    /// What the harness sends. A workspace provider is handed no
    /// descriptors: it already has the same capabilities by another
    /// road, and a second copy would be two names for one act.
    var suppliesDescriptors: Bool { self == .harness }
}

/// A provider's report of itself — the cloud.report vocabulary
/// exactly: a provider with no key is still reported, with the reason,
/// so a popup can say why a thing is missing instead of not showing it.
struct ChatProviderEntry: Equatable, Sendable {
    let id: String
    let label: String
    /// "serving" | "off" | "no-access" | "unavailable"
    let state: String
    let detail: String
}

/* Codable from here down, deliberately: a saved chat on disk holds
   this exact vocabulary (see ChatStore), so the persisted shape and
   the harness's shape cannot drift apart — a second set of storage
   structs would be a second place to be wrong. */

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

/// A tool invocation as the model asked for it. `argumentsJSON` stays
/// a string until the harness parses it — a model (local ones
/// especially) can emit JSON that does not parse, and that is a tool
/// error to feed back, not a crash.
struct ChatToolCall: Equatable, Codable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

enum ChatContent: Equatable, Codable, Sendable {
    case text(String)
    case toolCall(ChatToolCall)
    case toolResult(id: String, text: String, imagePNG: Data?, isError: Bool)
}

struct ChatTurn: Equatable, Codable, Sendable {
    let role: ChatRole
    let content: [ChatContent]

    static func user(_ text: String) -> ChatTurn {
        ChatTurn(role: .user, content: [.text(text)])
    }
}

/// A tool the model may call, already rendered to the one shape both
/// provider dialects can carry: name, sentence, JSON Schema object.
struct ChatToolDescriptor: Sendable {
    let name: String
    let description: String
    /// A JSON-serializable [String: Any]; wrapped so the descriptor
    /// itself can be Sendable.
    let inputSchemaJSON: Data
}

/// Why a provider's stream ended.
enum ChatFinish: Sendable {
    /// The assistant is done talking.
    case endTurn
    /// The assistant wants tools run. Providers assemble the calls
    /// COMPLETELY before emitting — the two dialects fragment them
    /// differently on the wire, and half a call is nothing the harness
    /// can act on.
    case toolUse([ChatToolCall])
    /// Cut off (max tokens etc.); the reason is for the transcript.
    case truncated(String)
}

enum ChatStreamEvent: Sendable {
    case textDelta(String)
    /// Something the provider is DOING, in one converted line — the
    /// workspace lane's own tool use, which this harness never sees as
    /// a tool call because the provider ran it. Display only, and it
    /// travels the same road a harness tool does: `chat.status` to the
    /// guest, a tool row in the host pane. Never transcript text.
    case activity(String)
    case finished(ChatFinish)
}

/// One completion request in harness vocabulary. The provider owns
/// the translation to its dialect, both directions.
struct ChatCompletionRequest: Sendable {
    let model: String
    let system: String
    let turns: [ChatTurn]
    let tools: [ChatToolDescriptor]
    let maxTokens: Int
    /// The lane's per-project working subfolder, when the conversation
    /// is filed under a project. One shared workspace let a turn find
    /// another project's hello-world and reuse it (2026-08-19); a
    /// subfolder per project is the cheap honest fence. API providers
    /// ignore it — they have no working directory.
    var workspaceSubdirectory: String? = nil
}

/// Wire-bound display text: converted, and inside the contract's
/// 31-byte label cap. One statement, used by every row that leaves.
enum ChatWireText {
    static func label(_ text: String) -> String {
        String(CloudText.displayable(text).prefix(31))
    }
}
