import Foundation

/* One LLM backend. The CloudProvider rules apply verbatim: everything
   a provider reports is its own truth, the registry never invents a
   state, and a provider that cannot serve still reports itself with
   the reason. */

protocol ChatProvider: AnyObject, Sendable {
    /// Registry key ("anthropic", "openai", "ollama", ...). Also the
    /// wire-model-id prefix, so it may not contain "/".
    var id: String { get }
    var label: String { get }
    /// How far this provider's turn reaches. Asked per turn, because a
    /// lane can be configured while the app is open.
    var toolReach: ChatToolReach { get }
    func entry() async -> ChatProviderEntry
    func listModels() async throws -> [ChatModel]
    /// Streams one completion. Text arrives live; tool calls arrive
    /// whole, in the terminal `.finished(.toolUse(_))`. Errors are
    /// ChatFault where the provider can say so.
    func stream(_ request: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
}

final class ChatProviderRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ChatProvider] = []

    func register(_ provider: ChatProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers.append(provider)
    }

    func all() -> [ChatProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providers
    }

    func provider(for id: String) -> ChatProvider? {
        all().first { $0.id == id }
    }

    /// Splits a wire model id ("anthropic/claude-opus-5") back into
    /// its provider and the provider's own model id. The first "/" is
    /// the seam; the model id may contain more (some local runtimes
    /// namespace theirs).
    func resolve(wireID: String) -> (provider: ChatProvider, modelID: String)? {
        guard let slash = wireID.firstIndex(of: "/") else { return nil }
        let providerID = String(wireID[..<slash])
        let modelID = String(wireID[wireID.index(after: slash)...])
        guard !modelID.isEmpty, let provider = provider(for: providerID) else {
            return nil
        }
        return (provider, modelID)
    }
}
