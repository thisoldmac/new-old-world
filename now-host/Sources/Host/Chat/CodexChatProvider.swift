import Foundation

final class CodexChatProvider: ChatProvider, @unchecked Sendable {
    let id = "codex"
    let label = "Codex (ChatGPT)"
    /* Text-only, and said out loud. The app-server client disables every
       tool and sandbox affordance it has (CodexAppServerClient's
       `shell_tool: false`), so this provider answers from knowledge and
       cannot look at the classic machine. It is not a lane yet: giving
       Codex hands is a second authority argument, not a flag. */
    let toolReach = ChatToolReach.none(
        reason: "Codex answers from knowledge; it cannot use New Old "
            + "World's tools")
    let client: CodexAppServerClient

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    func entry() async -> ChatProviderEntry {
        do {
            guard let account = try await client.account() else {
                return ChatProviderEntry(
                    id: id, label: label, state: "unavailable",
                    detail: "Sign in with ChatGPT")
            }
            guard account.isChatGPT else {
                return ChatProviderEntry(
                    id: id, label: label, state: "unavailable",
                    detail: "Codex is using API-key authentication")
            }
            let plan = account.planType?.capitalized ?? "ChatGPT"
            return ChatProviderEntry(
                id: id, label: label, state: "serving",
                detail: "\(plan) plan")
        } catch {
            return ChatProviderEntry(
                id: id, label: label, state: "unavailable",
                detail: ChatFault.from(error).reason)
        }
    }

    func listModels() async throws -> [ChatModel] {
        guard try await client.account()?.isChatGPT == true else {
            throw ChatFault.refuse(
                code: "no-credentials", reason: "Sign in with ChatGPT")
        }
        return try await client.models()
    }

    func stream(_ request: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        client.stream(request)
    }
}
