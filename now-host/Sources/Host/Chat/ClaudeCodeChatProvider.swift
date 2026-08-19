import Foundation

final class ClaudeCodeChatProvider: ChatProvider, @unchecked Sendable {
    let id = "claude"
    let label = "Claude (Experimental)"

    /* The one provider that can be either thing, so it is asked rather
       than assumed. With no workspace configured it is the text-only
       relay it has always been — and now SAYS so, in the popup, before
       somebody asks it to go and look at their machine. */
    var toolReach: ChatToolReach {
        switch client.laneState() {
        case .ready(let lane):
            return .workspace(summary: lane.summary)
        case .unusable(let reason):
            return .none(reason: reason)
        case .off:
            return .none(
                reason: "Text only until building is allowed once in "
                    + "Settings > Chat on the modern Mac")
        }
    }

    private let client: ClaudeCodeClient
    private static let models = [
        ChatModel(providerID: "claude", modelID: "sonnet",
                  displayName: "Claude Sonnet"),
        ChatModel(providerID: "claude", modelID: "opus",
                  displayName: "Claude Opus"),
        ChatModel(providerID: "claude", modelID: "haiku",
                  displayName: "Claude Haiku"),
    ]

    init(client: ClaudeCodeClient = ClaudeCodeClient()) {
        self.client = client
    }

    func entry() async -> ChatProviderEntry {
        switch await client.status() {
        case .success(let status) where status.isSubscription:
            let plan = status.subscriptionType?.capitalized ?? "subscription"
            /* The reach comes FIRST in the detail. It is the fact that
               decides whether this row can do the thing the person is
               about to ask for, and the detail is bounded to 96 bytes on
               the wire — a truncated sentence must lose the plan name,
               never the hands. */
            let reach: String
            switch toolReach {
            case .workspace(let summary): reach = summary
            case .none(let reason): reach = reason
            case .harness: reach = "Full tools"
            }
            return ChatProviderEntry(
                id: id, label: label, state: "serving",
                detail: "\(reach) - \(plan) runtime")
        case .success(let status) where status.loggedIn:
            return ChatProviderEntry(
                id: id, label: label, state: "unavailable",
                detail: "Claude is using \(status.authMethod ?? "non-subscription auth")")
        case .success:
            return ChatProviderEntry(
                id: id, label: label, state: "unavailable",
                detail: "Authenticate in Claude Code, then refresh")
        case .failure(let fault):
            return ChatProviderEntry(
                id: id, label: label, state: "unavailable",
                detail: ChatFault.from(fault).reason)
        }
    }

    func listModels() async throws -> [ChatModel] {
        switch await client.status() {
        case .success(let status) where status.isSubscription:
            return Self.models
        case .success:
            throw ChatFault.refuse(
                code: "no-credentials",
                reason: "Authenticate a Claude subscription in Claude Code")
        case .failure(let fault):
            throw fault
        }
    }

    func stream(_ request: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        client.stream(request)
    }
}
