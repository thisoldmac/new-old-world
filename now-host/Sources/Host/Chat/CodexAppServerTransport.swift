import Foundation

protocol CodexAppServerTransport: Sendable {
    func start(
        receive: @escaping @Sendable (String) -> Void,
        terminated: @escaping @Sendable () -> Void
    ) throws
    func send(_ data: Data) throws
    func stop()
}

final class SystemCodexAppServerTransport: CodexAppServerTransport,
    @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL?
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var receive: (@Sendable (String) -> Void)?

    init(
        executable: URL? = ChatRuntimeLocator.executable(named: "codex"),
        environment: [String: String] = ChatSubprocessEnvironment.minimal()
    ) {
        self.executable = executable
        self.environment = environment
    }

    func start(
        receive: @escaping @Sendable (String) -> Void,
        terminated: @escaping @Sendable () -> Void
    ) throws {
        guard let executable else {
            throw ChatFault.refuse(
                code: "unreachable", reason: "Codex CLI is not installed")
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = Self.arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in terminated() }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.received(data) }
        }
        // Diagnostics may contain account and prompt material. Drain them so
        // the child cannot block, but never retain or log them.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        lock.withLock {
            self.process = process
            self.input = stdin.fileHandleForWriting
            self.receive = receive
        }
        do {
            try process.run()
        } catch {
            lock.withLock {
                self.process = nil
                self.input = nil
            }
            throw ChatFault.refuse(
                code: "unreachable", reason: "Codex app-server could not start")
        }
    }

    func send(_ data: Data) throws {
        guard let handle = lock.withLock({ input }) else {
            throw ChatFault.refuse(
                code: "unreachable", reason: "Codex app-server is not running")
        }
        var line = data
        line.append(0x0A)
        do { try handle.write(contentsOf: line) }
        catch {
            throw ChatFault.refuse(
                code: "unreachable", reason: "Codex app-server stopped")
        }
    }

    func stop() {
        let process = lock.withLock { self.process }
        try? lock.withLock { input }?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    private func received(_ data: Data) {
        var lines: [String] = []
        let callback = lock.withLock { () -> (@Sendable (String) -> Void)? in
            buffer.append(data)
            if buffer.count > 8_388_608 {
                buffer.removeAll()
                return nil
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.count <= 1_048_576 {
                    lines.append(String(decoding: line, as: UTF8.self))
                }
            }
            return receive
        }
        lines.forEach { callback?($0) }
    }

    static let arguments = [
        "app-server", "--stdio", "--disable", "shell_tool",
        "--disable", "apps", "--disable", "browser_use",
        "--disable", "in_app_browser", "--disable", "image_generation",
        "--disable", "computer_use", "--disable", "view_image",
        "--disable", "multi_agent", "--disable", "skill_search",
        "--disable", "hooks", "-c", "mcp_servers={}",
    ]
}
