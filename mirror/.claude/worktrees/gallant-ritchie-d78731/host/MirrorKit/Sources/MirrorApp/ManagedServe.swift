import Foundation

/// The Host-managed lifecycle plane for the mirror service.
///
/// The 0.7 `HostServiceCatalog` supervises a managed service over a fixed
/// loopback TCP endpoint using the same HTTP handshake as the Python services
/// (`HostServiceHTTPTransport` / `HostServicePrivateHTTP`):
///
///   * `GET  /.well-known/timbottu/readiness` → 200 with the
///     `X-TBT-Readiness-Identity` header and a canonical
///     `{"readinessIdentity": "<id>"}` body.
///   * `POST /.well-known/timbottu/quit`      → 202, then the process exits so
///     the coordinator's cooperative stop proves child + endpoint release.
///
/// This is deliberately a *separate* plane from the unix method socket: agents
/// reach the fifteen `mirror.*` methods over the socket via `mirror_call`; only
/// the supervisor speaks this TCP handshake. The readiness identity is the one
/// the supervisor injected as `TBT_HOST_SERVICE_READINESS_IDENTITY`; a probe
/// carrying a different identity still gets our identity back (the coordinator,
/// not the child, decides ownership).
final class ManagedReadinessListener {
    private let identity: String
    private let port: UInt16
    private static let readinessPath = "/.well-known/timbottu/readiness"
    private static let quitPath = "/.well-known/timbottu/quit"

    init(identity: String, port: UInt16) {
        self.identity = identity
        self.port = port
    }

    func start() {
        let thread = Thread { [self] in serve() }
        thread.name = "mirror.serve.readiness"
        thread.start()
    }

    private func serve() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data(
                "mirror managed readiness: socket failed\n".utf8))
            return
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            FileHandle.standardError.write(Data((
                "mirror managed readiness: bind/listen 127.0.0.1:\(port) "
                + "failed: \(String(cString: strerror(errno)))\n").utf8))
            close(fd)
            return
        }
        FileHandle.standardOutput.write(Data(
            "mirror managed readiness: 127.0.0.1:\(port)\n".utf8))
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        // Read the request head (up to the blank line). Bodies are small and
        // we do not need them: readiness/quit dispatch on the request line.
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while request.range(of: terminator) == nil {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            request.append(contentsOf: buffer[0..<n])
            if request.count > 65_536 { break }
        }
        let head = String(decoding: request, as: UTF8.self)
        let requestLine = head.split(
            separator: "\r\n", maxSplits: 1,
            omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let fields = requestLine.split(separator: " ")
        let method = fields.count > 0 ? String(fields[0]) : ""
        let path = fields.count > 1 ? String(fields[1]) : ""

        if method == "GET" && path == Self.readinessPath {
            let body = "{\"readinessIdentity\":\"\(identity)\"}"
            write(client, response(
                status: "200 OK",
                headers: [
                    "X-TBT-Readiness-Identity": identity,
                    "Content-Type": "application/json",
                ],
                body: body))
        } else if method == "POST" && path == Self.quitPath {
            let body = "{\"readinessIdentity\":\"\(identity)\"}"
            write(client, response(
                status: "202 Accepted",
                headers: ["X-TBT-Readiness-Identity": identity,
                          "Content-Type": "application/json"],
                body: body))
            // Cooperative stop: the coordinator has asked us to quit; flush the
            // response, then exit so it can prove child + endpoint release.
            FileHandle.standardOutput.write(Data(
                "mirror managed readiness: cooperative quit\n".utf8))
            exit(0)
        } else {
            write(client, response(
                status: "404 Not Found", headers: [:], body: ""))
        }
    }

    private func response(
        status: String, headers: [String: String], body: String
    ) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.utf8.count)\r\n"
        text += "Connection: close\r\n\r\n"
        text += body
        return Data(text.utf8)
    }

    private func write(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = Darwin.write(client, base + offset, data.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
