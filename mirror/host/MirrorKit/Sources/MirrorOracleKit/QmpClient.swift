import Foundation

/// Minimal QMP input driver — the emu-only positional actuation plane.
/// Port of `qmp.py`: the mac99 mouse is RELATIVE-only and OS 9 accel
/// distorts open-loop moves, so precise positioning is closed-loop against
/// the guest's `mouseloc` (the dispatcher owns that loop). QMP-injected
/// events advance from OUTSIDE the guest CPU, which is what lets a drag
/// work while DragWindow/MenuSelect starve the Worker.
public final class QmpClient {
    private let fd: Int32

    public enum QmpError: Error, CustomStringConvertible {
        case connect(String)
        case io(String)
        case protocolError(String)

        public var description: String {
            switch self {
            case .connect(let m): return "qmp connect: \(m)"
            case .io(let m): return "qmp io: \(m)"
            case .protocolError(let m): return "qmp protocol: \(m)"
            }
        }
    }

    public init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw QmpError.connect(String(cString: strerror(errno)))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard ok else {
            close(fd)
            throw QmpError.connect("socket path too long: \(socketPath)")
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw QmpError.connect("\(socketPath): \(msg)")
        }
        _ = try readLine1()                     // greeting {"QMP": ...}
        _ = try command("qmp_capabilities")
    }

    deinit { close(fd) }

    // MARK: - Input events (port of qmp.py rel/button)

    /// Move by (dx,dy) in paced ±step increments — each delta stays below
    /// the guest accel threshold so it maps ~linearly.
    public func rel(dx: Int, dy: Int, step: Int = 3,
                    paceMicros: UInt32 = 3000) throws {
        let sx = dx > 0 ? step : -step
        var moved = 0
        while moved < abs(dx) {
            try send(events: [["type": "rel",
                               "data": ["axis": "x", "value": sx]]])
            if paceMicros > 0 { usleep(paceMicros) }
            moved += step
        }
        let sy = dy > 0 ? step : -step
        moved = 0
        while moved < abs(dy) {
            try send(events: [["type": "rel",
                               "data": ["axis": "y", "value": sy]]])
            if paceMicros > 0 { usleep(paceMicros) }
            moved += step
        }
    }

    public func button(down: Bool) throws {
        try send(events: [["type": "btn",
                           "data": ["button": "left", "down": down]]])
    }

    private func send(events: [[String: Any]]) throws {
        _ = try command("input-send-event", arguments: ["events": events])
    }

    // MARK: - Wire plumbing

    @discardableResult
    public func command(_ execute: String,
                        arguments: [String: Any]? = nil) throws -> [String: Any] {
        var obj: [String: Any] = ["execute": execute]
        if let arguments { obj["arguments"] = arguments }
        let payload = try JSONSerialization.data(withJSONObject: obj)
        try write(payload + Data("\r\n".utf8))
        // Skip async events until a return/error arrives.
        while true {
            let line = try readLine1()
            guard let reply = try? JSONSerialization
                .jsonObject(with: line) as? [String: Any] else { continue }
            if let err = reply["error"] {
                throw QmpError.protocolError("\(execute): \(err)")
            }
            if let ret = reply["return"] {
                return ret as? [String: Any] ?? [:]
            }
        }
    }

    private func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while sent < raw.count {
                let n = Foundation.send(fd, raw.baseAddress! + sent,
                                        raw.count - sent, 0)
                guard n > 0 else {
                    throw QmpError.io("send: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    private var buffer = Data()

    private func readLine1() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { return Data(line) }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else {
                throw QmpError.io(n == 0 ? "qmp closed"
                                  : String(cString: strerror(errno)))
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
