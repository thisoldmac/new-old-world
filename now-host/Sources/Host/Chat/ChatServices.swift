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
    /// Asked fresh per chat.models — a guest never reads a page cache.
    private let providers: () async -> [ChatCatalogProvider]
    /// The named provider's full list; the paging and the refs happen
    /// here, so the page never learns about frames.
    private let models: (String) async -> [ChatModel]?

    private var conversations: [GuestKey: [ChatTurn]] = [:]
    private struct ActiveTurn {
        let requestID: Int
        var seq: Int = 0
        var pendingText: String = ""
        var flushScheduled = false
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

    init(
        harness: ChatHarness,
        providers: @escaping () async -> [ChatCatalogProvider],
        models: @escaping (String) async -> [ChatModel]?
    ) {
        self.harness = harness
        self.providers = providers
        self.models = models
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
        }
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
        conversations[key] = nil
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
        var conversation = conversations[key] ?? []
        conversation.append(.user(request.prompt))
        conversations[key] = conversation
        active[key] = ActiveTurn(requestID: request.id)

        let turns = conversation
        Task { [weak self, weak asker, harness] in
            let started = await harness.run(
                conversation: key.text,
                wireModelID: wireModelID,
                transcript: turns,
                addressing: key.text,
                origin: .guestWire
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
        asker.send(.chatResult(ChatResult(
            id: request.id, ok: true, code: nil, message: nil)))
    }

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
            status(line, key: key, on: asker)
        case .toolStarted(let name):
            flush(key: key, on: asker)
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
        active[key] = turn
        for frame in frames {
            asker.send(.chatDelta(frame))
        }
    }

    private func status(_ text: String, key: GuestKey, on asker: Session) {
        guard let turn = active[key] else { return }
        asker.send(.chatStatus(ChatStatus(
            id: turn.requestID, text: CloudText.displayable(text))))
    }

    private func result(
        _ result: ChatResult, key: GuestKey, on asker: Session,
        clearActive: Bool
    ) {
        if clearActive { active[key] = nil }
        asker.send(.chatResult(result))
    }
}
