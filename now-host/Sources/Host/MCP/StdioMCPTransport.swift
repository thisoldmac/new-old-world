import Foundation
import NOWAgentIntegration

enum MCPInputEvent {
    case message(Data)
    case oversized
}

struct BoundedMCPLineFramer {
    private var pending = Data()
    private var droppingOversizedLine = false

    mutating func append(_ chunk: Data) -> [MCPInputEvent] {
        var events: [MCPInputEvent] = []
        for byte in chunk {
            if byte == 0x0A {
                if droppingOversizedLine {
                    events.append(.oversized)
                } else if !pending.isEmpty {
                    events.append(.message(pending))
                }
                pending.removeAll(keepingCapacity: true)
                droppingOversizedLine = false
            } else if !droppingOversizedLine {
                pending.append(byte)
                if pending.count > NOWMCPServer.maximumMessageBytes {
                    pending.removeAll(keepingCapacity: true)
                    droppingOversizedLine = true
                }
            }
        }
        return events
    }

    mutating func finish() -> [MCPInputEvent] {
        defer {
            pending.removeAll()
            droppingOversizedLine = false
        }
        if droppingOversizedLine { return [.oversized] }
        return pending.isEmpty ? [] : [.message(pending)]
    }
}

struct MCPStandardOutput {
    func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}

/// Identity of the executable this stdio companion started from.
///
/// The app is replaced in place during development while an MCP client keeps
/// this process alive. The running image then refers to the unlinked vnode,
/// while `Bundle.main.executableURL` names the newly installed build. Without
/// this check an old companion decodes a new host with an old local contract
/// and reports the actionable build split as `now-host-invalid-response`.
struct MCPExecutableGeneration {
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: TimeInterval
    }

    private let path: String
    private let startedAs: Identity

    init?(executableURL: URL? = Bundle.main.executableURL) {
        guard let executableURL,
              let identity = Self.identity(at: executableURL.path) else {
            return nil
        }
        path = executableURL.path
        startedAs = identity
    }

    var isCurrent: Bool {
        Self.identity(at: path) == startedAs
    }

    private static func identity(at path: String) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Identity(
            device: device.uint64Value,
            inode: inode.uint64Value,
            size: size.uint64Value,
            modified: modified.timeIntervalSinceReferenceDate)
    }
}

enum MCPStaleCompanionResponse {
    static func make(for request: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: request)
                as? [String: Any],
              let id = object["id"] else {
            return nil
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32001,
                "message": "The NOW MCP companion belongs to a replaced app build and is restarting. Retry this call.",
                "data": [
                    "code": "now-mcp-companion-stale",
                    "reach": "notSent",
                ],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: response,
                                           options: [.sortedKeys])
    }
}

/// The client-launched MCP mode of the New Old World executable.
///
/// This is deliberately not another product or server. An MCP client starts
/// the same binary with `--mcp-stdio`; this narrow process frames standard
/// input and reaches the already-running NOW app through its same-UID local
/// endpoint. Tool ownership, consent, audit and guest state remain in NOW.
enum MCPStdioTransport {
    static func run(workspaceRoot: URL? = nil) async {
        let identity = NOWMCPClientIdentity()
        let server = NOWMCPServer(
            client: SocketAgentIntegrationClient(),
            audit: LocalMCPAuditSink(identity: identity),
            identity: identity,
            workspaceGrant: workspaceRoot.map(HostWorkspaceGrant.init))
        let output = MCPStandardOutput()
        let executableGeneration = MCPExecutableGeneration()
        var framer = BoundedMCPLineFramer()

        while true {
            /* `availableData`, and NOT `readData(ofLength: 4096)`.
               Found 2026-08-07 while driving the seven revived tools, and
               it is the larger half of what that drive found.

               On Darwin `readData(ofLength:)` LOOPS until it has the full
               count or the descriptor ends. An MCP client holds stdio open
               for the life of the session and sends one small line at a
               time, so this loop sat on a 76-byte `initialize` waiting for
               4020 more bytes that were never coming — and answered
               nothing. Not one registry tool, not a sampled handful: the
               whole surface, to every client that behaves the way the
               transport says clients behave.

               It survived because everything that ever drove this binary
               wrote its whole script and CLOSED stdin, which is what makes
               the blocking read return. A pipeline that closes the pipe is
               not a client; it is a batch, and the surface passed for
               months on batches alone. Measured directly: one small line
               with stdin held open gets no reply in ten seconds, and
               padding the same line to exactly 4096 bytes gets one
               immediately.

               `availableData` returns whatever has arrived, blocking only
               until there IS something, and returns empty at EOF — which
               is the loop's own exit condition, unchanged. */
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            let events = framer.append(chunk)
            if executableGeneration?.isCurrent == false {
                /* The request is deliberately NOT sent to the host. Exit
                   after a typed reply so the MCP supervisor starts the
                   binary now present at the same stable app path. One retry
                   then runs both halves from that build. */
                for event in events {
                    guard case .message(let request) = event else { continue }
                    if let response = MCPStaleCompanionResponse.make(
                        for: request) {
                        output.write(response)
                    }
                    break
                }
                return
            }
            await handle(events, server: server, output: output)
        }
        await handle(framer.finish(), server: server, output: output)
    }

    private static func handle(
        _ events: [MCPInputEvent],
        server: NOWMCPServer,
        output: MCPStandardOutput
    ) async {
        for event in events {
            let response: Data?
            switch event {
            case .message(let data):
                response = await server.handle(data)
            case .oversized:
                response = await server.oversizedMessageResponse()
            }
            if let response {
                output.write(response)
            }
        }
    }
}
