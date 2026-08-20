import Darwin
import Foundation
import NOWAgentIntegration

struct ChatSubprocessRequest: Sendable {
    let executable: URL
    let arguments: [String]
    let standardInput: Data?
    let timeout: TimeInterval
    let environment: [String: String]
    let workingDirectory: URL?
}

enum ChatSubprocessError: Error, Equatable {
    case launchFailed
    case timedOut
    case outputTooLarge
    case exited(Int32)
}

protocol ChatSubprocessRunning: Sendable {
    func stdoutLines(_ request: ChatSubprocessRequest)
        -> AsyncThrowingStream<String, Error>
}

enum ChatSubprocessEnvironment {
    private static let exactKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM",
        "CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME",
        /* Carried on purpose, and the one entry here that is not about
           the runtime's own configuration. A workspace lane spawns
           `New Old World --mcp-stdio` UNDERNEATH the runtime, and that
           companion finds its host by this suffix. Stripped, a host on
           its own endpoint would hand the lane a companion that reached
           the DEFAULT socket — another session's host, and whatever
           Macintosh that one is driving, with neither side able to tell.

           By the CONSTANT, never by the string: `AgentEndpointIsolation
           Tests` requires the spelling to exist in exactly one file, and
           it is right to — the rule it protects is that a host and its
           companion cannot disagree about where the socket is. This is
           the second PROCESS agreeing, not a second reader. */
        AgentIntegrationEndpoint.suffixEnvironmentKey,
    ]

    /// Child runtimes need their own config and Keychain identity, not every
    /// secret the host happened to inherit. API-key variables are deliberately
    /// absent so a subscription card cannot silently become usage-based API.
    static func minimal(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = source.filter { key, _ in
            exactKeys.contains(key) || key.hasPrefix("LC_")
        }
        var paths = (result["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for path in ChatRuntimeLocator.fallbackPaths(home: result["HOME"])
            where !paths.contains(path) {
            paths.append(path)
        }
        result["PATH"] = paths.joined(separator: ":")
        return result
    }
}

enum ChatRuntimeLocator {
    static func fallbackPaths(home: String?) -> [String] {
        var paths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        if let home, !home.isEmpty {
            paths.append(URL(fileURLWithPath: home)
                .appendingPathComponent(".local/bin").path)
        }
        return paths
    }

    static func executable(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        paths.append(contentsOf: fallbackPaths(home: environment["HOME"]))
        let manager = FileManager.default
        for path in paths where !path.isEmpty {
            let candidate = URL(fileURLWithPath: path)
                .appendingPathComponent(name)
            if manager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

final class SystemChatSubprocessRunner: ChatSubprocessRunning,
    @unchecked Sendable {
    func stdoutLines(_ request: ChatSubprocessRequest)
        -> AsyncThrowingStream<String, Error> {
        let invocation = ChatProcessInvocation(request: request)
        return AsyncThrowingStream { continuation in
            invocation.start(continuation)
            continuation.onTermination = { _ in invocation.cancel() }
        }
    }
}

private final class ChatProcessInvocation: @unchecked Sendable {
    private static let lineLimit = 1_048_576
    private static let outputLimit = 8_388_608

    private let request: ChatSubprocessRequest
    private let lock = NSLock()
    private let stdoutQueue = DispatchQueue(
        label: "dev.newoldworld.now.chat-subprocess.stdout")
    private var process: Process?
    private var stdoutBuffer = Data()
    private var outputBytes = 0
    private var settled = false
    private var timedOut = false
    private var timeoutTask: Task<Void, Never>?
    private var continuation:
        AsyncThrowingStream<String, Error>.Continuation?

    init(request: ChatSubprocessRequest) {
        self.request = request
    }

    func start(
        _ continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        lock.withLock { self.continuation = continuation }
        Task.detached { [weak self] in self?.launch() }
    }

    private func launch() {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        if let input = request.standardInput {
            let stdin = Pipe()
            process.standardInput = stdin
            stdin.fileHandleForWriting.writeabilityHandler = { handle in
                handle.write(input)
                try? handle.close()
                handle.writeabilityHandler = nil
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readAvailableStdout(handle)
        }
        // Drain diagnostics to prevent child backpressure, but never retain or
        // log provider payloads.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.finishStdout(
                stdout.fileHandleForReading,
                status: process.terminationStatus)
        }

        lock.withLock { self.process = process }
        do {
            try process.run()
        } catch {
            settle(throwing: ChatSubprocessError.launchFailed)
            return
        }
        let nanoseconds = UInt64(max(0.1, request.timeout) * 1_000_000_000)
        timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.timeout()
        }
    }

    private func receiveStdout(_ data: Data) {
        var lines: [String] = []
        var overflow = false
        lock.withLock {
            guard !settled else { return }
            outputBytes += data.count
            stdoutBuffer.append(data)
            if outputBytes > Self.outputLimit
                || stdoutBuffer.count > Self.lineLimit {
                overflow = true
                return
            }
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer[..<newline]
                stdoutBuffer.removeSubrange(...newline)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.last == "\r" { line.removeLast() }
                lines.append(line)
            }
        }
        if overflow {
            settle(throwing: ChatSubprocessError.outputTooLarge)
            cancelProcess()
        } else {
            let current = lock.withLock { continuation }
            lines.forEach { current?.yield($0) }
        }
    }

    private func readAvailableStdout(_ handle: FileHandle) {
        stdoutQueue.sync {
            let data = handle.availableData
            if !data.isEmpty { receiveStdout(data) }
        }
    }

    private func finishStdout(_ handle: FileHandle, status: Int32) {
        stdoutQueue.sync {
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty { receiveStdout(remaining) }
            terminated(status: status)
        }
    }

    private func terminated(status: Int32) {
        let finalLine: String? = lock.withLock {
            guard !settled, !stdoutBuffer.isEmpty else { return nil }
            defer { stdoutBuffer.removeAll() }
            return String(decoding: stdoutBuffer, as: UTF8.self)
        }
        if let finalLine { lock.withLock { continuation }?.yield(finalLine) }
        if lock.withLock({ timedOut }) {
            settle(throwing: ChatSubprocessError.timedOut)
        } else if status == 0 {
            settle()
        } else {
            settle(throwing: ChatSubprocessError.exited(status))
        }
    }

    private func timeout() {
        lock.withLock { timedOut = true }
        cancelProcess()
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let process = self?.lock.withLock({ self?.process }),
                process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func cancel() {
        cancelProcess()
        settle(throwing: CancellationError())
    }

    private func cancelProcess() {
        let running = lock.withLock { process }
        if running?.isRunning == true { running?.terminate() }
    }

    private func settle(throwing error: Error? = nil) {
        let target: AsyncThrowingStream<String, Error>.Continuation? =
            lock.withLock {
                guard !settled else { return nil }
                settled = true
                timeoutTask?.cancel()
                return continuation
            }
        guard let target else { return }
        if let error { target.finish(throwing: error) }
        else { target.finish() }
    }
}
