import Foundation

/* The chat family as an agent sees it.
   
   These are the shapes behind `now_chats`, and the reason the row exists
   at all is worth stating where it will be read: an agent that can drive
   the classic machine but cannot see the conversation a person is having
   AT that machine leaves the human as the only wire between the two
   halves. Reading and continuing that conversation — on the person's own
   Mac, against the person's own store — is the loop this product is for
   (decided 2026-08-18, after this surface was first written up as a
   deliberate gap on the opposite argument).

   Bounded like every other row here: a listing is paged, a transcript is
   paged FROM THE END the way the wire pages it, and nothing returns a
   whole conversation because a whole conversation has no bound. */

public enum AgentIntegrationChatOperation: String, Codable, CaseIterable,
    Sendable {
    /// One page of saved chats, newest activity first.
    case list
    /// One page of a chat's transcript, counted from the end.
    case read
    /// A new chat, optionally filed under a project.
    case create
    /// File an existing chat under a project, or under none.
    case file
    /// One page of the projects a chat may be filed under.
    case projects
    /// Append one message to a chat, as the agent rather than as the
    /// person or the model. The cheap half of closing the loop: it needs
    /// no model turn and cannot be mistaken for one.
    case append
}

public struct AgentIntegrationChatRequest: Codable, Equatable, Sendable {
    public let operation: AgentIntegrationChatOperation
    public var chatID: String?
    public var projectID: String?
    public var title: String?
    public var text: String?
    public var cursor: Int?

    public init(operation: AgentIntegrationChatOperation,
                chatID: String? = nil, projectID: String? = nil,
                title: String? = nil, text: String? = nil,
                cursor: Int? = nil) {
        self.operation = operation
        self.chatID = chatID
        self.projectID = projectID
        self.title = title
        self.text = text
        self.cursor = cursor
    }

    /// Checked before the request is admitted, the projects rule: an
    /// identifier that cannot be one is refused at the door rather than
    /// looked up and missed.
    public var isWellFormed: Bool {
        guard chatID.map(Self.isIdentifier) ?? true,
              projectID.map(Self.isIdentifier) ?? true,
              cursor.map({ $0 >= 0 }) ?? true,
              title.map({ !$0.isEmpty && $0.count <= 200
                  && !$0.contains("\n") && !$0.contains("\0") }) ?? true,
              /* A bound rather than none: an appended message crosses a
                 local socket into a file a classic Mac will page through
                 24 rows at a time. */
              text.map({ !$0.isEmpty && $0.count <= 4096 }) ?? true
        else { return false }
        switch operation {
        case .list, .projects:
            return chatID == nil && projectID == nil && title == nil
                && text == nil
        case .read:
            return chatID != nil && title == nil && text == nil
                && projectID == nil
        case .create:
            return chatID == nil && text == nil && cursor == nil
        case .file:
            return chatID != nil && title == nil && text == nil
                && cursor == nil
        case .append:
            return chatID != nil && text != nil && title == nil
                && projectID == nil && cursor == nil
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.allSatisfy {
                $0.isHexDigit || $0.isNumber || $0.isLetter || $0 == "-"
            }
    }
}

/// One saved chat, metadata only — the roster rule, for the same reason:
/// a listing that carried transcript text would make listing expensive
/// and reading unnecessary, and both faces would drift toward one of
/// them.
public struct AgentIntegrationChatSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// "guest" or "host" — which machine it was typed at.
    public let origin: String
    public let projectID: String?
    public let turnCount: Int
    public let updatedAt: Date

    public init(id: String, title: String, origin: String,
                projectID: String?, turnCount: Int, updatedAt: Date) {
        self.id = id
        self.title = title
        self.origin = origin
        self.projectID = projectID
        self.turnCount = turnCount
        self.updatedAt = updatedAt
    }
}

public struct AgentIntegrationChatRow: Codable, Equatable, Sendable {
    /// person | model | tool | note | agent
    public let kind: String
    public let text: String

    public init(kind: String, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct AgentIntegrationChatProject: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// "host" or "guest" where a person has said; absent otherwise.
    public let home: String?

    public init(id: String, name: String, home: String?) {
        self.id = id
        self.name = name
        self.home = home
    }
}

public struct AgentIntegrationChatResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let chats: [AgentIntegrationChatSummary]?
    public let chat: AgentIntegrationChatSummary?
    public let rows: [AgentIntegrationChatRow]?
    public let projects: [AgentIntegrationChatProject]?
    /// True when another page remains at cursor + the rows received.
    public let more: Bool?
    public let failure: AgentIntegrationUnavailable?

    public init(chats: [AgentIntegrationChatSummary]? = nil,
                chat: AgentIntegrationChatSummary? = nil,
                rows: [AgentIntegrationChatRow]? = nil,
                projects: [AgentIntegrationChatProject]? = nil,
                more: Bool? = nil,
                failure: AgentIntegrationUnavailable? = nil) {
        self.ok = failure == nil
        self.chats = chats
        self.chat = chat
        self.rows = rows
        self.projects = projects
        self.more = more
        self.failure = failure
    }

    public static func unavailable(_ reason: AgentIntegrationUnavailable)
        -> Self {
        .init(failure: reason)
    }
}
