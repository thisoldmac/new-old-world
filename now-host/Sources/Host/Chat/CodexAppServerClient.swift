import Foundation

actor CodexAppServerClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    private struct ActiveTurn {
        let token: UUID
        let threadID: String
        let continuation:
            AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
        let workingDirectory: URL
    }

    private let transport: CodexAppServerTransport
    private var nextID = 1
    private var initialized = false
    private var startup: Task<Void, Error>?
    private var incomingTask: Task<Void, Never>?
    private var pending: [Int: PendingRequest] = [:]
    private var loginWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var turns: [String: ActiveTurn] = [:]
    private var turnByToken: [UUID: String] = [:]
    private var earlyTurnEvents: [String: [(String, [String: Any])]] = [:]

    init(transport: CodexAppServerTransport = SystemCodexAppServerTransport()) {
        self.transport = transport
    }

    func account() async throws -> CodexAccount? {
        try await ensureStarted()
        return try CodexJSON.account(await request(
            method: "account/read", params: ["refreshToken": false]))
    }

    func models() async throws -> [ChatModel] {
        try await ensureStarted()
        return try CodexJSON.models(await request(
            method: "model/list", params: ["limit": 100]))
    }

    func usage() async throws -> CodexUsageSnapshot {
        try await ensureStarted()
        async let limits = request(
            method: "account/rateLimits/read", params: [:])
        async let tokens = request(method: "account/usage/read", params: [:])
        return await CodexJSON.usage(
            rateLimits: try? limits, tokenUsage: try? tokens)
    }

    func beginLogin() async throws -> CodexLoginStart {
        try await ensureStarted()
        return try CodexJSON.login(await request(
            method: "account/login/start", params: ["type": "chatgpt"]))
    }

    func waitForLogin(_ loginID: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loginWaiters[loginID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    await self?.expireLogin(loginID)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelLogin(loginID) }
        }
    }

    func logout() async throws {
        try await ensureStarted()
        _ = try await request(method: "account/logout", params: [:])
    }

    nonisolated func stream(_ completion: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let token = UUID()
        return AsyncThrowingStream { continuation in
            Task {
                await self.beginTurn(
                    token: token, completion: completion,
                    continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task { await self.cancelTurn(token: token) }
            }
        }
    }

    private func ensureStarted() async throws {
        if initialized { return }
        if let startup { return try await startup.value }
        let task = Task { [weak self] in
            guard let self else { return }
            let (lines, continuation) = AsyncStream<String>.makeStream()
            try self.transport.start(
                receive: { line in
                    continuation.yield(line)
                },
                terminated: {
                    continuation.finish()
                })
            let incomingTask = Task { [weak self] in
                for await line in lines {
                    await self?.receive(line)
                }
                await self?.terminated()
            }
            await self.setIncomingTask(incomingTask)
            _ = try await self.rawRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "new-old-world",
                        "title": "New Old World",
                        "version": "1",
                    ],
                    "capabilities": [String: Any](),
                ], timeout: 15)
            try await self.sendNotification(method: "initialized", params: [:])
            await self.markInitialized()
        }
        startup = task
        do { try await task.value }
        catch {
            startup = nil
            transport.stop()
            throw error
        }
    }

    private func markInitialized() { initialized = true }

    private func setIncomingTask(_ task: Task<Void, Never>) {
        incomingTask = task
    }

    private func request(method: String, params: [String: Any]) async throws
        -> Data {
        try await ensureStarted()
        return try await rawRequest(method: method, params: params, timeout: 20)
    }

    private func rawRequest(
        method: String, params: [String: Any], timeout: TimeInterval
    ) async throws -> Data {
        let id = nextID
        nextID += 1
        let message = try CodexJSON.data([
            "id": id, "method": method, "params": params,
        ])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds:
                        UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(id)
                }
                pending[id] = PendingRequest(
                    continuation: continuation, timeout: timeoutTask)
                do { try transport.send(message) }
                catch {
                    pending.removeValue(forKey: id)?.timeout.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelRequest(id) }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try transport.send(CodexJSON.data([
            "method": method, "params": params,
        ]))
    }

    private func receive(_ line: String) {
        guard line.utf8.count <= 1_048_576,
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return }
        if let id = object["id"] as? Int,
            object["method"] == nil,
            let waiter = pending.removeValue(forKey: id) {
            waiter.timeout.cancel()
            if let error = object["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                waiter.continuation.resume(throwing: ChatFault.refuse(
                    code: "provider-error",
                    reason: "Codex request failed (\(code))"))
            } else {
                let result = object["result"] ?? [String: Any]()
                do { waiter.continuation.resume(returning:
                    try CodexJSON.data(result)) }
                catch { waiter.continuation.resume(throwing: error) }
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        if let id = object["id"] as? Int {
            refuseServerRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func refuseServerRequest(
        id: Int, method: String, params: [String: Any]
    ) {
        try? transport.send(CodexJSON.data([
            "id": id,
            "error": [
                "code": -32601,
                "message": "Interactive and tool requests are disabled",
            ],
        ]))
        if let turnID = params["turnId"] as? String {
            failTurn(turnID, reason: "Codex requested disabled authority")
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if method == "account/login/completed" {
            let loginID = params["loginId"] as? String
            let success = params["success"] as? Bool == true
            guard let loginID,
                let waiter = loginWaiters.removeValue(forKey: loginID)
            else { return }
            if success { waiter.resume() }
            else { waiter.resume(throwing: ChatFault.refuse(
                code: "no-credentials", reason: "ChatGPT sign-in failed")) }
            return
        }
        let turn = params["turn"] as? [String: Any]
        guard let turnID = (params["turnId"] as? String)
            ?? (turn?["id"] as? String) else { return }
        guard turns[turnID] != nil else {
            if earlyTurnEvents[turnID, default: []].count < 100 {
                earlyTurnEvents[turnID, default: []].append((method, params))
            }
            return
        }
        deliver(method: method, params: params, turnID: turnID)
    }

    private func deliver(
        method: String, params: [String: Any], turnID: String
    ) {
        guard let active = turns[turnID] else { return }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty {
                active.continuation.yield(.textDelta(delta))
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            if turn?["status"] as? String == "completed" {
                active.continuation.yield(.finished(.endTurn))
                active.continuation.finish()
                removeTurn(turnID)
            } else {
                failTurn(turnID, reason: "Codex turn failed")
            }
        case "item/started", "item/completed":
            let item = params["item"] as? [String: Any]
            let type = item?["type"] as? String ?? ""
            let allowed = ["agentMessage", "reasoning", "userMessage"]
            if !type.isEmpty && !allowed.contains(type) {
                failTurn(turnID, reason: "Codex attempted a disabled tool")
                Task { try? await interrupt(
                    threadID: active.threadID, turnID: turnID) }
            }
        default:
            break
        }
    }

    private func beginTurn(
        token: UUID, completion: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-codex-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            guard try await account()?.isChatGPT == true else {
                throw ChatFault.refuse(
                    code: "no-credentials",
                    reason: "Sign in with ChatGPT in Providers")
            }
            let threadData = try await request(method: "thread/start", params: [
                "model": completion.model,
                "cwd": directory.path,
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "baseInstructions": "You are a text-only chat assistant. "
                    + "Never use tools or inspect the local system.",
                "developerInstructions": completion.system,
                "config": [
                    "mcp_servers": [String: Any](),
                    "features": [
                        "shell_tool": false, "apps": false,
                        "browser_use": false, "hooks": false,
                        "multi_agent": false,
                    ],
                ],
            ])
            let thread = try CodexJSON.object(threadData)["thread"]
                as? [String: Any]
            guard let threadID = thread?["id"] as? String else {
                throw ChatFault.refuse(
                    code: "provider-error", reason: "Codex returned no thread")
            }
            let turnData = try await request(method: "turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": Self.prompt(completion)]],
                "approvalPolicy": "never",
                "sandboxPolicy": [
                    "type": "readOnly", "networkAccess": false,
                ],
            ])
            let turn = try CodexJSON.object(turnData)["turn"]
                as? [String: Any]
            guard let turnID = turn?["id"] as? String else {
                throw ChatFault.refuse(
                    code: "provider-error", reason: "Codex returned no turn")
            }
            turns[turnID] = ActiveTurn(
                token: token, threadID: threadID,
                continuation: continuation, workingDirectory: directory)
            turnByToken[token] = turnID
            let early = earlyTurnEvents.removeValue(forKey: turnID) ?? []
            early.forEach { deliver(method: $0.0, params: $0.1,
                                    turnID: turnID) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            continuation.finish(throwing: error)
        }
    }

    private static func prompt(_ completion: ChatCompletionRequest) -> String {
        completion.turns.map { turn in
            let text = turn.content.compactMap { content -> String? in
                switch content {
                case .text(let text): return text
                case .toolResult(_, let text, _, _): return text
                case .toolCall: return nil
                }
            }.joined(separator: "\n")
            return "<\(turn.role.rawValue)>\n\(text)\n</\(turn.role.rawValue)>"
        }.joined(separator: "\n\n")
    }

    private func cancelTurn(token: UUID) {
        guard let turnID = turnByToken[token],
            let active = turns[turnID] else { return }
        active.continuation.finish(throwing: CancellationError())
        removeTurn(turnID)
        Task { try? await interrupt(
            threadID: active.threadID, turnID: turnID) }
    }

    private func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request(method: "turn/interrupt", params: [
            "threadId": threadID, "turnId": turnID,
        ])
    }

    private func failTurn(_ turnID: String, reason: String) {
        guard let active = turns[turnID] else { return }
        active.continuation.finish(throwing: ChatFault.refuse(
            code: "provider-error", reason: reason))
        removeTurn(turnID)
    }

    private func removeTurn(_ turnID: String) {
        guard let active = turns.removeValue(forKey: turnID) else { return }
        turnByToken.removeValue(forKey: active.token)
        try? FileManager.default.removeItem(at: active.workingDirectory)
    }

    private func cancelLogin(_ loginID: String) {
        loginWaiters.removeValue(forKey: loginID)?.resume(
            throwing: CancellationError())
        Task { try? await request(
            method: "account/login/cancel", params: ["loginId": loginID]) }
    }

    private func expireLogin(_ loginID: String) {
        loginWaiters.removeValue(forKey: loginID)?.resume(
            throwing: ChatFault.refuse(
                code: "unreachable", reason: "ChatGPT sign-in timed out"))
    }

    private func cancelRequest(_ id: Int) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func requestTimedOut(_ id: Int) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: ChatFault.refuse(
            code: "unreachable", reason: "Codex app-server timed out"))
        transport.stop()
    }

    private func terminated() {
        initialized = false
        startup = nil
        incomingTask = nil
        let error = ChatFault.refuse(
            code: "unreachable", reason: "Codex app-server stopped")
        let waiters = pending.values
        pending.removeAll()
        waiters.forEach {
            $0.timeout.cancel()
            $0.continuation.resume(throwing: error)
        }
        loginWaiters.values.forEach { $0.resume(throwing: error) }
        loginWaiters.removeAll()
        Array(turns.keys).forEach { failTurn($0, reason: "Codex stopped") }
    }
}
