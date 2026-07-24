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
        let server = NOWMCPServer(healthClient: SocketHealthClient())
        let output = MCPStandardOutput()
        var framer = BoundedMCPLineFramer()

        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
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
