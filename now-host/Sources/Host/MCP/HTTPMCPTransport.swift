import Foundation
import Network
import NOWAgentIntegration

/// How the HTTP transport decides whether a request may speak MCP. The
/// loopback Host and Origin checks apply in every mode; this only selects
/// what the Authorization header must carry. stdio is uid-authenticated by
/// the kernel and has no mode.
enum MCPHTTPAuthMode: String, CaseIterable, Sendable {
    case unauthenticated = "none"
    case bearer
    case oauth
}

struct MCPHTTPConfiguration: Equatable {
    let port: UInt16
    let authMode: MCPHTTPAuthMode
    let bearerToken: String?
    let maximumHeaderBytes: Int
    let maximumSessions: Int
    let sessionLifetime: TimeInterval

    init(port: UInt16, authMode: MCPHTTPAuthMode, bearerToken: String?,
         maximumHeaderBytes: Int = 16 * 1024,
         maximumSessions: Int = 8,
         sessionLifetime: TimeInterval = 30 * 60) {
        self.port = port
        self.authMode = authMode
        self.bearerToken = bearerToken
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumSessions = maximumSessions
        self.sessionLifetime = sessionLifetime
    }

    /// Bearer-mode shorthand; existing call sites and tests predate modes.
    init(port: UInt16, bearerToken: String,
         maximumHeaderBytes: Int = 16 * 1024,
         maximumSessions: Int = 8,
         sessionLifetime: TimeInterval = 30 * 60) {
        self.init(port: port, authMode: .bearer, bearerToken: bearerToken,
                  maximumHeaderBytes: maximumHeaderBytes,
                  maximumSessions: maximumSessions,
                  sessionLifetime: sessionLifetime)
    }
}

struct BoundedHTTPRequest: Equatable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

/// Compatibility spelling for MCP callers while the socket now serves both
/// the public API and MCP route adapters.
typealias MCPHTTPRequest = BoundedHTTPRequest

enum MCPHTTPRequestParseError: Error, Equatable {
    case malformed
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding
}

/// One bounded HTTP/1.1 request. The listener closes every connection after
/// its response, so pipelining and chunked bodies are deliberately not part of
/// this local transport. Streamable HTTP does not require either one.
struct BoundedHTTPRequestParser {
    private var pending = Data()
    private var expectedBodyBytes: Int?
    private var parsedHead: (method: String, target: String,
                             headers: [String: String])?
    private let maximumHeaderBytes: Int

    init(maximumHeaderBytes: Int = 16 * 1024) {
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    mutating func append(_ data: Data) throws -> MCPHTTPRequest? {
        pending.append(data)
        if parsedHead == nil {
            guard let divider = pending.range(of: Data("\r\n\r\n".utf8)) else {
                if pending.count > maximumHeaderBytes {
                    throw MCPHTTPRequestParseError.headersTooLarge
                }
                return nil
            }
            guard divider.lowerBound <= maximumHeaderBytes else {
                throw MCPHTTPRequestParseError.headersTooLarge
            }
            let headerData = pending[..<divider.lowerBound]
            let bodyStart = divider.upperBound
            guard let head = String(data: headerData, encoding: .utf8) else {
                throw MCPHTTPRequestParseError.malformed
            }
            parsedHead = try Self.parseHead(head)
            if parsedHead?.headers["transfer-encoding"] != nil {
                throw MCPHTTPRequestParseError.unsupportedTransferEncoding
            }
            let length: Int
            if let rawLength = parsedHead?.headers["content-length"] {
                guard let parsed = Int(rawLength), parsed >= 0 else {
                    throw MCPHTTPRequestParseError.malformed
                }
                length = parsed
            } else if parsedHead?.method == "POST" {
                throw MCPHTTPRequestParseError.malformed
            } else {
                length = 0
            }
            guard length <= NOWMCPServer.maximumMessageBytes else {
                throw MCPHTTPRequestParseError.bodyTooLarge
            }
            expectedBodyBytes = length
            pending.removeSubrange(..<bodyStart)
        }
        guard let length = expectedBodyBytes else { return nil }
        if pending.count > length {
            throw MCPHTTPRequestParseError.malformed
        }
        guard pending.count == length, let head = parsedHead else { return nil }
        return .init(method: head.method, target: head.target,
                     headers: head.headers, body: pending)
    }

    private static func parseHead(_ text: String) throws
        -> (method: String, target: String, headers: [String: String]) {
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw MCPHTTPRequestParseError.malformed }
        let request = lines.removeFirst().split(separator: " ",
                                                omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1",
              !request[0].isEmpty, !request[1].isEmpty else {
            throw MCPHTTPRequestParseError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                throw MCPHTTPRequestParseError.malformed
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil,
                  name.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0)
                          || $0 == "-"
                  }) else {
                throw MCPHTTPRequestParseError.malformed
            }
            headers[name] = value
        }
        return (String(request[0]), String(request[1]), headers)
    }
}

typealias BoundedMCPHTTPRequestParser = BoundedHTTPRequestParser

/// A response body that remains open. `next` has at most one outstanding
/// consumer, and the connection requests another piece only after the prior
/// network write completes.
protocol MCPHTTPStreamingBody: AnyObject, Sendable {
    func next(_ completion: @escaping @Sendable (Data?) -> Void)
    func cancel()
}

struct MCPHTTPResponse: Equatable {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// A private, already-settled file response. The connection writer reads
    /// this in bounded pieces; API downloads never become one giant `Data`.
    var bodyFileURL: URL? = nil
    var bodyFileLength: Int? = nil
    var streamingBody: (any MCPHTTPStreamingBody)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.headers == rhs.headers
            && lhs.body == rhs.body && lhs.bodyFileURL == rhs.bodyFileURL
            && lhs.bodyFileLength == rhs.bodyFileLength
            && (lhs.streamingBody != nil) == (rhs.streamingBody != nil)
    }

    var wireHeadData: Data {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 201: phrase = "Created"
        case 202: phrase = "Accepted"
        case 302: phrase = "Found"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 403: phrase = "Forbidden"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 406: phrase = "Not Acceptable"
        case 409: phrase = "Conflict"
        case 413: phrase = "Content Too Large"
        case 415: phrase = "Unsupported Media Type"
        case 428: phrase = "Precondition Required"
        case 429: phrase = "Too Many Requests"
        case 503: phrase = "Service Unavailable"
        default: phrase = "Internal Server Error"
        }
        var fields = headers
        if streamingBody == nil {
            fields["Content-Length"] = "\(bodyFileLength ?? body.count)"
            fields["Connection"] = "close"
        } else {
            fields["Connection"] = "keep-alive"
            fields["Transfer-Encoding"] = "chunked"
        }
        var head = "HTTP/1.1 \(status) \(phrase)\r\n"
        for key in fields.keys.sorted() {
            head += "\(key): \(fields[key]!)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    var wireData: Data {
        wireHeadData + body
    }
}

actor MCPHTTPService {
    /// One server AND its identity box per session: the server fills the
    /// box at initialize, the service adds the session id it mints, and the
    /// audit sink the factory built beside them reads it at record time.
    typealias ServerFactory = @Sendable ()
        -> (server: NOWMCPServer, identity: NOWMCPClientIdentity)
    typealias ActivityObserver = @Sendable (_ began: Bool, _ at: Date) -> Void

    private struct Session {
        let server: NOWMCPServer
        let protocolVersion: String
        var lastUsed: Date
    }

    private let configuration: MCPHTTPConfiguration
    private let serverFactory: ServerFactory
    private let activityObserver: ActivityObserver?
    private let oauth: MCPOAuthAuthority?
    private let apiRouter: NOWAPIHTTPRouter?
    private var sessions: [String: Session] = [:]

    init(configuration: MCPHTTPConfiguration,
         serverFactory: @escaping ServerFactory,
         activityObserver: ActivityObserver? = nil,
         oauth: MCPOAuthAuthority? = nil,
         apiRouter: NOWAPIHTTPRouter? = nil) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.activityObserver = activityObserver
        self.oauth = oauth
        self.apiRouter = apiRouter
    }

    func respond(to request: MCPHTTPRequest, now: Date = Date()) async
        -> MCPHTTPResponse {
        if request.target == "/api/v1"
            || request.target.hasPrefix("/api/v1/") {
            guard let host = validatedHost(request.headers["host"]) else {
                return response(400)
            }
            _ = host
            if let origin = request.headers["origin"], !validOrigin(origin) {
                return response(403)
            }
            guard let apiRouter else { return response(404) }
            return await apiRouter.respond(to: request)
        }
        /* /mcp is matched on the whole target: it never carries a query.
           Only the oauth routes split path from query. */
        if request.target != "/mcp" {
            if configuration.authMode == .oauth, let oauth {
                return await oauthRoute(request, authority: oauth, now: now)
            }
            return response(404)
        }
        guard let host = validatedHost(request.headers["host"]) else {
            return response(400)
        }
        if let origin = request.headers["origin"], !validOrigin(origin) {
            return response(403)
        }
        switch configuration.authMode {
        case .unauthenticated:
            break
        case .bearer:
            guard validAuthorization(request.headers["authorization"]) else {
                return response(401,
                                headers: ["WWW-Authenticate": "Bearer"])
            }
        case .oauth:
            let challenge = "Bearer resource_metadata=\"http://\(host)"
                + "/.well-known/oauth-protected-resource/mcp\""
            guard let value = request.headers["authorization"],
                  value.hasPrefix("Bearer "), let oauth,
                  await oauth.validateAccessToken(
                    String(value.dropFirst("Bearer ".count)), now: now)
            else {
                return response(401,
                                headers: ["WWW-Authenticate": challenge])
            }
        }
        expireSessions(at: now)

        switch request.method {
        case "GET":
            return response(405, headers: ["Allow": "POST, DELETE"])
        case "DELETE":
            guard let id = request.headers["mcp-session-id"],
                  let session = sessions[id],
                  request.headers["mcp-protocol-version"]
                    == session.protocolVersion else {
                return response(404)
            }
            sessions[id] = nil
            return response(200)
        case "POST":
            return await post(request, now: now)
        default:
            return response(405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func post(_ request: MCPHTTPRequest, now: Date) async
        -> MCPHTTPResponse {
        guard request.headers["content-type"]?.lowercased()
                .split(separator: ";", maxSplits: 1).first
                .map(String.init) == "application/json" else {
            return response(415)
        }
        let accepted = Set((request.headers["accept"] ?? "")
            .lowercased().split(separator: ",")
            .map { $0.split(separator: ";", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces) })
        guard accepted.contains("application/json"),
              accepted.contains("text/event-stream") else {
            return response(406)
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
              let method = object["method"] as? String else {
            return jsonResponse(
                await serverFactory().server.handle(request.body))
        }
        let observesAgentCall = method == "tools/call"
        if observesAgentCall { activityObserver?(true, now) }
        defer {
            if observesAgentCall { activityObserver?(false, Date()) }
        }

        if method == "initialize" {
            guard request.headers["mcp-session-id"] == nil else {
                return response(400)
            }
            guard sessions.count < configuration.maximumSessions else {
                return response(429, headers: ["Retry-After": "30"])
            }
            let (server, identity) = serverFactory()
            guard let reply = await server.handle(request.body) else {
                return response(202)
            }
            guard let version = Self.protocolVersion(in: reply) else {
                return jsonResponse(reply)
            }
            let id = UUID().uuidString.lowercased()
            identity.setSessionKey(id)
            sessions[id] = .init(server: server, protocolVersion: version,
                                 lastUsed: now)
            return jsonResponse(reply, headers: ["Mcp-Session-Id": id])
        }

        guard let id = request.headers["mcp-session-id"],
              var session = sessions[id] else { return response(404) }
        guard request.headers["mcp-protocol-version"]
                == session.protocolVersion else { return response(400) }
        session.lastUsed = now
        sessions[id] = session
        guard let reply = await session.server.handle(request.body) else {
            return response(202)
        }
        return jsonResponse(reply)
    }

    /// The authorization-server half of oauth mode: metadata, registration,
    /// consent-gated authorization, and the token endpoint. All still behind
    /// the loopback Host check; these routes exist only while the mode is
    /// oauth.
    private func oauthRoute(_ request: MCPHTTPRequest,
                            authority: MCPOAuthAuthority,
                            now: Date) async -> MCPHTTPResponse {
        guard let host = validatedHost(request.headers["host"]) else {
            return response(400)
        }
        if let origin = request.headers["origin"], !validOrigin(origin) {
            return response(403)
        }
        let (path, query) = Self.splitTarget(request.target)
        switch (request.method, path) {
        case ("GET", "/.well-known/oauth-protected-resource"),
             ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return jsonResponse(
                MCPOAuthAuthority.protectedResourceMetadata(host: host))
        case ("GET", "/.well-known/oauth-authorization-server"):
            return jsonResponse(
                MCPOAuthAuthority.authorizationServerMetadata(host: host))
        case ("POST", "/oauth/register"):
            guard jsonContentType(request) else { return response(415) }
            return tokenOutcomeResponse(
                await authority.register(body: request.body, now: now),
                status: 201)
        case ("GET", "/oauth/authorize"):
            switch await authority.authorize(query: query, now: now) {
            case .redirect(let location):
                return .init(status: 302,
                             headers: ["Location": location,
                                       "Cache-Control": "no-store"])
            case .invalidRequest(let sentence):
                return response(400,
                                headers: ["Content-Type":
                                            "text/plain; charset=utf-8"],
                                body: Data(sentence.utf8))
            }
        case ("POST", "/oauth/token"):
            guard request.headers["content-type"]?.lowercased()
                .split(separator: ";", maxSplits: 1).first
                .map(String.init) == "application/x-www-form-urlencoded"
            else { return response(415) }
            return tokenOutcomeResponse(
                await authority.token(
                    form: MCPOAuthAuthority.parseForm(request.body),
                    now: now),
                status: 200)
        default:
            return response(404)
        }
    }

    private func tokenOutcomeResponse(
        _ outcome: MCPOAuthAuthority.TokenOutcome,
        status: Int) -> MCPHTTPResponse {
        switch outcome {
        case .issued(let body):
            return .init(status: status,
                         headers: ["Content-Type": "application/json",
                                   "Cache-Control": "no-store"],
                         body: body)
        case .rejected(let status, let error, let detail):
            let body = (try? JSONSerialization.data(
                withJSONObject: ["error": error,
                                 "error_description": detail],
                options: [.sortedKeys])) ?? Data()
            return .init(status: status,
                         headers: ["Content-Type": "application/json",
                                   "Cache-Control": "no-store"],
                         body: body)
        }
    }

    private func jsonContentType(_ request: MCPHTTPRequest) -> Bool {
        request.headers["content-type"]?.lowercased()
            .split(separator: ";", maxSplits: 1).first
            .map(String.init) == "application/json"
    }

    private static func splitTarget(_ target: String)
        -> (path: String, query: [String: String]) {
        guard let divider = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<divider])
        let raw = String(target[target.index(after: divider)...])
        return (path, MCPOAuthAuthority.parseForm(Data(raw.utf8)))
    }

    private static func protocolVersion(in data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        let result = object?["result"] as? [String: Any]
        return result?["protocolVersion"] as? String
    }

    private func expireSessions(at now: Date) {
        sessions = sessions.filter {
            now.timeIntervalSince($0.value.lastUsed)
                <= configuration.sessionLifetime
        }
    }

    /// The lowercased Host header when it names this loopback listener, so
    /// OAuth metadata can echo whichever spelling the client used.
    private func validatedHost(_ host: String?) -> String? {
        guard let host = host?.lowercased(),
              host == "127.0.0.1:\(configuration.port)"
                || host == "localhost:\(configuration.port)" else {
            return nil
        }
        return host
    }

    private func validOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              components.port == Int(configuration.port),
              components.path.isEmpty,
              components.query == nil, components.fragment == nil else {
            return false
        }
        let host = components.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    private func validAuthorization(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("Bearer "),
              let token = configuration.bearerToken else { return false }
        return Self.constantTimeEqual(
            String(value.dropFirst("Bearer ".count)), token)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }

    private func jsonResponse(_ body: Data?,
                              headers: [String: String] = [:])
        -> MCPHTTPResponse {
        guard let body else { return response(202) }
        return response(200,
                        headers: headers.merging(
                            ["Content-Type": "application/json"],
                            uniquingKeysWith: { first, _ in first }),
                        body: body)
    }

    private func response(_ status: Int,
                          headers: [String: String] = [:],
                          body: Data = Data()) -> MCPHTTPResponse {
        .init(status: status, headers: headers, body: body)
    }
}

private final class MCPHTTPStartSettlement: @unchecked Sendable {
    /// Accessed only by one NWListener's serial callback queue. The wrapper
    /// makes that ownership explicit to Swift's Sendable checker.
    var isSettled = false
}

final class MCPHTTPListener: @unchecked Sendable {
    typealias FailureObserver = @Sendable (Error) -> Void

    private let configuration: MCPHTTPConfiguration
    private let service: MCPHTTPService
    private let failureObserver: FailureObserver?
    private let queue = DispatchQueue(label: "dev.newoldworld.mcp-http")
    private var listener: NWListener?

    init(configuration: MCPHTTPConfiguration,
         serverFactory: @escaping MCPHTTPService.ServerFactory,
         activityObserver: MCPHTTPService.ActivityObserver? = nil,
         failureObserver: FailureObserver? = nil,
         oauth: MCPOAuthAuthority? = nil,
         apiRouter: NOWAPIHTTPRouter? = nil) throws {
        self.configuration = configuration
        self.failureObserver = failureObserver
        service = MCPHTTPService(configuration: configuration,
                                 serverFactory: serverFactory,
                                 activityObserver: activityObserver,
                                 oauth: oauth,
                                 apiRouter: apiRouter)
    }

    /// Start the in-process listener and return when the port is bound.
    /// The listener remains owned by this object until `stop()`.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: configuration.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            /* All state callbacks arrive on `queue`, so this flag owns the
               continuation without a lock. A Stop pressed while bind is in
               flight settles start as cancellation instead of leaving its
               task suspended forever. */
            let settlement = MCPHTTPStartSettlement()
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready where !settlement.isSettled:
                    settlement.isSettled = true
                    continuation.resume()
                case .failed(let error):
                    if !settlement.isSettled {
                        settlement.isSettled = true
                        continuation.resume(throwing: error)
                    } else {
                        /* A port can fail after it was ready. The owner must
                           stop presenting a green Running state. */
                        failureObserver?(error)
                    }
                    listener.cancel()
                case .cancelled where !settlement.isSettled:
                    settlement.isSettled = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let active = listener
        listener = nil
        queue.async { active?.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let exchange = MCPHTTPConnection(
            connection: connection, service: service,
            maximumHeaderBytes: configuration.maximumHeaderBytes,
            queue: queue)
        exchange.start()
    }
}

private final class MCPHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let service: MCPHTTPService
    private let queue: DispatchQueue
    private var parser: BoundedHTTPRequestParser
    private var finished = false
    private var peerClosed = false
    private var activeStream: (any MCPHTTPStreamingBody)?
    /// `NWListener` does not retain the object that installed the receive
    /// callback. Keep this exchange alive until its one response is sent;
    /// without this ownership the accepted TCP connection remains open but
    /// nobody parses it, which looks exactly like a wedged MCP server.
    private var keepAlive: MCPHTTPConnection?

    init(connection: NWConnection, service: MCPHTTPService,
         maximumHeaderBytes: Int, queue: DispatchQueue) {
        self.connection = connection
        self.service = service
        self.queue = queue
        parser = .init(maximumHeaderBytes: maximumHeaderBytes)
    }

    func start() {
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.activeStream?.cancel()
                self?.activeStream = nil
                self?.keepAlive = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finish(.init(status: 400))
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let error {
                self.connection.cancel()
                self.finished = true
                self.keepAlive = nil
                let detail = "HTTP connection failed: \(error)"
                Task { @MainActor in
                    HostLog.shared.write(.warn, "mcp", detail,
                                         transport: .http)
                }
                return
            }
            do {
                if let data, let request = try self.parser.append(data) {
                    self.monitorPeerClose()
                    Task {
                        let response = await self.service.respond(to: request)
                        self.queue.async { self.finish(response) }
                    }
                    return
                }
            } catch MCPHTTPRequestParseError.headersTooLarge {
                self.finish(.init(status: 413))
                return
            } catch MCPHTTPRequestParseError.bodyTooLarge {
                self.finish(.init(status: 413))
                return
            } catch {
                self.finish(.init(status: 400))
                return
            }
            if complete {
                self.finish(.init(status: 400))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ response: MCPHTTPResponse) {
        guard !finished else { return }
        guard !peerClosed else {
            response.streamingBody?.cancel()
            keepAlive = nil
            return
        }
        finished = true
        if let stream = response.streamingBody {
            activeStream = stream
            connection.send(content: response.wireHeadData,
                            completion: .contentProcessed {
                [weak self] error in
                guard let self, error == nil else {
                    stream.cancel()
                    self?.connection.cancel()
                    self?.keepAlive = nil
                    return
                }
                self.sendStream(stream)
            })
            return
        }
        if let fileURL = response.bodyFileURL,
           let fileLength = response.bodyFileLength {
            connection.send(content: response.wireHeadData,
                            completion: .contentProcessed {
                [weak self] error in
                guard let self, error == nil,
                      let handle = try? FileHandle(forReadingFrom: fileURL)
                else {
                    self?.connection.cancel()
                    self?.keepAlive = nil
                    return
                }
                self.sendFile(handle, remaining: fileLength)
            })
            return
        }
        connection.send(content: response.wireData,
                        completion: .contentProcessed { [self, connection] _ in
                            connection.cancel()
                            keepAlive = nil
                        })
    }

    /// The request parser is one-shot, but a live response must still learn
    /// when its client closes. A concurrent one-byte receive is only a close
    /// witness: request pipelining is unsupported, so any further input also
    /// terminates this exchange.
    private func monitorPeerClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self] _, _, _, _ in
            guard let self else { return }
            self.peerClosed = true
            self.activeStream?.cancel()
            self.activeStream = nil
            self.connection.cancel()
            self.keepAlive = nil
        }
    }

    private func sendStream(_ stream: any MCPHTTPStreamingBody) {
        stream.next { [weak self] piece in
            guard let self else { stream.cancel(); return }
            self.queue.async { [self] in
                guard let piece else {
                    stream.cancel()
                    self.activeStream = nil
                    self.connection.send(
                        content: Data("0\r\n\r\n".utf8), isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            self?.connection.cancel()
                            self?.keepAlive = nil
                        })
                    return
                }
                let header = Data(String(piece.count, radix: 16).utf8)
                let chunk = header + Data("\r\n".utf8) + piece
                    + Data("\r\n".utf8)
                self.connection.send(content: chunk,
                                     completion: .contentProcessed {
                    [weak self] error in
                    guard let self, error == nil else {
                        stream.cancel()
                        self?.activeStream = nil
                        self?.connection.cancel()
                        self?.keepAlive = nil
                        return
                    }
                    self.sendStream(stream)
                })
            }
        }
    }

    /// One file-backed response, read and sent in bounded pieces. Network's
    /// completion callback supplies the backpressure: the next piece is not
    /// read until the previous one has been consumed.
    private func sendFile(_ handle: FileHandle, remaining: Int) {
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, isComplete: true,
                            completion: .contentProcessed {
                [weak self] _ in
                self?.connection.cancel()
                self?.keepAlive = nil
            })
            return
        }
        let piece: Data
        do {
            piece = try handle.read(upToCount: min(64 * 1024, remaining))
                ?? Data()
        } catch {
            try? handle.close()
            connection.cancel()
            keepAlive = nil
            return
        }
        guard !piece.isEmpty else {
            try? handle.close()
            connection.send(content: nil, isComplete: true,
                            completion: .contentProcessed {
                [weak self] _ in
                self?.connection.cancel()
                self?.keepAlive = nil
            })
            return
        }
        connection.send(content: piece, completion: .contentProcessed {
            [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                self?.connection.cancel()
                self?.keepAlive = nil
                return
            }
            self.sendFile(handle, remaining: remaining - piece.count)
        })
    }
}
