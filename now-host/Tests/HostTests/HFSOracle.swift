import Foundation
import XCTest

/// The hfsutils oracle, shared by every test that needs an HFS Standard
/// volume read back by an implementation this repository does not own.
enum HFSOracle {
    static func tools() throws -> String {
        // Same resolution as the Makefile, VALIDATED at each step - a
        // worktree's .env.lab copied from the example carries /path/to/
        // placeholders that would otherwise shadow the main worktree's
        // real value (which cost this desk an evening once already).
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["NOW_HFSUTILS"] {
            candidates.append(path)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HostTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // now-host
            .deletingLastPathComponent()  // repo root
        var roots = [root]
        if let range = root.path.range(of: "/.claude/worktrees/") {
            roots.append(URL(fileURLWithPath:
                String(root.path[..<range.lowerBound])))
        }
        for directory in roots {
            for envFile in [".env", ".env.lab"] {
                let url = directory.appendingPathComponent(envFile)
                guard let text = try? String(contentsOf: url,
                                             encoding: .utf8) else {
                    continue
                }
                for line in text.split(whereSeparator: \.isNewline)
                    where line.hasPrefix("NOW_HFSUTILS=") {
                    candidates.append(String(
                        line.dropFirst("NOW_HFSUTILS=".count)))
                }
            }
        }
        for candidate in candidates where !candidate.isEmpty {
            if FileManager.default.isExecutableFile(
                atPath: candidate + "/hmount") {
                return candidate
            }
        }
        throw XCTSkip("no usable NOW_HFSUTILS (checked environment and "
                      + "env files) - the hfsutils oracle cannot read "
                      + "the volume back (docs/lab-setup.md)")
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    home: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // hfsutils keeps mount state in $HOME/.hcwd; a private HOME keeps
        // parallel tests and the desk's own state out of each other.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw Failure.command(String(data: stderr, encoding: .utf8)
                ?? executable)
        }
        return stdout
    }

    enum Failure: Error {
        case command(String)
    }
}
