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

/* The one place a drawn row and a saved row meet. Kept together so
   the two directions cannot disagree: a tool row that saved as a note
   would come back as a note, silently. */
extension StoredChatRow {
    init(displaying row: ChatDisplayRow) {
        switch row.kind {
        case .person:
            self.init(kind: .person, text: row.text)
        case .model:
            self.init(kind: .model, text: row.text)
        case .note:
            self.init(kind: .note, text: row.text)
        case .tool(let name, let ok):
            self.init(kind: .tool, text: row.text,
                      toolName: name, toolOK: ok)
        }
    }

    var displayRow: ChatDisplayRow {
        switch kind {
        case .person: return ChatDisplayRow(kind: .person, text: text)
        case .model: return ChatDisplayRow(kind: .model, text: text)
        case .note: return ChatDisplayRow(kind: .note, text: text)
        case .tool:
            return ChatDisplayRow(
                kind: .tool(name: toolName ?? text, ok: toolOK), text: text)
        }
    }
}

private func makeChatProviderRegistry(
    store: ChatCredentialStore, transport: ChatHTTPTransport,
    runtimeProviders: [ChatProvider]
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
    runtimeProviders.forEach(registry.register)
    return registry
}

private func makePassiveChatProviderRegistry(
    store: ChatCredentialStore, transport: ChatHTTPTransport,
    runtimeProviders: [ChatProvider]
) -> (credentials: OperationChatCredentialStore,
      registry: ChatProviderRegistry) {
    let credentials = OperationChatCredentialStore(
        source: store, interaction: .forbid)
    return (credentials, makeChatProviderRegistry(
        store: credentials, transport: transport,
        runtimeProviders: runtimeProviders))
}

@MainActor
final class ChatModuleModel: ObservableObject {
    enum CodexSignInState: Equatable {
        case idle
        case signingIn
        case failed(String)
    }

    private struct CredentialAccess: Equatable {
        var notice: String?
        var authorizationKeys: [ChatCredentialKey] = []
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
    @Published private(set) var hasAnthropicKey = false
    @Published private(set) var hasOpenAIKey = false
    @Published private(set) var codexAccount: CodexAccount?
    @Published private(set) var codexUsage: CodexUsageSnapshot?
    @Published private(set) var codexSignIn: CodexSignInState = .idle
    @Published private var credentialAccess = CredentialAccess()
    @Published private(set) var isAuthorizingCredentials = false

    var credentialNotice: String? { credentialAccess.notice }
    var canAuthorizeSavedCredentials: Bool {
        !credentialAccess.authorizationKeys.isEmpty
    }

    let harness: ChatHarness
    private let store: ChatCredentialStore
    private let transport: ChatHTTPTransport
    private let runtimeProviders: [ChatProvider]
    private let codexClient: CodexAppServerClient
    private let defaults: UserDefaults
    private var conversation: [ChatTurn] = []
    private static let modelKey = "chat.selectedModel"
    private static let paneConversation = "host-pane"

    /* Saved chats. The store is optional because a machine whose
       Application Support cannot be written is a machine where chat
       should still WORK — it degrades to the old in-memory behaviour
       with the reason on screen, rather than refusing to talk. */
    private let chatStore: ChatStore?
    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var chatProjects: [ChatProjectRecord] = []
    @Published private(set) var selectedChatID: ChatID?
    /// Why saving is not happening, when it is not.
    @Published private(set) var storageNotice: String?
    private var didBootstrapChats = false

    init(
        agentIntegration: AgentIntegrationHostAdapter,
        guestFiles: GuestFilesCommandService,
        agentActivity: AgentActivityModel?,
        /* The connected Mac's screen, or nil for "nobody has measured
           it". Injected rather than looked up, because the thing that
           knows is the live Mirror and this model must not construct
           one — and because nil has to survive all the way into the
           prompt as `unknown`. */
        guestScreen: @escaping @Sendable () async -> ChatSystemPrompt.Screen?
            = { nil },
        store: ChatCredentialStore = KeychainChatCredentialStore(),
        transport: ChatHTTPTransport = URLSessionChatTransport(),
        defaults: UserDefaults = UserDefaults(
            suiteName: ProductIdentity.preferencesSuite) ?? .standard,
        /* Injected — the module hands over `try? ChatStore()`, the way
           the Projects module hands over its ProjectStore. Nil means
           saving is unavailable, and every test that builds this model
           incidentally gets that rather than writing into the real
           Application Support. */
        chatStore: ChatStore? = nil
    ) {
        self.store = store
        self.transport = transport
        self.defaults = defaults
        self.chatStore = chatStore
        selectedWireModelID = defaults.string(forKey: Self.modelKey) ?? ""

        let codexClient = CodexAppServerClient()
        self.codexClient = codexClient
        let runtimeProviders: [ChatProvider] = [
            ClaudeCodeChatProvider(), CodexChatProvider(client: codexClient),
        ]
        self.runtimeProviders = runtimeProviders
        let registry = makeChatProviderRegistry(
            store: store, transport: transport,
            runtimeProviders: runtimeProviders)
        harness = ChatHarness(
            registry: registry,
            makeClient: { selector in
                HostAgentIntegrationClient(
                    adapter: agentIntegration, guestFiles: guestFiles
                ).addressing(selector)
            },
            audit: ChatAuditSink(
                adapter: agentIntegration, activity: agentActivity),
            guestScreen: guestScreen)
        /* NO Keychain read here, deliberately. This init runs on the
           main actor inside HostAppState — including in every test that
           builds one — and a Keychain item created by a differently-
           signed build can stall the read behind an authorization
           prompt. A blocked main actor is a blocked GuestListener, and
           that took down half the socket-timing suite (2026-08-02).
           refresh() reads everything off-main. */
    }

    // MARK: - Providers and models

    func refresh(preservingCredentialNotice preservedNotice: String? = nil) {
        let store = store
        let transport = transport
        let runtimeProviders = runtimeProviders
        let codexClient = codexClient
        /* Detached: Keychain reads and local-runtime probes must never
           run on the main actor (see init). */
        Task.detached { [weak self] in
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport,
                runtimeProviders: runtimeProviders)
            let credentialReads = Dictionary(uniqueKeysWithValues:
                ChatCredentialKey.activeCases.map {
                    ($0, passive.credentials.read($0, interaction: .forbid))
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
            let keychainNotice = ChatCredentialKey.activeCases.compactMap {
                credentialReads[$0]?.statusReason
            }.first
            let authorizationKeys = ChatCredentialKey.activeCases.filter {
                credentialReads[$0] == .authorizationRequired
            }
            let found = (
                entries: entries, models: models,
                hasAnthropicKey:
                    !(credentialReads[.anthropicAPIKey]?.string ?? "").isEmpty,
                hasOpenAIKey:
                    !(credentialReads[.openAIAPIKey]?.string ?? "").isEmpty,
                notice: preservedNotice ?? keychainNotice,
                authorizationKeys: authorizationKeys,
                codexAccount: try? await codexClient.account(),
                codexUsage: try? await codexClient.usage())
            await MainActor.run { [weak self] in
                guard let self else { return }
                let models = found.models
                self.hasAnthropicKey = found.hasAnthropicKey
                self.hasOpenAIKey = found.hasOpenAIKey
                self.codexAccount = found.codexAccount ?? nil
                self.codexUsage = found.codexUsage ?? nil
                self.credentialAccess = CredentialAccess(
                    notice: found.notice,
                    authorizationKeys: found.authorizationKeys)
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
        let runtimeProviders = runtimeProviders
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport,
                runtimeProviders: runtimeProviders)
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
        let runtimeProviders = runtimeProviders
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport,
                runtimeProviders: runtimeProviders)
            guard let provider = passive.registry.provider(for: id)
            else { return nil }
            return try? await provider.listModels()
        }.value
    }

    func providerEntries() async -> [ChatProviderEntry] {
        let store = store
        let transport = transport
        let runtimeProviders = runtimeProviders
        return await Task.detached {
            let passive = makePassiveChatProviderRegistry(
                store: store, transport: transport,
                runtimeProviders: runtimeProviders)
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
        var notice: String?
        do {
            if trimmed.isEmpty {
                try store.delete(which)
            } else {
                try store.writeString(which, trimmed)
            }
        } catch {
            notice = ChatFault.from(error).reason
            credentialAccess.notice = notice
        }
        refresh(preservingCredentialNotice: notice)
    }

    func authorizeSavedCredentials() {
        let keys = credentialAccess.authorizationKeys
        guard !isAuthorizingCredentials, !keys.isEmpty else { return }
        isAuthorizingCredentials = true
        let store = store
        Task.detached { [weak self] in
            let results = keys.map {
                store.read($0, interaction: .allow)
            }
            let notice = results.compactMap(\.statusReason).first
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAuthorizingCredentials = false
                self.credentialAccess.notice = notice
                self.refresh(preservingCredentialNotice: notice)
            }
        }
    }

    func removeLegacyAnthropicSignIn() {
        do {
            try store.delete(.anthropicOAuth)
            refresh()
        } catch {
            let reason = ChatFault.from(error).reason
            credentialAccess.notice = reason
            refresh(preservingCredentialNotice: reason)
        }
    }

    func beginCodexSignIn() {
        guard codexSignIn != .signingIn else { return }
        codexSignIn = .signingIn
        Task { [weak self] in
            guard let self else { return }
            do {
                let login = try await self.codexClient.beginLogin()
                guard NSWorkspace.shared.open(login.authorizationURL) else {
                    throw ChatFault.refuse(
                        code: "unreachable",
                        reason: "The ChatGPT sign-in page could not open")
                }
                try await self.codexClient.waitForLogin(login.loginID)
                self.codexSignIn = .idle
                self.refresh()
            } catch is CancellationError {
                self.codexSignIn = .idle
            } catch {
                self.codexSignIn = .failed(ChatFault.from(error).reason)
            }
        }
    }

    func signOutCodex() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.codexClient.logout()
                self.codexSignIn = .idle
                self.refresh()
            } catch {
                self.codexSignIn = .failed(ChatFault.from(error).reason)
            }
        }
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
        /* Saved before the answer, not after: a prompt lost to a crash
           mid-answer is the one a person minds most. */
        persistCurrentChat()
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

    func newChat(in projectID: ChatProjectID? = nil) {
        guard !isStreaming else { return }
        persistCurrentChat()
        conversation = []
        transcript = []
        guard let chatStore else { return }
        do {
            let created = try chatStore.createChat(in: projectID)
            selectedChatID = created.id
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    // MARK: - Saved chats

    /* The page's side of persistence. Two rules run through all of it:
       a transcript is read only when its chat is SELECTED, and the
       harness is untouched — the wire's conversation key stays what it
       was, because which chat a person is reading is a host-side idea
       the guest has never been told about. */

    /// Called when the page appears. Idempotent: the catalog is read
    /// every time (cheap, metadata only), the adoption happens once.
    func bootstrapChats() {
        guard let chatStore else { return }
        defer { reloadChatCatalog() }
        guard !didBootstrapChats else { return }
        didBootstrapChats = true
        do {
            /* Whatever is already on screen becomes chat #1 rather than
               being lost the first time this runs against an existing
               session. */
            let adopted = try chatStore.bootstrap(
                adopting: storedTranscript())
            selectedChatID = adopted.id
            if !storedTranscript().isEmpty { return }
            apply(try chatStore.loadTranscript(adopted.id))
        } catch {
            note(error)
        }
    }

    /// Switch chats: the outgoing one is written, the incoming one is
    /// read — the only place a transcript file is opened.
    func selectChat(_ id: ChatID) {
        guard let chatStore, id != selectedChatID, !isStreaming else { return }
        persistCurrentChat()
        do {
            let loaded = try chatStore.loadTranscript(id)
            selectedChatID = id
            apply(loaded)
            storageNotice = nil
        } catch {
            note(error)
        }
        reloadChatCatalog()
    }

    func renameChat(_ id: ChatID, to title: String) {
        guard let chatStore else { return }
        do {
            try chatStore.rename(id, to: title)
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    func deleteChat(_ id: ChatID) {
        guard let chatStore, !(isStreaming && id == selectedChatID)
        else { return }
        do {
            try chatStore.delete(id)
            reloadChatCatalog()
            guard id == selectedChatID else { return }
            selectedChatID = nil
            conversation = []
            transcript = []
            if let next = chats.first {
                selectChat(next.id)
            } else {
                newChat()
            }
        } catch {
            note(error)
        }
    }

    func fileChat(_ id: ChatID, under projectID: ChatProjectID?) {
        guard let chatStore else { return }
        do {
            try chatStore.move(id, to: projectID)
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    @discardableResult
    func newChatProject(name: String) -> ChatProjectRecord? {
        guard let chatStore else { return nil }
        do {
            let created = try chatStore.createProject(name: name)
            reloadChatCatalog()
            return created
        } catch {
            note(error)
            return nil
        }
    }

    func renameChatProject(_ id: ChatProjectID, to name: String) {
        guard let chatStore else { return }
        do {
            try chatStore.renameProject(id, to: name)
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    /// Removes the folder; its chats stay, unfiled.
    func deleteChatProject(_ id: ChatProjectID) {
        guard let chatStore else { return }
        do {
            try chatStore.deleteProject(id)
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    /// Associates a chat project with a Projects-module project — the
    /// build target and code half of the same piece of work.
    func associateChatProject(_ id: ChatProjectID, with linked: ProjectID?) {
        guard let chatStore else { return }
        do {
            try chatStore.associate(id, with: linked)
            reloadChatCatalog()
        } catch {
            note(error)
        }
    }

    /// Writes the open chat, and names an untitled one after its first
    /// prompt. Called when a turn ends and when the selection moves;
    /// cheap enough to call more often than that.
    func persistCurrentChat() {
        guard let chatStore, let id = selectedChatID else { return }
        let stored = storedTranscript()
        guard !stored.isEmpty else { return }
        do {
            try chatStore.saveTranscript(stored, for: id)
            if let summary = try? chatStore.summary(id),
                summary.title == ChatStore.untitled {
                try chatStore.rename(id, to: ChatStore.title(for: stored))
            }
            reloadChatCatalog()
            storageNotice = nil
        } catch {
            note(error)
        }
    }

    private func reloadChatCatalog() {
        guard let chatStore else { return }
        chats = (try? chatStore.list()) ?? chats
        chatProjects = (try? chatStore.listProjects()) ?? chatProjects
    }

    private func note(_ error: Error) {
        storageNotice = (error as? LocalizedError)?.errorDescription
            ?? "\(error)"
    }

    /// The live pane in the store's vocabulary.
    private func storedTranscript() -> StoredChatTranscript {
        StoredChatTranscript(
            rows: transcript.map(StoredChatRow.init(displaying:)),
            turns: conversation)
    }

    private func apply(_ stored: StoredChatTranscript) {
        transcript = stored.rows.map(\.displayRow)
        conversation = stored.turns
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
            persistCurrentChat()
        }
    }
}
