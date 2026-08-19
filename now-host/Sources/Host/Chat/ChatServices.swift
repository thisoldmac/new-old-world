import Foundation

/* The host's half of the chat.* family: what the harness is willing to
   say to a classic Mac. The conversation lives HERE, per connection —
   the guest sends one turn and never history — and every string that
   leaves is converted first (CloudText.displayable), because the
   modern machine is the only side that can spell both alphabets.

   The one bound worth stating twice: a chat.delta frame is sized by
   MEASURED encoded bytes against the 4 KB control cap, through the
   same codec that will put it on the wire. The cap has been stated in
   three places before in this project and cost a wire; this reading
   of it cannot drift from the sender because it IS the sender. */

extension GuestListener {
    enum ChatAsk {
        case models(ChatModels)
        case send(ChatSend)
        case cancel(ChatCancel)
        case reset(ChatReset)
        case chats(ChatChats)
        case open(ChatOpen)
        case history(ChatHistory)
        case projects(ChatProjects)
        case project(ChatProject)
        case skillList(ChatSkills)
    }

    /// Like the cloud serves: answered for any connected guest, down
    /// the connection that asked. No service wired is the honest
    /// pre-family answer — silence, which the guest's own deadline
    /// turns into "that Mac offers no chat".
    func serveChat(_ ask: ChatAsk, on asker: Session) {
        guard let service = chatService else { return }
        service.serve(ask, on: asker)
    }
}

/// Sizes chat.delta frames by measured encode. Pure, so the arithmetic
/// has a test that feeds it hostile text.
enum ChatDeltaChunking {
    static let controlCap = 4096

    /// Splits converted text into deltas whose ENCODED frames each fit
    /// the control cap, seq numbered from `firstSeq`.
    static func frames(id: Int, firstSeq: Int, text: String) -> [ChatDelta] {
        var frames: [ChatDelta] = []
        var seq = firstSeq
        var remaining = Substring(text)
        while !remaining.isEmpty {
            var piece = remaining
            while !fits(ChatDelta(id: id, seq: seq, text: String(piece))) {
                let half = piece.index(
                    piece.startIndex,
                    offsetBy: max(1, piece.count / 2))
                piece = piece[..<half]
            }
            frames.append(ChatDelta(id: id, seq: seq, text: String(piece)))
            seq += 1
            remaining = remaining[piece.endIndex...]
        }
        return frames
    }

    static func fits(_ delta: ChatDelta) -> Bool {
        guard let encoded = try? ControlMessageCodec.encode(.chatDelta(delta))
        else { return false }
        return encoded.count <= controlCap
    }
}

/// Owns the wire's conversations: one per connection, one turn
/// streaming at a time per connection, all of it through the same
/// harness the host page drives.
@MainActor
final class ChatWireService {
    private let harness: ChatHarness
    /// Cached at construction from the harness, because reading it is
    /// an actor hop and a slash command is answered on the main actor.
    private let skills: ChatSkillLibrary
    /// Asked fresh per chat.models — a guest never reads a page cache.
    private let providers: () async -> [ChatCatalogProvider]
    /// The named provider's full list; the paging and the refs happen
    /// here, so the page never learns about frames.
    private let models: (String) async -> [ChatModel]?

    /// Where a guest's conversations live now. Optional because a store
    /// that cannot be opened must not take chat down with it: without
    /// one the family behaves exactly as it did before this slice —
    /// one conversation per connection, held in memory, gone on
    /// disconnect — and every session ask answers honestly unavailable.
    private let store: ChatStore?
    /// Which saved chat each connection is currently on.
    private var currentChat: [GuestKey: ChatID] = [:]
    /// The in-memory fallback, and the working copy while a turn runs.
    private var conversations: [GuestKey: [ChatTurn]] = [:]
    /// Minted refs for chats and projects, per connection — the model
    /// ref rule: a title or a project name is a person's sentence and
    /// outgrows a classic buffer, so only opaque refs cross.
    /// Which skills this connection has loaded, in the order they were
    /// asked for. Per connection rather than per chat: a person loads a
    /// skill for the work they are doing now, and carrying it into a
    /// chat they reopen a week later would be a surprise.
    private var loadedSkills: [GuestKey: [String]] = [:]
    private var chatRefs: [GuestKey: [String: ChatID]] = [:]
    private var projectRefs: [GuestKey: [String: ChatProjectID]] = [:]
    /// Mints the ProjectStore half of a created chat project — the
    /// once-dead `linkedProjectID`/`associate` seam, wired. Injected
    /// because the store project is the adapter's authority, not this
    /// service's; nil (tests, degraded hosts) files the chat folder
    /// alone, which is still worth having.
    private let mintLinkedProject: ((String, ProjectHome, String?) async
        -> Result<ProjectID, ProjectGround.Refusal>)?
    private struct ActiveTurn {
        let requestID: Int
        var seq: Int = 0
        var pendingText: String = ""
        var flushScheduled = false
        /// The last thing this turn was seen doing, repeated by the
        /// heartbeat. Empty until something happens.
        var lastActivity: String = ""
        /// When a frame for this turn last left. The heartbeat measures
        /// silence from here, so a talkative turn costs no extra frames.
        var lastFrameAt: Date = .init()
    }
    private var active: [GuestKey: ActiveTurn] = [:]

    /* The ref table: what chat.send's opaque refs mean, per
       connection. Minted fresh for every models page ("m1", "m2", ...,
       one counter per connection so refs never collide across
       providers or re-asks), resolved at send, gone with the session.
       A provider's model NAME never crosses the wire: names are
       unbounded out in the world and a classic buffer is not (metal,
       2026-08-02 - a 48-byte name lost its last byte and every send
       of it answered not-found). */
    private var refs: [GuestKey: [String: String]] = [:]
    private var minted: [GuestKey: Int] = [:]

    /// The guest's own arithmetic: 512 raw bytes escape to at most
    /// 3072 on the wire plus envelope, inside the 4 KB cap. Stated in
    /// the contract on ChatSend.prompt; this mirrors it.
    static let promptCap = 512
    /// Rows per chat.catalog models page — the contract's frame bound;
    /// `more` carries the rest.
    static let pageRows = 16
    /// How long a turn may go without a frame before this side says
    /// something anyway.
    ///
    /// **The contract obliges the host, not the guest**: "a host that
    /// serves chat MUST keep one of the two flowing while a turn is
    /// open — a guest is entitled to declare a turn dead after 60
    /// seconds of total silence and cancel it" (hostServesChat). The
    /// harness's own tools answer in seconds and never came close. The
    /// workspace lane does: one `Bash` call running a cross-compile is
    /// several minutes inside a single tool, and the runtime says
    /// nothing until it returns — so without this, a guest that asked
    /// for a build would correctly kill it at sixty seconds and the
    /// person would watch a build die for looking dead.
    ///
    /// Well under the deadline rather than near it, because the frame
    /// still has a slow wire to cross.
    static let heartbeat: TimeInterval = 20

    private let heartbeatInterval: TimeInterval

    /// Rows per roster page — the frame bound, `more` carries the rest.
    static let rosterRows = 12
    /// Transcript rows per history page.
    static let historyRows = 24

    init(
        harness: ChatHarness,
        providers: @escaping () async -> [ChatCatalogProvider],
        models: @escaping (String) async -> [ChatModel]?,
        store: ChatStore? = nil,
        heartbeatInterval: TimeInterval = ChatWireService.heartbeat,
        mintLinkedProject: ((String, ProjectHome, String?) async
            -> Result<ProjectID, ProjectGround.Refusal>)? = nil
    ) {
        self.harness = harness
        self.skills = harness.skills
        self.providers = providers
        self.models = models
        self.store = store
        self.heartbeatInterval = heartbeatInterval
        self.mintLinkedProject = mintLinkedProject
    }

    func serve(_ ask: GuestListener.ChatAsk, on asker: Session) {
        switch ask {
        case .models(let request):
            serveModels(request, on: asker)
        case .send(let request):
            serveSend(request, on: asker)
        case .cancel(let request):
            serveCancel(request, on: asker)
        case .reset(let request):
            serveReset(request, on: asker)
        case .chats(let request):
            serveChats(request, on: asker)
        case .open(let request):
            serveOpen(request, on: asker)
        case .history(let request):
            serveHistory(request, on: asker)
        case .projects(let request):
            serveProjects(request, on: asker)
        case .project(let request):
            serveProject(request, on: asker)
        case .skillList(let request):
            serveSkills(request, on: asker)
        }
    }

    /// The same catalogue the system prompt carries, as rows a guest
    /// can draw. One page in practice — the shipped tree is a handful —
    /// but paged in shape so a grown tree never breaks a frame bound.
    private func serveSkills(_ request: ChatSkills, on asker: Session) {
        let rows = skills.skills.prefix(12).map { skill in
            ChatSkillRow(
                command: String(skill.command.prefix(40)),
                detail: skill.description.isEmpty
                    ? nil : String(CloudText.displayable(
                        skill.description).prefix(96)))
        }
        asker.send(.chatSkillRoster(ChatSkillRoster(
            id: request.id, skills: Array(rows),
            more: skills.skills.count > rows.count)))
    }

    private func serveModels(_ request: ChatModels, on asker: Session) {
        guard let key = asker.guestKey else { return }
        guard let providerID = request.provider else {
            Task { [weak self, weak asker] in
                guard let self else { return }
                let rows = Array(await self.providers().prefix(8))
                await MainActor.run {
                    asker?.send(.chatCatalog(ChatCatalog(
                        id: request.id, providers: rows)))
                }
            }
            return
        }
        Task { [weak self, weak asker] in
            guard let self else { return }
            let list = await self.models(providerID) ?? []
            await MainActor.run {
                guard let asker else { return }
                self.sendModelsPage(
                    request, providerID: providerID, list: list,
                    key: key, on: asker)
            }
        }
    }

    private func sendModelsPage(
        _ request: ChatModels, providerID: String, list: [ChatModel],
        key: GuestKey, on asker: Session
    ) {
        let start = min(max(0, request.cursor ?? 0), list.count)
        let page = list[start..<min(start + Self.pageRows, list.count)]
        let rows = page.map { model -> ChatCatalogModel in
            let count = (minted[key] ?? 0) + 1
            minted[key] = count
            let ref = "m\(count)"
            refs[key, default: [:]][ref] = model.wireID
            return ChatCatalogModel(
                ref: ref,
                label: ChatWireText.label(model.displayName),
                detail: nil)
        }
        asker.send(.chatCatalog(ChatCatalog(
            id: request.id, provider: providerID, models: rows,
            more: start + page.count < list.count)))
    }

    func sessionClosed(key: GuestKey?) {
        guard let key else { return }
        /* The conversation is no longer lost with the link — it is on
           disk. What goes is this connection's view of it: the working
           copy and every ref minted for it, because a ref is a promise
           about one connection's listing and nothing else. */
        conversations[key] = nil
        currentChat[key] = nil
        loadedSkills[key] = nil
        chatRefs[key] = nil
        projectRefs[key] = nil
        refs[key] = nil
        minted[key] = nil
        if active[key] != nil {
            active[key] = nil
            Task { [harness] in
                _ = await harness.cancel(conversation: key.text)
            }
        }
    }

    private func serveSend(_ request: ChatSend, on asker: Session) {
        guard let key = asker.guestKey else { return }
        guard active[key] == nil else {
            result(
                ChatResult(id: request.id, ok: false, code: "busy",
                           message: "An answer is still arriving"),
                key: key, on: asker, clearActive: false)
            return
        }
        guard request.prompt.utf8.count <= Self.promptCap else {
            result(
                ChatResult(id: request.id, ok: false, code: "too-long",
                           message: "The prompt is over \(Self.promptCap) bytes"),
                key: key, on: asker, clearActive: false)
            return
        }
        guard let wireModelID = refs[key]?[request.ref] else {
            result(
                ChatResult(id: request.id, ok: false, code: "unknown-model",
                           message: "No model with that ref on this connection"),
                key: key, on: asker, clearActive: false)
            return
        }
        /* The conversation comes from the STORE when there is one, so
           a turn typed after a reconnect continues the chat the person
           was in rather than a fresh page that looks identical. The
           in-memory copy is the working one for the turn. */
        var chatID: ChatID?
        if let store {
            chatID = ensureCurrent(key, store: store)
            if let chatID, conversations[key] == nil {
                conversations[key] =
                    (try? store.loadTranscript(chatID))?.turns ?? []
            }
        }
        /* A slash is a command, answered HERE with no model turn and no
           line in the conversation the model is re-sent. It reaches the
           same place from either face because it is only ever prompt
           text — which is why this costs no contract change and no
           second verb for the console to fall behind on. */
        if let command = ChatSlashCommand.parse(
            request.prompt, known: harnessSkills.names) {
            serveSlash(command, request: request, key: key, on: asker)
            return
        }
        var conversation = conversations[key] ?? []
        conversation.append(.user(request.prompt))
        conversations[key] = conversation
        persist(key: key, appending: [
            StoredChatRow(kind: .person, text: request.prompt,
                          toolName: nil, toolOK: nil),
        ], turns: conversation, titledBy: request.prompt)
        active[key] = ActiveTurn(requestID: request.id)
        beat(key: key, on: asker, requestID: request.id)

        let mode = ChatMode(wire: request.mode)
        let loaded = skillsFor(key)
        let turns = conversation
        Task { [weak self, weak asker, harness] in
            let started = await harness.run(
                conversation: key.text,
                wireModelID: wireModelID,
                transcript: turns,
                addressing: key.text,
                origin: .guestWire,
                mode: mode,
                loadedSkills: loaded
            ) { [weak self, weak asker] event in
                Task { @MainActor [weak self, weak asker] in
                    guard let self, let asker else { return }
                    self.handle(event, key: key, on: asker)
                }
            }
            if !started {
                // The busy gate above makes this unreachable in
                // practice; answer honestly anyway rather than hang.
                await MainActor.run { [weak self, weak asker] in
                    guard let self, let asker else { return }
                    self.result(
                        ChatResult(id: request.id, ok: false, code: "busy",
                                   message: "An answer is still arriving"),
                        key: key, on: asker, clearActive: true)
                }
            }
        }
    }

    private func serveCancel(_ request: ChatCancel, on asker: Session) {
        guard let key = asker.guestKey else { return }
        guard let turn = active[key], turn.requestID == request.id else {
            // Always answered — an unknown id gets not-running, the
            // exec.cancel hardening inherited rather than rediscovered.
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: false, code: "not-running",
                message: nil)))
            return
        }
        Task { [harness] in
            _ = await harness.cancel(conversation: key.text)
            // The cancelled run's finished(cancelled) event sends the
            // terminal chat.result - one result per send, exec's rule.
        }
    }

    private func serveReset(_ request: ChatReset, on asker: Session) {
        guard let key = asker.guestKey else { return }
        guard active[key] == nil else {
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: false, code: "busy",
                message: "Cancel the streaming answer first")))
            return
        }
        conversations[key] = []
        /* A blank page is now a NEW CHAT rather than an erasure: the
           one it replaces is on disk and listed a moment later. It
           inherits the project the person was working in, because
           "new chat" while inside a project means another chat in that
           project, not a trip back to the top. */
        if let store {
            let project = (try? currentSummary(key, store: store))?.projectID
            currentChat[key] = try? store.createChat(
                in: project, origin: .guest).id
        }
        asker.send(.chatResult(ChatResult(
            id: request.id, ok: true, code: nil, message: nil)))
    }

    // MARK: - Skills

    /// The library the HARNESS holds, asked of it rather than read
    /// again here: two libraries could list different names, and a
    /// command the parser accepted but the prompt never carried would
    /// be a skill that loads and does nothing.
    private var harnessSkills: ChatSkillLibrary { skills }

    /// What the wire face will accept as a slash command. Exposed so a
    /// test drives the names this build actually installed rather than
    /// a name it invented — a fixture name would pass with `skills/`
    /// missing entirely.
    var installedSkillNames: [String] { harnessSkills.names }

    private func skillsFor(_ key: GuestKey) -> [String] {
        loadedSkills[key] ?? []
    }

    private func serveSlash(
        _ command: ChatSlashCommand, request: ChatSend,
        key: GuestKey, on asker: Session
    ) {
        func answer(_ text: String) {
            /* Delivered as DELTA then result, the family's one shape for
               "here is some text": a guest that had to learn a second
               way to receive words would be a second thing to get
               wrong, and the page already draws deltas. */
            let converted = CloudText.displayable(text)
            for frame in ChatDeltaChunking.frames(
                id: request.id, firstSeq: 0, text: converted) {
                asker.send(.chatDelta(frame))
            }
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: true, code: nil, message: nil)))
        }
        switch command {
        case .list:
            let skills = harnessSkills.skills
            guard !skills.isEmpty else {
                return answer("No skills are installed on the other Mac.")
            }
            var lines = ["Skills you can load:"]
            for skill in skills {
                lines.append("\(skill.command)")
                lines.append("   \(skill.description)")
            }
            if !skillsFor(key).isEmpty {
                lines.append("Loaded now: "
                    + skillsFor(key).map { "/" + $0 }.joined(separator: " "))
            }
            answer(lines.joined(separator: "\n"))
        case .unknown(let name):
            /* Not passed to the model. Somebody who mistyped wants to be
               told, not to watch a model improvise an answer to it. */
            answer("No skill called /\(name). Type /skills for the list.")
        case .load(let name, let rest):
            var loaded = skillsFor(key)
            if !loaded.contains(name) {
                loaded.append(name)
                loadedSkills[key] = loaded
            }
            let skill = harnessSkills[name]
            if rest.isEmpty {
                answer("Loaded /\(name). "
                    + (skill?.description ?? "")
                    + " It applies from your next message.")
            } else {
                /* A command with a question after it does both, so
                   "/classic-mac-carbon-ui how do I draw a tab?" is one
                   round trip rather than two. */
                answer("Loaded /\(name).")
                var followUp = request
                followUp.prompt = rest
                serveSend(followUp, on: asker)
            }
        }
    }

    // MARK: - Sessions, history and projects

    /// The store, or a served refusal. One place, so every session ask
    /// answers the same way when saving is unavailable rather than
    /// four subtly different ways.
    private func requireStore(id: Int, on asker: Session) -> ChatStore? {
        guard let store else {
            asker.send(.chatResult(ChatResult(
                id: id, ok: false, code: "unreachable",
                message: "Saved chats are unavailable on this Mac")))
            return nil
        }
        return store
    }

    private func currentSummary(_ key: GuestKey, store: ChatStore) throws
        -> ChatSummary? {
        guard let id = currentChat[key] else { return nil }
        return try? store.summary(id)
    }

    /// The chat this connection writes to, made if it does not exist —
    /// a person who just starts typing gets a saved chat without having
    /// asked for one.
    private func ensureCurrent(_ key: GuestKey, store: ChatStore) -> ChatID? {
        if let id = currentChat[key], (try? store.summary(id)) != nil {
            return id
        }
        let made = try? store.createChat(origin: .guest)
        currentChat[key] = made?.id
        return made?.id
    }

    private func serveChats(_ request: ChatChats, on asker: Session) {
        guard let key = asker.guestKey,
              let store = requireStore(id: request.id, on: asker) else { return }
        guard let all = try? store.list() else {
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: false, code: "provider-error",
                message: "The saved chats could not be read")))
            return
        }
        let start = min(max(0, request.cursor ?? 0), all.count)
        let page = all[start..<min(start + Self.rosterRows, all.count)]
        let current = currentChat[key]
        let rows = page.map { summary -> ChatRosterRow in
            let ref = mintChatRef(summary.id, key: key)
            var detail = summary.turnCount == 0
                ? "empty" : "\(summary.turnCount) turns"
            detail += " - " + Self.when.string(from: summary.updatedAt)
            return ChatRosterRow(
                ref: ref,
                label: ChatWireText.label(summary.title),
                origin: summary.whereTyped.rawValue,
                project: summary.projectID.flatMap {
                    projectRef(for: $0, key: key)
                },
                detail: CloudText.displayable(detail),
                current: summary.id == current ? true : nil)
        }
        asker.send(.chatRoster(ChatRoster(
            id: request.id, chats: Array(rows),
            more: start + page.count < all.count)))
    }

    private func serveOpen(_ request: ChatOpen, on asker: Session) {
        guard let key = asker.guestKey,
              let store = requireStore(id: request.id, on: asker) else { return }
        guard active[key] == nil else {
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: false, code: "busy",
                message: "Cancel the streaming answer first")))
            return
        }
        guard let id = chatRefs[key]?[request.ref],
              let summary = try? store.summary(id) else {
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: false, code: "unknown-model",
                message: "No chat with that ref on this connection")))
            return
        }
        /* The turns are read HERE and the rows are not: the model needs
           the conversation to answer, the guest asks for the rows it can
           draw. Opening a long chat therefore costs one read on this
           side and nothing on the wire. */
        currentChat[key] = summary.id
        conversations[key] = (try? store.loadTranscript(summary.id))?.turns ?? []
        asker.send(.chatResult(ChatResult(
            id: request.id, ok: true, code: nil, message: nil)))
    }

    private func serveHistory(_ request: ChatHistory, on asker: Session) {
        guard let key = asker.guestKey,
              let store = requireStore(id: request.id, on: asker) else { return }
        guard let id = currentChat[key],
              let transcript = try? store.loadTranscript(id) else {
            // A conversation nobody has saved yet has no history, and
            // that is an answer rather than a fault.
            asker.send(.chatTranscript(ChatTranscript(
                id: request.id, rows: [], more: false)))
            return
        }
        /* Counted from the END: the newest page first, older pages by
           asking again. That is what makes an open cheap on a machine
           that can hold 300 lines of a transcript with thousands. */
        let rows = transcript.rows
        let taken = min(max(0, request.cursor ?? 0), rows.count)
        let end = rows.count - taken
        let start = max(0, end - Self.historyRows)
        let page = rows[start..<end].map {
            ChatTranscriptRow(
                kind: $0.kind.rawValue,
                text: CloudText.displayable($0.text))
        }
        asker.send(.chatTranscript(ChatTranscript(
            id: request.id, rows: Array(page), more: start > 0)))
    }

    private func serveProjects(_ request: ChatProjects, on asker: Session) {
        guard let key = asker.guestKey,
              let store = requireStore(id: request.id, on: asker) else { return }
        let all = (try? store.listProjects()) ?? []
        let start = min(max(0, request.cursor ?? 0), all.count)
        let page = all[start..<min(start + Self.rosterRows, all.count)]
        let current = (try? currentSummary(key, store: store))??.projectID
        let rows = page.map { record -> ChatProjectRow in
            ChatProjectRow(
                ref: mintProjectRef(record.id, key: key),
                label: ChatWireText.label(record.name),
                home: record.intendedHome?.rawValue,
                current: record.id == current ? true : nil)
        }
        asker.send(.chatProjectRoster(ChatProjectRoster(
            id: request.id, projects: Array(rows),
            more: start + page.count < all.count)))
    }

    private func serveProject(_ request: ChatProject, on asker: Session) {
        guard let key = asker.guestKey,
              let store = requireStore(id: request.id, on: asker) else { return }
        func answer(_ ok: Bool, _ code: String? = nil, _ message: String? = nil) {
            asker.send(.chatResult(ChatResult(
                id: request.id, ok: ok, code: code,
                message: message.map(CloudText.displayable))))
        }
        guard let chat = ensureCurrent(key, store: store) else {
            return answer(false, "provider-error", "This chat could not be saved")
        }
        switch request.op {
        case "none":
            _ = try? store.move(chat, to: nil)
            answer(true)
        case "select":
            guard let ref = request.ref,
                  let project = projectRefs[key]?[ref] else {
                return answer(false, "unknown-model",
                              "No project with that ref on this connection")
            }
            guard (try? store.move(chat, to: project)) != nil else {
                return answer(false, "provider-error",
                              "The chat could not be filed there")
            }
            answer(true)
        case "create":
            guard let name = request.name, !name.isEmpty else {
                return answer(false, "provider-error", "A project needs a name")
            }
            /* Absent home is REFUSED rather than defaulted. Which
               machine holds the authoritative copy is the question this
               product exists to ask, and a default would answer it
               silently for somebody's source. */
            guard let home = request.home.flatMap(ProjectHome.init(rawValue:))
            else {
                return answer(false, "provider-error",
                              "Say whether the project lives on this Mac or "
                                  + "the modern one")
            }
            guard let record = try? store.createProject(
                name: name, intendedHome: home) else {
                return answer(false, "provider-error",
                              "The project could not be made")
            }
            _ = try? store.move(chat, to: record.id)
            /* The chat folder exists either way — it is not worthless
               without a store project. The CODE half is minted through
               the same ground rules as an agent create (ProjectGround):
               a guest home is a typed refusal there, because
               ProjectStore requires a verified guest digest — the
               classic Mac holds the authoritative copy and a second
               minter of guest projects is exactly the drift this
               contract exists to prevent — so the answer is ok, filed,
               with the refusal's own story. A host home mints a real
               starter project and wires the once-dead associate seam. */
            guard let mintLinkedProject else {
                return answer(true, nil, home == .guest
                    ? "Filed. Its code is staged here and promoted to "
                        + "this machine when you build it."
                    : "Filed. Its code lives on the modern Mac.")
            }
            Task { @MainActor in
                /* The wire carries home only; the toolchain follows
                   from ProjectGround's defaulting rule. */
                switch await mintLinkedProject(name, home, nil) {
                case .success(let projectID):
                    _ = try? store.associate(record.id, with: projectID)
                    answer(true, nil, "Filed. A starter project was "
                        + "minted on the modern Mac and linked; build "
                        + "it to see it here.")
                case .failure(let refusal):
                    answer(true, nil,
                           "Filed as a chat folder. " + refusal.message)
                }
            }
        default:
            answer(false, "provider-error", "Unknown project operation")
        }
    }

    /// Appends to the current chat's saved transcript, refreshing the
    /// turns wholesale and the rows by addition.
    ///
    /// Best-effort by design: a store that cannot be written must not
    /// take a live conversation down, so a failure here loses the
    /// SAVING of a turn and never the turn.
    private func persist(
        key: GuestKey, appending rows: [StoredChatRow],
        turns: [ChatTurn], titledBy prompt: String?
    ) {
        guard let store, let id = ensureCurrent(key, store: store) else {
            return
        }
        var transcript = (try? store.loadTranscript(id)) ?? StoredChatTranscript()
        transcript.rows.append(contentsOf: rows)
        transcript.turns = turns
        _ = try? store.saveTranscript(transcript, for: id)
        /* A chat names itself after the first thing said in it, the way
           the host's own sidebar does — an untouched title only. */
        if let prompt, let summary = try? store.summary(id),
            summary.title == ChatStore.untitled {
            _ = try? store.rename(id, to: String(prompt.prefix(60)))
        }
    }

    /// What a finished turn leaves on the page. Tool calls become tool
    /// rows so a reopened chat still shows the model's hands.
    private static func rows(from turns: [ChatTurn]) -> [StoredChatRow] {
        turns.flatMap { turn -> [StoredChatRow] in
            turn.content.compactMap { content in
                switch content {
                case .text(let text):
                    return StoredChatRow(kind: .model, text: text,
                                         toolName: nil, toolOK: nil)
                case .toolCall(let call):
                    return StoredChatRow(kind: .tool, text: call.name,
                                         toolName: call.name, toolOK: nil)
                case .toolResult:
                    return nil
                }
            }
        }
    }

    private func mintChatRef(_ id: ChatID, key: GuestKey) -> String {
        if let existing = chatRefs[key]?.first(where: { $0.value == id })?.key {
            return existing
        }
        let count = (minted[key] ?? 0) + 1
        minted[key] = count
        let ref = "c\(count)"
        chatRefs[key, default: [:]][ref] = id
        return ref
    }

    private func mintProjectRef(_ id: ChatProjectID, key: GuestKey) -> String {
        if let existing = projectRefs[key]?
            .first(where: { $0.value == id })?.key {
            return existing
        }
        let count = (minted[key] ?? 0) + 1
        minted[key] = count
        let ref = "p\(count)"
        projectRefs[key, default: [:]][ref] = id
        return ref
    }

    private func projectRef(for id: ChatProjectID, key: GuestKey) -> String? {
        projectRefs[key]?.first(where: { $0.value == id })?.key
            ?? mintProjectRef(id, key: key)
    }

    private static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    // MARK: - Streaming back

    private func handle(
        _ event: ChatHarnessEvent, key: GuestKey, on asker: Session
    ) {
        guard var turn = active[key] else { return }
        switch event {
        case .delta(let part):
            turn.pendingText += part
            active[key] = turn
            // Coalesce: token-sized frames would flood a 68030. Flush
            // early once a frame's worth is waiting.
            if turn.pendingText.utf8.count >= 1024 {
                flush(key: key, on: asker)
            } else if !turn.flushScheduled {
                turn.flushScheduled = true
                active[key] = turn
                Task { @MainActor [weak self, weak asker] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, let asker else { return }
                    self.flush(key: key, on: asker)
                }
            }
        case .activity(let line):
            flush(key: key, on: asker)
            remember(line, key: key)
            status(line, key: key, on: asker)
        case .toolStarted(let name):
            flush(key: key, on: asker)
            remember("Using \(name)", key: key)
            status("Using \(name)", key: key, on: asker)
        case .toolFinished:
            // The next delta or status says what happened; a per-tool
            // "done" line would be noise on a one-line display.
            break
        case .finished(let outcome):
            flush(key: key, on: asker)
            status("", key: key, on: asker)
            var conversation = conversations[key] ?? []
            conversation.append(contentsOf: outcome.appended)
            conversations[key] = conversation
            /* Saved at the END of the turn, and only the answer text:
               the rows are what a page draws, the turns are what the
               model is re-sent, and both halves are needed because
               either alone loses something (ChatStore's own rule). */
            persist(key: key, appending: Self.rows(from: outcome.appended),
                    turns: conversation, titledBy: nil)
            result(
                ChatResult(
                    id: turn.requestID, ok: outcome.ok,
                    code: outcome.ok ? nil : (outcome.code ?? "provider-error"),
                    message: outcome.message.map(CloudText.displayable)),
                key: key, on: asker, clearActive: true)
        }
    }

    private func flush(key: GuestKey, on asker: Session) {
        guard var turn = active[key] else { return }
        turn.flushScheduled = false
        let text = turn.pendingText
        turn.pendingText = ""
        guard !text.isEmpty else {
            active[key] = turn
            return
        }
        // Convert AFTER coalescing, so a combining mark is never split
        // from its base across a chunk boundary.
        let converted = CloudText.displayable(text)
        let frames = ChatDeltaChunking.frames(
            id: turn.requestID, firstSeq: turn.seq, text: converted)
        turn.seq += frames.count
        turn.lastFrameAt = Date()
        active[key] = turn
        for frame in frames {
            asker.send(.chatDelta(frame))
        }
    }

    private func status(_ text: String, key: GuestKey, on asker: Session) {
        guard var turn = active[key] else { return }
        turn.lastFrameAt = Date()
        active[key] = turn
        asker.send(.chatStatus(ChatStatus(
            id: turn.requestID, text: CloudText.displayable(text))))
    }

    private func remember(_ line: String, key: GuestKey) {
        guard var turn = active[key] else { return }
        turn.lastActivity = line
        active[key] = turn
    }

    /// One self-rescheduling beat per turn, ending when the turn does.
    ///
    /// It repeats what the turn was last seen doing rather than
    /// inventing a new line, because the status field is display-only
    /// and un-sequenced: each replaces the last, so a repeat costs the
    /// guest nothing and a made-up line would be a claim. `requestID`
    /// is carried so a beat left over from a finished turn cannot speak
    /// for the next one.
    private func beat(key: GuestKey, on asker: Session, requestID: Int) {
        Task { @MainActor [weak self, weak asker] in
            let interval = self?.heartbeatInterval
                ?? ChatWireService.heartbeat
            try? await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, let asker,
                  let turn = self.active[key],
                  turn.requestID == requestID else { return }
            if Date().timeIntervalSince(turn.lastFrameAt) >= interval {
                let line = turn.lastActivity.isEmpty
                    ? "Working" : "Still: \(turn.lastActivity)"
                self.status(line, key: key, on: asker)
            }
            self.beat(key: key, on: asker, requestID: requestID)
        }
    }

    private func result(
        _ result: ChatResult, key: GuestKey, on asker: Session,
        clearActive: Bool
    ) {
        if clearActive { active[key] = nil }
        asker.send(.chatResult(result))
    }
}
