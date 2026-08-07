import Foundation

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

@main
enum NOWAgentCompanionMain {
    static func main() async {
        let server = NOWMCPServer(
            client: SocketAgentIntegrationClient(),
            audit: LocalAuditSink())
        let output = MCPStandardOutput()
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
               nothing. Not one of the forty-one tools, not seven: the
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
            await handle(framer.append(chunk), server: server,
                         output: output)
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
