import XCTest
@testable import MirrorKit

/// The wire's recovery from a desynchronised stream.
///
/// Measured 2026-08-02 against a live guest: after a window close, the
/// window filled with `wire bad reply` and never recovered. Two halves of
/// one defect. `readLine` skipped a STALE reply by id, but a line that did
/// not PARSE fell past that check and was returned as though it were the
/// answer; the caller then threw `badReply` without dropping the socket,
/// so every later request read the next fragment of the same confusion.
/// One split line poisoned the session for good.
///
/// These drive a real socket rather than a mock, because the defect lived
/// in the framing between two sockets and a mock of the framing would have
/// agreed with the bug.
final class WireResyncTests: XCTestCase {

    /// A server that writes canned bytes at a client, then serves normally.
    private final class Peer {
        let port: UInt16
        private let listener: FileHandle
        private var thread: Thread?

        init(script: @escaping @Sendable (Int32) -> Void) throws {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            var bound = addr
            let ok = withUnsafePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0,
                                socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(ok, 0, "bind")
            _ = Darwin.listen(fd, 4)
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = getsockname(fd, $0, &len)
                }
            }
            port = actual.sin_port.bigEndian == 0
                ? UInt16(bigEndian: actual.sin_port) : actual.sin_port.bigEndian
            listener = FileHandle(fileDescriptor: fd)
            let t = Thread {
                while true {
                    let c = accept(fd, nil, nil)
                    if c < 0 { return }
                    script(c)
                    close(c)
                }
            }
            t.start()
            thread = t
        }

        deinit { listener.closeFile() }
    }

    private static func send(_ fd: Int32, _ s: String) {
        _ = s.withCString { write(fd, $0, strlen($0)) }
    }

    private static func readRequest(_ fd: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    /// A line that cannot be parsed is stepped over, not mistaken for the
    /// answer — so ONE malformed line costs nothing at all.
    func testAnUnparseableLineIsSteppedOverRatherThanAnswered() throws {
        let peer = try Peer { fd in
            _ = Self.readRequest(fd)
            Self.send(fd, "{\"ok\":true,\"id\":1,\"resu\n")     // split JSON
            Self.send(fd, "{\"ok\":true,\"id\":1,\"result\":{\"v\":7}}\n")
        }
        let client = WireClient(host: "127.0.0.1", port: Int(peer.port))
        let (result, _) = try client.request("ping")
        XCTAssertEqual(result["v"] as? Int, 7,
                       "the real reply follows the garbage and must be found")
    }

    /// And when the garbage never ends, the request fails rather than
    /// spinning — a peer emitting only noise is a failure, not a wait.
    func testEndlessGarbageFailsRatherThanSpinning() throws {
        let peer = try Peer { fd in
            _ = Self.readRequest(fd)
            for _ in 0..<40 { Self.send(fd, "not json at all\n") }
        }
        let client = WireClient(host: "127.0.0.1", port: Int(peer.port))
        XCTAssertThrowsError(try client.request("ping")) { error in
            guard case WireClient.WireError.badReply = error else {
                return XCTFail("expected badReply, got \(error)")
            }
        }
    }
}
