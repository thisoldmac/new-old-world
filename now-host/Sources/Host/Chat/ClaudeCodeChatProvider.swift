import Foundation

final class ClaudeCodeChatProvider: ChatProvider, @unchecked Sendable {
    let id = "claude"
    let label = "Claude (Experimental)"

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
            return ChatProviderEntry(
                id: id, label: label, state: "serving",
                detail: "Experimental - \(plan) runtime")
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
