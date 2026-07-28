import Darwin
import Foundation

public struct AgentIntegrationEndpoint: Equatable, Sendable {
    public let directoryURL: URL
    public let socketURL: URL

    public init(directoryURL: URL, socketURL: URL) {
        self.directoryURL = directoryURL
        self.socketURL = socketURL
    }

    public static func currentUser(uid: uid_t = geteuid()) throws
        -> AgentIntegrationEndpoint {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dev.newoldworld.now-agent-\(uid)",
                isDirectory: true)
        let endpoint = AgentIntegrationEndpoint(
            directoryURL: directory,
            socketURL: directory.appendingPathComponent("host.sock"))
        try AgentIntegrationUnixSocket.validatePathLength(
            endpoint.socketURL.path)
        return endpoint
    }
}

enum AgentIntegrationUnixSocket {
    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ioError("socket") }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0
        else {
            close(descriptor)
            throw ioError("setsockopt")
        }
        return descriptor
    }

    static func withAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        try validatePathLength(path)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(
            of: \.sun_path)!
        withUnsafeMutableBytes(of: &address) { destination in
            for (index, byte) in bytes.enumerated() {
                destination[pathOffset + index] = UInt8(bitPattern: byte)
            }
        }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func validatePathLength(_ path: String) throws {
        let maximum = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count + 1 <= maximum else {
            throw AgentIntegrationLocalTransportError.unsafeEndpoint(
                "Local socket path is too long")
        }
    }

    static func writeLine(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= AgentIntegrationLocalProtocol.maximumMessageBytes
        else {
            throw AgentIntegrationLocalTransportError.messageTooLarge
        }
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    buffer.count - written)
                guard result > 0 else { throw ioError("write") }
                written += result
            }
        }
    }

    static func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                guard !data.isEmpty else { throw ioError("read") }
                return data
            }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
            guard data.count <=
                    AgentIntegrationLocalProtocol.maximumMessageBytes else {
                throw AgentIntegrationLocalTransportError.messageTooLarge
            }
        }
    }

    static func setTimeouts(_ descriptor: Int32, seconds: TimeInterval = 2) {
        let wholeSeconds = floor(seconds)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((seconds - wholeSeconds) * 1_000_000))
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
                socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, $0,
                socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func validateDirectory(_ url: URL, uid: uid_t) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT {
                throw AgentIntegrationLocalTransportError.hostUnavailable
            }
            throw ioError("lstat")
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == uid,
              status.st_mode & 0o077 == 0 else {
            throw AgentIntegrationLocalTransportError.unsafeEndpoint(
                "Local socket directory is not private to this user")
        }
    }

    static func validateSocket(_ url: URL, uid: uid_t) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT {
                throw AgentIntegrationLocalTransportError.hostUnavailable
            }
            throw ioError("lstat")
        }
        guard status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == uid,
              status.st_mode & 0o077 == 0 else {
            throw AgentIntegrationLocalTransportError.unsafeEndpoint(
                "Local host endpoint is not a private user socket")
        }
    }

    static func ioError(_ operation: String)
        -> AgentIntegrationLocalTransportError {
        .io("\(operation) failed: \(String(cString: strerror(errno)))")
    }
}

private func ioError(_ operation: String)
    -> AgentIntegrationLocalTransportError {
    AgentIntegrationUnixSocket.ioError(operation)
}
