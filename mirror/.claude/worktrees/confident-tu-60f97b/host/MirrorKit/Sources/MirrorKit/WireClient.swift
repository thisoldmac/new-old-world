import Foundation

/// Minimal newline-JSON wire client, mirroring the workshop `Wire.swift`
/// shape: one TCP connection per request — connect, send one envelope line,
/// read one reply line, close. Stateless by construction; the guest serves
/// serially. (Named debt: third Swift wire client — consolidate into a
/// shared wire package at promotion time, MIRRORKIT-PLAN phase 3.)
public final class WireClient {
    public let host: String
    public let port: Int
    /// Per-request wall-clock timeout, seconds.
    public var timeout: Double

    private var nextID = 0

    public init(host: String, port: Int, timeout: Double = 10.0) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    public convenience init(target: MirrorTarget, timeout: Double = 10.0) {
        self.init(host: target.host, port: target.port, timeout: timeout)
    }

    public enum WireError: Error, CustomStringConvertible {
        case connect(String)
        case io(String)
        case timeout
        case badReply(String)
        /// The guest answered `ok:false`; carries its error code/message.
        case guestError(String)

        public var description: String {
            switch self {
            case .connect(let m): return "wire connect: \(m)"
            case .io(let m): return "wire io: \(m)"
            case .timeout: return "wire timeout"
            case .badReply(let m): return "wire bad reply: \(m)"
            case .guestError(let m): return "guest error: \(m)"
            }
        }
    }

    /// One request → the reply's `result` object. Also returns the raw reply
    /// byte count (the scene meta wants it).
    ///
    /// Uses ONE persistent connection reused across requests — the toolkit
    /// worker serves a single connection serially, and opening/closing a
    /// fresh socket per request races the worker's accept and gets refused
    /// under bursts (multiple lists per poll). On any I/O error the
    /// connection is dropped so the next request reconnects.
    @discardableResult
    public func request(_ verb: String,
                        _ args: [String: Any] = [:]) throws -> (result: [String: Any], bytes: Int) {
        nextID += 1
        let id = nextID
        var envelope: [String: Any] = ["proto": 1, "id": id, "verb": verb]
        if !args.isEmpty {
            envelope["args"] = args
        }
        let payload = try JSONSerialization.data(withJSONObject: envelope)

        let replyLine: Data
        do {
            try ensureConnected()
            try writeAll(payload + Data([0x0A]))
            replyLine = try readLine(wantID: id)
        } catch {
            dropConnection()   // force a clean reconnect next time
            throw error
        }

        // The guest speaks MacRoman. Decode the whole line as MacRoman, then
        // re-encode UTF-8 for JSONSerialization: MacRoman is ASCII-compatible
        // for 0x00–0x7F so the JSON structure is untouched, and high bytes
        // (…, ™, curly quotes, é) become their real Unicode instead of the
        // U+FFFD a UTF-8 decode would produce. Fall back to UTF-8 repair if
        // MacRoman decoding somehow fails.
        let text = String(data: replyLine, encoding: .macOSRoman)
            ?? String(decoding: replyLine, as: UTF8.self)
        guard let reply = try? JSONSerialization
            .jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw WireError.badReply(String(text.prefix(200)))
        }
        guard (reply["ok"] as? NSNumber)?.boolValue == true else {
            let err = reply["error"].map { "\($0)" } ?? "ok:false with no error"
            throw WireError.guestError(err)
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        return (result, replyLine.count)
    }

    /// Close the persistent connection (e.g. before a co-driving human
    /// attaches, or to force a reconnect).
    public func disconnect() { dropConnection() }

    // MARK: - Persistent connection

    private var fd: Int32 = -1
    private var rbuf = Data()

    private func ensureConnected() throws {
        if fd >= 0 { return }
        fd = try connectSocket()
        rbuf.removeAll(keepingCapacity: true)
    }

    private func dropConnection() {
        if fd >= 0 { close(fd); fd = -1 }
        rbuf.removeAll(keepingCapacity: true)
    }

    deinit { dropConnection() }

    private func writeAll(_ payload: Data) throws {
        var sent = 0
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while sent < raw.count {
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 {
                    throw errno == EWOULDBLOCK || errno == EAGAIN
                        ? WireError.timeout
                        : WireError.io("send: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    /// Read one newline-terminated reply whose `id` matches; a stale reply
    /// from a prior timed-out call is discarded. Leftover bytes past the
    /// newline stay buffered for the next read.
    private func readLine(wantID: Int) throws -> Data {
        while true {
            if let nl = rbuf.firstIndex(of: 0x0A) {
                let line = Data(rbuf[rbuf.startIndex..<nl])
                rbuf.removeSubrange(rbuf.startIndex...nl)
                if line.isEmpty { continue }
                // Match the id; skip a stale reply and read on.
                if let obj = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                   let rid = (obj["id"] as? NSNumber)?.intValue, rid != wantID {
                    continue
                }
                return line
            }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 {
                throw errno == EWOULDBLOCK || errno == EAGAIN
                    ? WireError.timeout
                    : WireError.io("recv: \(String(cString: strerror(errno)))")
            }
            if n == 0 {
                throw WireError.io("connection closed before reply")
            }
            rbuf.append(contentsOf: buf[0..<n])
        }
    }

    private func connectSocket() throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET,
                             ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil,
                             ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0,
              let first = info else {
            throw WireError.connect("cannot resolve \(host):\(port)")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype,
                        first.pointee.ai_protocol)
        guard fd >= 0 else {
            throw WireError.connect("socket: \(String(cString: strerror(errno)))")
        }
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw WireError.connect("\(host):\(port): \(msg)")
        }
        return fd
    }
}
