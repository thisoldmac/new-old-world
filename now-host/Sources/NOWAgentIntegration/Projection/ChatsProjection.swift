import Foundation

/// The person's saved conversations, as one discriminated row.
///
/// **Why this exists at all**, since it was very nearly argued away: an
/// agent that can drive the classic machine but cannot see the
/// conversation a person is having AT that machine leaves the human as
/// the only wire between the two halves. Reading it, filing it, and
/// writing into it is the loop this product is for (decided 2026-08-18,
/// reversing a same-day disposition in `docs/mcp-coverage.md` that had
/// called the family a deliberate gap).
///
/// The authority is this Mac's own storage, like `now_projects`: a chat
/// exists whether or not a Macintosh is connected, so guest consent has
/// no bearing and naming a guest is not accepted.
///
/// **What it deliberately does not do is run a model turn.** `append`
/// writes a note into the conversation; it does not speak as the
/// assistant and does not join the turns the model is re-sent. A row
/// that started a turn would be a long-running local-socket call needing
/// its own deadline argument, and inheriting one by accident is how a
/// caller ends up waiting on a build with no way to tell.
public enum ChatsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_chats")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let authorityDomain =
        HostProjectionAuthorityDomain.hostProjects
    public static let acceptsGuestAddressing = false
    public static let acceptedArguments: Set<String> = [
        "operation", "chatID", "projectID", "title", "text", "cursor",
    ]
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "Chat/ChatSidebarView.swift",
                         symbol: "ChatSidebar"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "The running host owns a bounded Application Support chats store."

    public static var operationDescriptor: NOWOperationDescriptor {
        [
            "title": "New Old World Saved Chats",
            "description":
                "Lists, reads, creates and files the conversations saved by New Old World, including the ones typed at the connected classic Macintosh, and appends a note to one. Listings and transcripts are paged; a transcript pages from the newest end. It runs no model turn and speaks as neither the person nor the assistant.",
            "inputSchema": inputSchema,
            "outputSchema": [
                "type": "object",
                "description": "One page of chats, one page of a transcript, one page of chat projects, one chat summary, or a typed failure.",
            ],
            "annotations": [
                /* False because create, file and append change stored
                   state. The three reads share the row, which is what a
                   discriminated surface costs — and the reason the mode
                   gate in Chat reads this hint rather than a list of its
                   own is that this answer stays true as operations are
                   added. */
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    // `Any` erases Sendable; these are immutable JSON value graphs only.
    private nonisolated(unsafe) static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "operation": [
                "type": "string",
                "enum": AgentIntegrationChatOperation.allCases.map(\.rawValue),
                "description":
                    "list pages saved chats newest first; read pages one chat's transcript from its newest end; projects pages the projects a chat may be filed under; create makes a chat; file moves one under a project or none; append adds a note to one.",
            ],
            "chatID": [
                "type": "string", "pattern": "^[0-9a-f]{32}$",
                "description": "Required by read, file and append.",
            ],
            "projectID": [
                "type": "string", "pattern": "^chatproject-[0-9a-f]{16}$",
                "description":
                    "With create or file. Absent on file means the chat becomes loose.",
            ],
            "title": [
                "type": "string", "maxLength": 200,
                "description": "With create only.",
            ],
            "text": [
                "type": "string", "maxLength": 4096,
                "description":
                    "With append only. It is stored as a note — neither the person's words nor the assistant's — and is not re-sent to the model as part of the conversation.",
            ],
            "cursor": [
                "type": "integer", "minimum": 0,
                "description":
                    "Rows already received. With read it counts back from the newest row, so 0 is the newest page.",
            ],
        ],
        "required": ["operation"],
        "additionalProperties": false,
    ]

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let object = arguments.object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let request = try? JSONDecoder().decode(
                AgentIntegrationChatRequest.self, from: data),
              request.isWellFormed else {
            return .invalidArguments(
                "now_chats requires one valid operation and only the arguments that operation takes")
        }
        return .value(.init(await client.chats(request)))
    }
}
