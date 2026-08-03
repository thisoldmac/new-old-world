import AppKit
import Foundation
import NOWAgentIntegration

/* The Chat page's model: provider configuration (the harness's whole
   settings surface — there is no preferences window, per this app's
   rule) and a working transcript that exercises the same harness the
   wire serves. What the guest sees comes through the same registry and
   the same loop; this page is where a person proves the harness works
   before a classic Mac ever asks. */

/// One transcript row as the page draws it.
struct ChatDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case person
        case model
        case tool(name: String, ok: Bool?)
        case note
    }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class ChatModuleModel: ObservableObject {
    enum SignInState: Equatable {
        case idle
        case awaitingPaste(AnthropicOAuth.PKCE)
        case failed(String)
    }

    @Published private(set) var entries: [ChatProviderEntry] = []
    @Published private(set) var models: [ChatModel] = []
    @Published var selectedWireModelID: String {
        didSet {
            defaults.set(selectedWireModelID, forKey: Self.modelKey)
        }
    }
    /// The provider half of the two pickers. Changing it snaps the
    /// model picker to that provider's first model.
    @Published var selectedProviderID: String = "" {
        didSet {
            guard oldValue != selectedProviderID else { return }
            let scoped = models(of: selectedProviderID)
            if !scoped.contains(where: { $0.wireID == selectedWireModelID }),
                let first = scoped.first {
                selectedWireModelID = first.wireID
            }
        }
    }

    /// Providers that listed at least one model, in registry order.
    var providersWithModels: [ChatProviderEntry] {
        entries.filter { entry in
            models.contains { $0.providerID == entry.id }
        }
    }

    func models(of provider: String) -> [ChatModel] {
        models.filter { $0.providerID == provider }
    }
    @Published private(set) var transcript: [ChatDisplayRow] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var signIn: SignInState = .idle
    @Published private(set) var hasAnthropicKey = false
    @Published private(set) var hasAnthropicOAuth = false
    @Published private(set) var hasOpenAIKey = false

    let registry: ChatProviderRegistry
    let harness: ChatHarness
    private let store: ChatCredentialStore
    private let transport: ChatHTTPTransport
    private let defaults: UserDefaults
    private var conversation: [ChatTurn] = []
    private static let modelKey = "chat.selectedModel"
    private static let paneConversation = "host-pane"

    init(
        agentIntegration: AgentIntegrationHostAdapter,
        guestFiles: GuestFilesCommandService,
        agentActivity: AgentActivityModel?,
        store: ChatCredentialStore = KeychainChatCredentialStore(),
        transport: ChatHTTPTransport = URLSessionChatTransport(),
        defaults: UserDefaults = UserDefaults(
            suiteName: ProductIdentity.preferencesSuite) ?? .standard
    ) {
        self.store = store
        self.transport = transport
        self.defaults = defaults
        selectedWireModelID = defaults.string(forKey: Self.modelKey) ?? ""

        let registry = ChatProviderRegistry()
        registry.register(
            AnthropicChatProvider(store: store, transport: transport))
        registry.register(
            OpenAICompatibleChatProvider.openAI(
                store: store, transport: transport))
        registry.register(
            OpenAICompatibleChatProvider.ollama(
                store: store, transport: transport))
        registry.register(
            OpenAICompatibleChatProvider.lmStudio(
                store: store, transport: transport))
        registry.register(
            OpenAICompatibleChatProvider.oMLX(
                store: store, transport: transport))
        self.registry = registry
        harness = ChatHarness(
            registry: registry,
            makeClient: { selector in
                ChatAgentClient(
                    adapter: agentIntegration, guestFiles: guestFiles
                ).addressing(selector)
            },
            audit: ChatAuditSink(
                adapter: agentIntegration, activity: agentActivity))
        /* NO Keychain read here, deliberately. This init runs on the
           main actor inside HostAppState — including in every test that
           builds one — and a Keychain item created by a differently-
           signed build can stall the read behind an authorization
           prompt. A blocked main actor is a blocked GuestListener, and
           that took down half the socket-timing suite (2026-08-02).
           refresh() reads everything off-main. */
    }

    // MARK: - Providers and models

    func refresh() {
        let registry = registry
        let store = store
        /* Detached: Keychain reads and local-runtime probes must never
           run on the main actor (see init). */
        Task.detached { [weak self] in
            let hasAnthropicKey =
                !(store.readString(.anthropicAPIKey) ?? "").isEmpty
            let hasAnthropicOAuth = store.read(.anthropicOAuth) != nil
            let hasOpenAIKey =
                !(store.readString(.openAIAPIKey) ?? "").isEmpty
            var entries: [ChatProviderEntry] = []
            for provider in registry.all() {
                entries.append(await provider.entry())
            }
            var models: [ChatModel] = []
            for provider in registry.all() {
                if let served = try? await provider.listModels() {
                    models.append(contentsOf: served)
                }
            }
            let found = (entries: entries, models: models)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let models = found.models
                self.hasAnthropicKey = hasAnthropicKey
                self.hasAnthropicOAuth = hasAnthropicOAuth
                self.hasOpenAIKey = hasOpenAIKey
                self.entries = found.entries
                self.models = models
                if self.selectedWireModelID.isEmpty
                    || !models.contains(where: {
                        $0.wireID == self.selectedWireModelID
                    }) {
                    self.selectedWireModelID = models.first?.wireID
                        ?? self.selectedWireModelID
                }
                // The provider picker follows the model's owner.
                if let owner = models.first(where: {
                    $0.wireID == self.selectedWireModelID
                })?.providerID {
                    self.selectedProviderID = owner
                } else if let first = models.first?.providerID {
                    self.selectedProviderID = first
                }
            }
        }
    }

    /// What the wire's chat.models catalog is built from — asked fresh
    /// so a guest never reads a stale page's cache.
    func servableModels() async -> [ChatModel] {
        var models: [ChatModel] = []
        for provider in registry.all() {
            if let served = try? await provider.listModels() {
                models.append(contentsOf: served)
            }
        }
        return models
    }

    /// The chat.* family's server, sharing this page's harness so what
    /// a guest reaches is exactly what the test pane proved. The
    /// service pages and mints refs; this page only answers what the
    /// registry knows, when asked.
    private(set) lazy var wireService = ChatWireService(
        harness: harness,
        providers: { [weak self] in
            await self?.wireProviders() ?? []
        },
        models: { [weak self] providerID in
            await self?.wireModels(provider: providerID)
        })

    /// Every provider, whatever its state — the cloud.report rule: one
    /// that cannot serve is still a row saying WHY. Labels leave
    /// converted and bounded (<= 31 bytes, the cloud rule).
    private func wireProviders() async -> [ChatCatalogProvider] {
        var rows: [ChatCatalogProvider] = []
        for provider in registry.all() {
            let entry = await provider.entry()
            rows.append(ChatCatalogProvider(
                provider: provider.id,
                label: ChatWireText.label(entry.label),
                state: entry.state,
                detail: CloudText.displayable(entry.detail)))
        }
        return rows
    }

    /// The named provider's FULL list, fetched when somebody selects
    /// it — never sooner. nil (unknown provider, or one that cannot
    /// list right now) reads as an empty page at the service, the
    /// contract's honest "nothing to list".
    private func wireModels(provider id: String) async -> [ChatModel]? {
        guard let provider = registry.all().first(where: { $0.id == id })
        else { return nil }
        return try? await provider.listModels()
    }

    func providerEntries() async -> [ChatProviderEntry] {
        var entries: [ChatProviderEntry] = []
        for provider in registry.all() {
            entries.append(await provider.entry())
        }
        return entries
    }

    // MARK: - Credentials

    private func refreshCredentialFlags() {
        hasAnthropicKey = !(store.readString(.anthropicAPIKey) ?? "").isEmpty
        hasAnthropicOAuth = store.read(.anthropicOAuth) != nil
        hasOpenAIKey = !(store.readString(.openAIAPIKey) ?? "").isEmpty
    }

    func setAnthropicKey(_ key: String) {
        setKey(.anthropicAPIKey, key)
    }

    func setOpenAIKey(_ key: String) {
        setKey(.openAIAPIKey, key)
    }

    private func setKey(_ which: ChatCredentialKey, _ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.delete(which)
        } else {
            try? store.writeString(which, trimmed)
        }
        refreshCredentialFlags()
        refresh()
    }

    func beginAnthropicSignIn() {
        let pkce = AnthropicOAuth.makePKCE()
        signIn = .awaitingPaste(pkce)
        NSWorkspace.shared.open(AnthropicOAuth.authorizeURL(pkce: pkce))
    }

    func completeAnthropicSignIn(pasted: String) {
        guard case .awaitingPaste(let pkce) = signIn else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let code = try AnthropicOAuth.parsePasted(pasted, pkce: pkce)
                let tokens = try await AnthropicOAuth.exchange(
                    code: code, pkce: pkce, transport: self.transport)
                try self.store.write(
                    .anthropicOAuth, JSONEncoder().encode(tokens))
                self.signIn = .idle
                self.refreshCredentialFlags()
                self.refresh()
            } catch {
                self.signIn = .failed(ChatFault.from(error).reason)
            }
        }
    }

    func cancelAnthropicSignIn() {
        signIn = .idle
    }

    func signOutAnthropic() {
        store.delete(.anthropicOAuth)
        signIn = .idle
        refreshCredentialFlags()
        refresh()
    }

    // MARK: - The test chat pane

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        guard !selectedWireModelID.isEmpty else {
            transcript.append(ChatDisplayRow(
                kind: .note, text: "Pick a model first"))
            return
        }
        transcript.append(ChatDisplayRow(kind: .person, text: trimmed))
        conversation.append(.user(trimmed))
        isStreaming = true
        let turns = conversation
        let model = selectedWireModelID
        Task { [weak self] in
            guard let self else { return }
            let started = await self.harness.run(
                conversation: Self.paneConversation,
                wireModelID: model,
                transcript: turns,
                addressing: nil,
                origin: .hostPane
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            if !started {
                self.isStreaming = false
                self.transcript.append(ChatDisplayRow(
                    kind: .note, text: "A turn is already running"))
            }
        }
    }

    func cancel() {
        Task { [weak self] in
            _ = await self?.harness.cancel(
                conversation: Self.paneConversation)
        }
    }

    func newChat() {
        guard !isStreaming else { return }
        conversation = []
        transcript = []
    }

    private func handle(_ event: ChatHarnessEvent) {
        switch event {
        case .delta(let part):
            if case .model = transcript.last?.kind {
                transcript[transcript.count - 1].text += part
            } else {
                transcript.append(ChatDisplayRow(kind: .model, text: part))
            }
        case .toolStarted(let name):
            transcript.append(ChatDisplayRow(
                kind: .tool(name: name, ok: nil), text: name))
        case .toolFinished(let name, let ok):
            if let index = transcript.lastIndex(where: {
                if case .tool(let n, nil) = $0.kind { return n == name }
                return false
            }) {
                transcript[index].kind = .tool(name: name, ok: ok)
            }
        case .finished(let outcome):
            isStreaming = false
            conversation.append(contentsOf: outcome.appended)
            if !outcome.ok {
                let code = outcome.code ?? "provider-error"
                let message = outcome.message.map { " - \($0)" } ?? ""
                transcript.append(ChatDisplayRow(
                    kind: .note, text: "\(code)\(message)"))
            }
        }
    }
}
