import Foundation
import Network
@testable import Host
@testable import NOWAgentIntegration

/// **A real MCP client, and the classification of what every tool answers
/// it.**
///
/// This file is the client and the recipe book; `MCPClientConformanceTests`
/// is the gate that runs it. They are split because the same run has two
/// audiences — a CI gate that asserts nothing timed out, and a person
/// reading the served/refused/failed table off a live machine — and one of
/// those wants to print.
///
/// The harness speaks through NOW's shipping loopback listener rather than
/// calling `NOWMCPServer.handle(_:)`, so HTTP framing, authentication,
/// sessions, and dispatch all remain inside the gate.
enum MCPConformance {}

// MARK: - The client

protocol MCPConformanceClient: AnyObject {
    func request(_ method: String, params: [String: Any]?,
                 timeout: TimeInterval) throws -> [String: Any]
    func notify(_ method: String, params: [String: Any]?)
    func handshake() throws -> [String: Any]
    func advertisedTools() throws -> [[String: Any]]
    func shutDown()
}

extension MCPConformanceClient {
    func request(_ method: String,
                 params: [String: Any]? = nil) throws -> [String: Any] {
        try request(method, params: params, timeout: 30)
    }

    func notify(_ method: String, params: [String: Any]? = nil) {
        notify(method, params: params)
    }
}

/// A client session over the real loopback HTTP listener.
///
/// It owns NOW's real loopback listener, a TCP port, HTTP authentication, and
/// an MCP session. The listener is in process because that is the shipping
/// ownership boundary; spawning a second HTTP product here would preserve the
/// component split this gate now exists to prevent.
final class MCPHTTPClient: MCPConformanceClient, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }

    private let listener: MCPHTTPListener
    private let endpoint: URL
    private let token: String
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 0

    private final class StartErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func store(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func load() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    init(environment _: [String: String]? = nil) throws {
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bearerToken = token
        let serverFactory: MCPHTTPService.ServerFactory = {
            (NOWMCPServer(
                client: HTTPConformanceNoHostClient(),
                audit: LocalMCPAuditSink()),
             NOWMCPClientIdentity())
        }
        /* A random high port collides on a shared CI runner often enough to
           matter (EADDRINUSE, 2026-08-20). The port must be known before the
           listener exists — it is baked into the endpoint URL and the
           configuration — so bind-and-retry with a fresh draw is the fix,
           not port 0. */
        var attempt = 0
        while true {
            attempt += 1
            let port = UInt16.random(in: 40_000...60_000)
            let candidate = try MCPHTTPListener(
                configuration: .init(port: port, bearerToken: bearerToken),
                serverFactory: serverFactory)
            do {
                try Self.startAndAwaitBind(candidate)
            } catch let error as NWError
                where error == .posix(.EADDRINUSE) && attempt < 5 {
                candidate.stop()
                continue
            }
            listener = candidate
            endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
            return
        }
    }

    private static func startAndAwaitBind(_ listener: MCPHTTPListener) throws {
        let ready = DispatchSemaphore(value: 0)
        let startError = StartErrorBox()
        Task {
            do { try await listener.start() }
            catch { startError.store(error) }
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw Failure(detail: "NOW's HTTP listener did not bind in 5s")
        }
        if let error = startError.load() { throw error }
    }

    deinit { shutDown() }

    func shutDown() {
        if let sessionID, let protocolVersion {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            authorize(&request, session: sessionID,
                      protocolVersion: protocolVersion)
            _ = try? exchange(request, timeout: 2)
        }
        listener.stop()
    }

    func request(_ method: String, params: [String: Any]? = nil,
                 timeout: TimeInterval = 30) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
        ]
        if let params { object["params"] = params }
        let response = try post(object, timeout: timeout,
                                retryConnection: method == "initialize")
        guard response.status == 200,
              let reply = try JSONSerialization.jsonObject(with: response.data)
                as? [String: Any] else {
            throw Failure(detail: "HTTP \(response.status) for \(method)")
        }
        if method == "initialize",
           let result = reply["result"] as? [String: Any],
           let version = result["protocolVersion"] as? String {
            guard let session = response.headers["mcp-session-id"] else {
                throw Failure(detail: "initialize returned no MCP session")
            }
            sessionID = session
            protocolVersion = version
        }
        return reply
    }

    func notify(_ method: String, params: [String: Any]? = nil) {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        _ = try? post(object, timeout: 5, retryConnection: false)
    }

    @discardableResult
    func handshake() throws -> [String: Any] {
        let reply = try request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "now-conformance", "version": "1"],
        ])
        notify("notifications/initialized")
        return reply
    }

    func advertisedTools() throws -> [[String: Any]] {
        let reply = try request("tools/list")
        guard let result = reply["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw Failure(detail: "tools/list returned no catalog")
        }
        return tools
    }

    private struct Exchange {
        let data: Data
        let status: Int
        let headers: [String: String]
    }

    private final class ExchangeOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Exchange, Error>?

        func store(_ result: Result<Exchange, Error>) {
            lock.lock()
            defer { lock.unlock() }
            value = result
        }

        func load() -> Result<Exchange, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func post(_ object: [String: Any], timeout: TimeInterval,
                      retryConnection: Bool) throws -> Exchange {
        let body = try JSONSerialization.data(withJSONObject: object)
        let attempts = retryConnection ? 25 : 1
        var last: Error?
        for attempt in 0..<attempts {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json",
                             forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream",
                             forHTTPHeaderField: "Accept")
            authorize(&request, session: sessionID,
                      protocolVersion: protocolVersion)
            do { return try exchange(request, timeout: timeout) }
            catch {
                last = error
                if attempt + 1 < attempts { usleep(100_000) }
            }
        }
        throw last ?? Failure(detail: "HTTP connection failed")
    }

    private func authorize(_ request: inout URLRequest, session: String?,
                           protocolVersion: String?) {
        request.setValue("Bearer \(token)",
                         forHTTPHeaderField: "Authorization")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            request.setValue(protocolVersion,
                             forHTTPHeaderField: "Mcp-Protocol-Version")
        }
    }

    private func exchange(_ request: URLRequest,
                          timeout: TimeInterval) throws -> Exchange {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ExchangeOutcome()
        let task = URLSession.shared.dataTask(with: request) {
            data, response, error in
            defer { semaphore.signal() }
            if let error { outcome.store(.failure(error)); return }
            guard let response = response as? HTTPURLResponse else {
                outcome.store(.failure(Failure(detail: "non-HTTP response")))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key).lowercased()]
                    = String(describing: value)
            }
            outcome.store(.success(.init(data: data ?? Data(),
                                         status: response.statusCode,
                                         headers: headers)))
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw Failure(detail: "HTTP request timed out in \(timeout)s")
        }
        return try outcome.load()?.get()
            ?? { throw Failure(detail: "HTTP request produced no outcome") }()
    }

}

/// The HTTP-only gate's deterministic in-process product boundary. It says
/// exactly what a running host adapter says when it has no connected guest,
/// without proving HTTP by crossing the stdio companion's Unix socket.
struct HTTPConformanceNoHostClient: AgentIntegrationClient {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .hostUnavailable
    }
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult { .unavailable(.host) }
    func listProcesses() async -> AgentIntegrationProcessListResult {
        .guestUnavailable
    }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult { .unavailable(.host) }
    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult { .unavailable(.host) }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult { .unavailable(.host) }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }
}

// MARK: - Classification

extension MCPConformance {

    /// What one tool did when a client called it.
    ///
    /// Five cases and not three. `humanGated` keeps a deliberate authority
    /// boundary distinct from `uncovered`, which remains a coverage finding.
    /// this surface cannot construct a legal argument for is a **finding**,
    /// and folding it into "refused" would hide it behind a pass.
    enum Verdict: String {
        /// A result whose outcome is the tool's own success.
        case served
        /// The machine, the guest or this host said no, and said why.
        case refused
        /// No answer, an unparseable one, or an answer that contradicts a
        /// healthy host.
        case failed
        /// A person must mint the authority needed to call this row.
        case humanGated = "human-gated"
        /// The tool answered correctly that a precondition this surface
        /// cannot mint is absent. Not a refusal on the merits and not a
        /// coverage gap: the capability is reachable, and the lane it
        /// needs is one only a configured host has.
        case expectedUnavailable = "expected-unavailable"
        /// No legal argument exists on this surface. Named, never skipped.
        case uncovered
    }

    /// Where a row's arguments came from, because it changes what a
    /// refusal means.
    enum ArgumentKind: String {
        /// Constructed from this run's own earlier answers, or needing none.
        case real
        /// Syntactically valid, deliberately never minted — so the guest's
        /// revalidation is what answers. Exercises the tool; does not prove
        /// the capability.
        case synthetic
        /// The recipe could not be built at all.
        case none
    }

    struct Row {
        let tool: String
        let verdict: Verdict
        let argumentKind: ArgumentKind
        /// The tool's own sentence, or this driver's reason for `failed`.
        let detail: String
        let elapsed: TimeInterval
    }

    /// Structural preconditions a headless conformance run cannot satisfy,
    /// and the flag that says whether this run satisfied each anyway.
    ///
    /// The same shape as `live`: a code is the honest answer when its
    /// precondition is absent and a FALSE one when it is present, so the
    /// verdict turns on the run's own configuration rather than on the
    /// sentence. `now_guest_files_upload_file` reads bytes out of the chat
    /// workspace lane, whose root is pinned on the companion's command
    /// line at spawn (`--workspace-root`) or in-process before an HTTP
    /// lane turn. This driver spawns without one, so the row's no-lane
    /// answer is correct and scoring it `refused` overstated what the
    /// surface had been asked.
    static let workspacePreconditionCode = "now-files-workspace-unavailable"

    /// Reads one `tools/call` reply and says which of the four it is.
    ///
    /// `live` is the one thing that changes the verdict rather than the
    /// prose: with a host running, `now-host-unavailable` is a false answer
    /// from a healthy machine and is a failure. With no host it is the
    /// honest one.
    static func classify(_ reply: [String: Any],
                         live: Bool,
                         workspacePinned: Bool) -> (Verdict, String) {
        if let error = reply["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            let message = (error["message"] as? String) ?? ""
            switch code {
            case -32602 where message == "Unknown tool":
                return (.failed, "the surface advertises a tool its "
                        + "dispatch does not claim")
            case -32602:
                /* The recipe was rejected, which is a defect in this file
                   rather than in the surface — and it must not read as a
                   refusal, or a driver that sends nonsense would score a
                   clean sheet. */
                return (.failed, "invalid arguments: \(message)")
            case -32601, -32603, -32700, -32600:
                return (.failed, "protocol error \(code): \(message)")
            default:
                // A consent denial has its own code and its own reason.
                return (.refused, "denied (\(code)): \(message)")
            }
        }
        guard let result = reply["result"] as? [String: Any] else {
            return (.failed, "a reply that is neither result nor error")
        }
        guard let structured =
            result["structuredContent"] as? [String: Any] else {
            return (.failed, "a result with no structuredContent")
        }
        return classify(structured: structured, live: live,
                        workspacePinned: workspacePinned)
    }

    /// The projected envelope, and the four families that do not use it.
    ///
    /// It reads the shapes rather than a table of tool names on purpose:
    /// a new capability answering in an existing shape is classified
    /// correctly by a file that has never heard of it.
    static func classify(structured: [String: Any],
                         live: Bool,
                         workspacePinned: Bool) -> (Verdict, String) {
        if let outcome = structured["outcome"] as? String {
            let payload = structured[outcome] as? [String: Any]
            /* `unavailable` is the one outcome name every family spells the
               same, because they all carry the same type for it. */
            if outcome == "unavailable" {
                let code = (payload?["code"] as? String) ?? ""
                if live, code == "now-host-unavailable" {
                    return (.failed, "answered now-host-unavailable while "
                            + "a host was running")
                }
                if code == workspacePreconditionCode {
                    if workspacePinned {
                        return (.failed, "answered "
                                + "\(workspacePreconditionCode) while a "
                                + "workspace root was pinned")
                    }
                    let (_, detail) = refusal(payload, kind: "unavailable")
                    return (.expectedUnavailable, detail)
                }
                return refusal(payload, kind: "unavailable")
            }
            /* **The shape decides, not the word.** Every family names its
               own outcomes — `completed`, `captured`, `requestSent`,
               `abandoned`, `stale`, `notFound` — and a driver holding a
               list of those words would classify a new capability by not
               recognising it. A refusal is a payload that is a code and a
               sentence; anything else that carries a payload at all is an
               answer.

               The payload is not always under the outcome's own name: the
               capture family answers `{"outcome":"captured","capture":{…}}`.
               So a refusal is looked for under the outcome name, where the
               families that have one put it, and everything else is judged
               on whether the reply said anything besides its verdict. */
            if let payload, payload["code"] is String,
               payload["message"] is String {
                return refusal(payload, kind: outcome)
            }
            guard structured.keys.contains(where: { $0 != "outcome" }) else {
                return (.failed, "outcome \(outcome) and nothing else — a "
                        + "verdict with no answer beside it")
            }
            return (.served, outcome)
        }
        /* **`showing` is `available` spelled a fourth way**, and this is a
           driver reading a drift rather than a driver learning a shape.

           `AgentIntegrationMirrorOpenResult` says availability with
           `showing: Bool` beside the same `unavailable` payload every
           envelope below carries — semantically identical to `available`,
           and the fourth spelling of one question on this surface after
           `available`, `hostAvailable` and `ok`. It was found by the round-3
           integration merge, because `now_semantic_ui_start` (018-open-mirror) and
           this driver (019-conformance) had never met: the driver read it as
           "a structured result in no shape this driver can read", which is
           the correct verdict about a surface with four names for one thing.

           Taught here rather than renamed, because renaming a shipped MCP
           result field is a surface change and not an integration's to make.
           **The consolidation is the finding**; see docs/open-issues.md. */
        if let showing = structured["showing"] as? Bool {
            if showing { return (.served, "showing") }
            return refusal(structured["unavailable"] as? [String: Any],
                           kind: "unavailable")
        }
        /* `now_list_machines` and the guest Files family keep their own
           envelopes; both say availability with a boolean beside a reason. */
        if let available = structured["available"] as? Bool {
            if available { return (.served, "available") }
            let failure = structured["unavailable"] as? [String: Any]
            let code = (failure?["code"] as? String) ?? ""
            if live, code == "now-host-unavailable" {
                return (.failed, "answered now-host-unavailable while a "
                        + "host was running")
            }
            return refusal(failure, kind: "unavailable")
        }
        /* The guest Files family's own envelope, which says availability
           and outcome in two separate places: `hostAvailable` is about this
           machine, and the receipt's `outcome` is about the other one. A
           driver that read only the first would score every not-found as a
           success. */
        if let hostAvailable = structured["hostAvailable"] as? Bool {
            guard hostAvailable else {
                let failure = structured["unavailable"] as? [String: Any]
                let code = (failure?["code"] as? String) ?? ""
                if live, code == "now-host-unavailable" {
                    return (.failed, "answered now-host-unavailable while a "
                            + "host was running")
                }
                return refusal(failure, kind: "unavailable")
            }
            let receipt = structured["receipt"] as? [String: Any]
            let outcome = (receipt?["outcome"] as? String) ?? ""
            if outcome == "success" { return (.served, "success") }
            return refusal(structured["failure"] as? [String: Any],
                           kind: "receipt \(outcome)")
        }
        if let ok = structured["ok"] as? Bool {
            if ok { return (.served, "ok") }
            let failure = (structured["error"] as? [String: Any])
                ?? (structured["failure"] as? [String: Any])
            return refusal(failure, kind: "not ok")
        }
        return (.failed,
                "a structured result in no shape this driver can read: "
                    + summary(of: structured))
    }

    /// A refusal is a pass **only if it says why**. A refusal with an empty
    /// reason is the shape this whole exercise exists to catch: an answer
    /// that looks handled and tells a caller nothing.
    private static func refusal(_ failure: [String: Any]?,
                                kind: String) -> (Verdict, String) {
        let code = (failure?["code"] as? String) ?? ""
        let message = (failure?["message"] as? String) ?? ""
        guard !message.isEmpty else {
            return (.failed, "\(kind) with no reason given")
        }
        return (.refused, "\(kind) \(code.isEmpty ? "" : "(\(code)) ")"
                + message)
    }

    private static func summary(of object: [String: Any]) -> String {
        object.keys.sorted().prefix(6).joined(separator: ", ")
    }
}
