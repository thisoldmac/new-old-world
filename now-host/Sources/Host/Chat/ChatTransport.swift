import Foundation

/* The harness's one seam to the network. There is no URLProtocol
   stubbing anywhere in this tree — services are faked at protocol
   seams (the CloudProvider precedent), and this is the chat family's:
   providers take a transport, tests hand them a scripted one. */

protocol ChatHTTPTransport: Sendable {
    /// One request, whole response. Throws on transport failure;
    /// returns whatever status the server gave.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// One request, response body delivered line by line (newline
    /// stripped). The stream ends when the body does; cancelling the
    /// consuming task cancels the connection.
    func streamLines(_ request: URLRequest) async throws
        -> (lines: AsyncThrowingStream<String, Error>, response: HTTPURLResponse)
}

struct URLSessionChatTransport: ChatHTTPTransport {
    /// Ephemeral so provider traffic shares no cookie or cache state
    /// with anything else; generous read timeout because a model that
    /// thinks for a minute between tokens is healthy, not stuck.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: config)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatFault.refuse(code: "unreachable", reason: "not an HTTP response")
        }
        return (data, http)
    }

    func streamLines(_ request: URLRequest) async throws
        -> (lines: AsyncThrowingStream<String, Error>, response: HTTPURLResponse) {
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatFault.refuse(code: "unreachable", reason: "not an HTTP response")
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

/// One server-sent event, as dispatched at a blank line.
struct ServerSentEvent: Equatable {
    var event: String?
    var data: String
}

/// Pure SSE line accumulator: feed lines, collect events. Handles
/// multi-line `data:`, comment/heartbeat lines, trailing CR, and the
/// blank-line dispatch rule. Knows nothing about any provider —
/// OpenAI's `[DONE]` sentinel is data like any other and is the
/// caller's business.
struct ServerSentEventParser {
    private var event: String?
    private var dataLines: [String] = []

    /// Feed one line (newline already stripped); returns a completed
    /// event when this line dispatched one.
    mutating func feed(_ rawLine: String) -> ServerSentEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            guard !dataLines.isEmpty || event != nil else { return nil }
            let out = ServerSentEvent(
                event: event, data: dataLines.joined(separator: "\n"))
            event = nil
            dataLines = []
            return out
        }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break  // id, retry, unknown fields: not our business
        }
        return nil
    }
}
