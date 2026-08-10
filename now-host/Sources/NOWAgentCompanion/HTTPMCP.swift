import Foundation
import Network

enum CompanionInvocation: Equatable {
    static let tokenEnvironmentKey = "NOW_MCP_HTTP_BEARER_TOKEN"
    static let portEnvironmentKey = "NOW_MCP_HTTP_PORT"
    static let defaultHTTPPort: UInt16 = 5254

    case stdio
    case http(MCPHTTPConfiguration)
    case invalid(String)

    static func parse(arguments: [String], environment: [String: String])
        -> CompanionInvocation {
        guard !arguments.isEmpty else { return .stdio }
        guard arguments.first == "--http" else {
            return .invalid("usage: NOWAgentCompanion [--http [--port N]]")
        }
        var port = environment[portEnvironmentKey]
            .flatMap(UInt16.init) ?? defaultHTTPPort
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--port", index + 1 < arguments.count,
                  let parsed = UInt16(arguments[index + 1]), parsed != 0 else {
                return .invalid(
                    "usage: NOWAgentCompanion [--http [--port N]]")
            }
            port = parsed
            index += 2
        }
        guard let token = environment[tokenEnvironmentKey],
              (32...512).contains(token.utf8.count) else {
            return .invalid(
                "--http requires \(tokenEnvironmentKey) with 32-512 UTF-8 bytes")
        }
        return .http(.init(port: port, bearerToken: token))
    }
}

struct MCPHTTPConfiguration: Equatable {
    let port: UInt16
    let bearerToken: String
    let maximumHeaderBytes: Int
    let maximumSessions: Int
    let sessionLifetime: TimeInterval

    init(port: UInt16, bearerToken: String,
         maximumHeaderBytes: Int = 16 * 1024,
         maximumSessions: Int = 8,
         sessionLifetime: TimeInterval = 30 * 60) {
        self.port = port
        self.bearerToken = bearerToken
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumSessions = maximumSessions
        self.sessionLifetime = sessionLifetime
    }
}

struct MCPHTTPRequest: Equatable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

enum MCPHTTPRequestParseError: Error, Equatable {
    case malformed
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding
}

/// One bounded HTTP/1.1 request. The listener closes every connection after
/// its response, so pipelining and chunked bodies are deliberately not part of
/// this local transport. Streamable HTTP does not require either one.
struct BoundedMCPHTTPRequestParser {
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

struct MCPHTTPResponse: Equatable {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()

    var wireData: Data {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 202: phrase = "Accepted"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 403: phrase = "Forbidden"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 406: phrase = "Not Acceptable"
        case 413: phrase = "Content Too Large"
        case 415: phrase = "Unsupported Media Type"
        case 429: phrase = "Too Many Requests"
        default: phrase = "Internal Server Error"
        }
        var fields = headers
        fields["Content-Length"] = "\(body.count)"
        fields["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(phrase)\r\n"
        for key in fields.keys.sorted() {
            head += "\(key): \(fields[key]!)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

actor MCPHTTPService {
    typealias ServerFactory = @Sendable () -> NOWMCPServer

    private struct Session {
        let server: NOWMCPServer
        let protocolVersion: String
        var lastUsed: Date
    }

    private let configuration: MCPHTTPConfiguration
    private let serverFactory: ServerFactory
    private var sessions: [String: Session] = [:]

    init(configuration: MCPHTTPConfiguration,
         serverFactory: @escaping ServerFactory = {
             NOWMCPServer(client: SocketAgentIntegrationClient(),
                          audit: LocalAuditSink())
         }) {
        self.configuration = configuration
        self.serverFactory = serverFactory
    }

    func respond(to request: MCPHTTPRequest, now: Date = Date()) async
        -> MCPHTTPResponse {
        guard request.target == "/mcp" else { return response(404) }
        guard validHost(request.headers["host"]) else { return response(400) }
        if let origin = request.headers["origin"], !validOrigin(origin) {
            return response(403)
        }
        guard validAuthorization(request.headers["authorization"]) else {
            return response(401, headers: ["WWW-Authenticate": "Bearer"])
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
            return jsonResponse(await serverFactory().handle(request.body))
        }

        if method == "initialize" {
            guard request.headers["mcp-session-id"] == nil else {
                return response(400)
            }
            guard sessions.count < configuration.maximumSessions else {
                return response(429, headers: ["Retry-After": "30"])
            }
            let server = serverFactory()
            guard let reply = await server.handle(request.body) else {
                return response(202)
            }
            guard let version = Self.protocolVersion(in: reply) else {
                return jsonResponse(reply)
            }
            let id = UUID().uuidString.lowercased()
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

    private func validHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(configuration.port)"
            || host == "localhost:\(configuration.port)"
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
        guard let value, value.hasPrefix("Bearer ") else { return false }
        return Self.constantTimeEqual(
            String(value.dropFirst("Bearer ".count)),
            configuration.bearerToken)
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

final class MCPHTTPListener: @unchecked Sendable {
    private let configuration: MCPHTTPConfiguration
    private let service: MCPHTTPService
    private let queue = DispatchQueue(label: "dev.newoldworld.mcp-http")
    private var listener: NWListener?
    private var didStart = false

    init(configuration: MCPHTTPConfiguration) throws {
        self.configuration = configuration
        service = MCPHTTPService(configuration: configuration)
    }

    func run() async throws {
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
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready where !didStart:
                    didStart = true
                    FileHandle.standardError.write(Data(
                        "NOW MCP HTTP listening at http://127.0.0.1:\(self.configuration.port)/mcp\n".utf8))
                case .failed(let error):
                    if !didStart { continuation.resume(throwing: error) }
                    listener.cancel()
                case .cancelled:
                    if didStart { continuation.resume() }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
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
    private var parser: BoundedMCPHTTPRequestParser
    private var finished = false
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
                FileHandle.standardError.write(Data(
                    "NOW MCP HTTP connection failed: \(error)\n".utf8))
                return
            }
            do {
                if let data, let request = try self.parser.append(data) {
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
        finished = true
        connection.send(content: response.wireData,
                        completion: .contentProcessed { [self, connection] _ in
                            connection.cancel()
                            keepAlive = nil
                        })
    }
}
