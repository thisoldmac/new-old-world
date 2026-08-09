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

private func makeChatProviderRegistry(
    store: ChatCredentialStore, transport: ChatHTTPTransport
) -> ChatProviderRegistry {
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
    return registry
}

private func makePassiveChatProviderRegistry(
    store: ChatCredentialStore, transport: ChatHTTPTransport
) -> (snapshot: SnapshotChatCredentialStore,
      registry: ChatProviderRegistry) {
    let snapshot = SnapshotChatCredentialStore(
        source: store, interaction: .forbid)
    return (snapshot, makeChatProviderRegistry(
        store: snapshot, transport: transport))
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
    @Published private(set) var credentialNotice: String?
    @Published private(set) var canAuthorizeSavedCredentials = false
    @Published private(set) var isAuthorizingCredentials = false

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

        let registry = makeChatProviderRegistry(
            store: store, transport: transport)
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
        let store = store
        let transport = transport
        /* Detached: Keychain reads and local-runtime probes must never
           run on the main actor (see init). */
        Task.detached { [weak self] in
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport)
            let credentialReads = Dictionary(uniqueKeysWithValues:
                ChatCredentialKey.allCases.map {
                    ($0, passive.snapshot.read($0, interaction: .forbid))
                })
            var entries: [ChatProviderEntry] = []
            for provider in passive.registry.all() {
                entries.append(await provider.entry())
            }
            var models: [ChatModel] = []
            for provider in passive.registry.all() {
                if let served = try? await provider.listModels() {
                    models.append(contentsOf: served)
                }
            }
            let notice = ChatCredentialKey.allCases.compactMap {
                credentialReads[$0]?.statusReason
            }.first
            let canAuthorize = credentialReads.values.contains {
                $0 == .authorizationRequired
            }
            let found = (
                entries: entries, models: models,
                hasAnthropicKey:
                    !(credentialReads[.anthropicAPIKey]?.string ?? "").isEmpty,
                hasAnthropicOAuth:
                    credentialReads[.anthropicOAuth]?.isAvailable == true,
                hasOpenAIKey:
                    !(credentialReads[.openAIAPIKey]?.string ?? "").isEmpty,
                notice: notice, canAuthorize: canAuthorize)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let models = found.models
                self.hasAnthropicKey = found.hasAnthropicKey
                self.hasAnthropicOAuth = found.hasAnthropicOAuth
                self.hasOpenAIKey = found.hasOpenAIKey
                self.credentialNotice = found.notice
                self.canAuthorizeSavedCredentials = found.canAuthorize
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
        let store = store
        let transport = transport
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport)
            var models: [ChatModel] = []
            for provider in passive.registry.all() {
                if let served = try? await provider.listModels() {
                    models.append(contentsOf: served)
                }
            }
            return models
        }.value
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
        let entries = await providerEntries()
        return entries.map { entry in
            ChatCatalogProvider(
                provider: entry.id,
                label: ChatWireText.label(entry.label),
                state: entry.state,
                detail: CloudText.displayable(entry.detail))
        }
    }

    /// The named provider's FULL list, fetched when somebody selects
    /// it — never sooner. nil (unknown provider, or one that cannot
    /// list right now) reads as an empty page at the service, the
    /// contract's honest "nothing to list".
    private func wireModels(provider id: String) async -> [ChatModel]? {
        let store = store
        let transport = transport
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport)
            guard let provider = passive.registry.provider(for: id)
            else { return nil }
            return try? await provider.listModels()
        }.value
    }

    func providerEntries() async -> [ChatProviderEntry] {
        let store = store
        let transport = transport
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport)
            var entries: [ChatProviderEntry] = []
            for provider in passive.registry.all() {
                entries.append(await provider.entry())
            }
            return entries
        }.value
    }

    // MARK: - Credentials

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
            do {
                try store.writeString(which, trimmed)
            } catch {
                credentialNotice = ChatFault.from(error).reason
            }
        }
        refresh()
    }

    func authorizeSavedCredentials() {
        guard !isAuthorizingCredentials else { return }
        isAuthorizingCredentials = true
        let store = store
        Task.detached { [weak self] in
            let results = ChatCredentialKey.allCases.map {
                store.read($0, interaction: .allow)
            }
            let notice = results.compactMap(\.statusReason).first
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAuthorizingCredentials = false
                self.credentialNotice = notice
                self.refresh()
            }
        }
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

    /// "Answer that again." The last prompt is asked afresh with
    /// everything it produced removed from both halves — a retry that
    /// left the failed answer in context asked a different question
    /// than the one on screen.
    func retryLastPrompt() {
        guard !isStreaming,
            let rewound = ChatRewind.toLastPrompt(
                rows: transcript, turns: conversation)
        else { return }
        transcript = rewound.rows
        conversation = rewound.turns
        send(rewound.prompt)
    }

    /// "Let me put that differently." Everything after the edited
    /// prompt goes, including the answers a person is replacing.
    func resend(promptID: UUID, as text: String) {
        guard !isStreaming,
            let rewound = ChatRewind.toPrompt(
                id: promptID, rows: transcript, turns: conversation)
        else { return }
        transcript = rewound.rows
        conversation = rewound.turns
        send(text)
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
