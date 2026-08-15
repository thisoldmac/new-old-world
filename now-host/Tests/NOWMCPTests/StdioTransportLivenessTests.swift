import Foundation
@testable import Host
import XCTest

/// **The gate for a surface that answers a batch and ignores a client.**
///
/// Every other test in this tree calls `NOWMCPServer.handle(_:)` directly.
/// That is the right seam for what a tool does — and it is exactly why the
/// defect this file exists for survived: the bug was not in a tool, or in
/// the framer, or in the server. It was in the four lines that read bytes
/// off stdin, which no test reached and every ad-hoc driver got away with.
///
/// `FileHandle.standardInput.readData(ofLength: 4096)` loops until it has
/// the full count or the descriptor ends. An MCP client holds stdio open for
/// the life of the session and sends one small line at a time, so the loop
/// sat on a 76-byte `initialize` waiting for 4020 bytes that were never
/// coming. **The whole surface answered nothing** — not seven tools, all
/// forty-one — to any client that behaves the way the transport says clients
/// behave. Everything that ever drove this binary wrote its whole script and
/// closed stdin, which is what makes the blocking read return; a pipeline
/// that closes the pipe is a batch, not a client, and the surface passed on
/// batches alone.
///
/// So this test spawns the real executable, writes ONE small line, and
/// **holds stdin open** — the one condition every previous driver removed.
/// It is deliberately an end-to-end spawn rather than a unit test with an
/// injected byte source: a fake source would have been satisfied by the
/// broken code, because the bug is a property of `FileHandle` and not of any
/// abstraction over it. A gate that could not have failed is not a gate.
final class StdioTransportLivenessTests: XCTestCase {

    /// How long a healthy answer may take. Generous by an order of
    /// magnitude: `initialize` reaches no host and no Macintosh, so this is
    /// a bound on process start, not on work. The broken form does not miss
    /// it by a margin — it never answers at all.
    private static let deadline: TimeInterval = 15

    func testExecutableGenerationDetectsAtomicBundleReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("NOW")
        try Data("old".utf8).write(to: executable)
        let generation = try XCTUnwrap(
            MCPExecutableGeneration(executableURL: executable))
        XCTAssertTrue(generation.isCurrent)

        let replacement = directory.appendingPathComponent("replacement")
        try Data("new".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(
            executable, withItemAt: replacement)

        XCTAssertFalse(
            generation.isCurrent,
            "a companion must notice when its stable app path names a new vnode")
    }

    func testStaleCompanionNamesRetryWithoutReachingHost() throws {
        let request = Data(#"{"jsonrpc":"2.0","id":17,"method":"tools/call"}"#.utf8)
        let data = try XCTUnwrap(MCPStaleCompanionResponse.make(for: request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 17)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        let detail = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(detail["code"] as? String,
                       "now-mcp-companion-stale")
        XCTAssertEqual(detail["reach"] as? String, "notSent")
    }

    func testAnswersOneSmallMessageWithStandardInputStillOpen() throws {
        let executable = try Self.hostExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mcp-stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let request = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":\
            {"protocolVersion":"2024-11-05","capabilities":{},\
            "clientInfo":{"name":"gate","version":"0"}}}

            """
        input.fileHandleForWriting.write(Data(request.utf8))
        /* NOT closed, and that is the entire test. Closing it here would
           restore the exact condition that hid the defect for months. */

        let answered = expectation(description: "a reply arrives")
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if collected.append(data) { answered.fulfill() }
        }
        let outcome = XCTWaiter().wait(for: [answered], timeout: Self.deadline)
        output.fileHandleForReading.readabilityHandler = nil

        guard outcome == .completed else {
            return XCTFail("""
                New Old World's MCP stdio mode answered nothing in \
                \(Int(Self.deadline))s to one small `initialize` written \
                with standard input STILL OPEN — which is how every real \
                MCP client speaks to it.

                The likely cause is the read loop in StdioMCP.swift asking \
                for a fixed number of bytes: `readData(ofLength:)` loops \
                until it has the whole count or the pipe closes, so a \
                short line sits unread until 4 KiB arrives. Use \
                `availableData`. A driver that writes its whole script and \
                closes stdin will NOT reproduce this — that is a batch, and \
                the surface has always passed batches.
                """)
        }
        let reply = collected.text()
        XCTAssertTrue(
            reply.contains("\"id\":1"),
            "The first line back was not a reply to the request: \(reply)")
    }

    /// Accumulates until a whole line is in hand. `readabilityHandler` fires
    /// on whatever the pipe has, which may be part of a line.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        /// True once a newline has arrived — a whole reply, not a fragment.
        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            return data.contains(0x0A)
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? "<not UTF-8>"
        }
    }

    /// The built companion, beside the test bundle.
    ///
    /// It FAILS rather than skips when it is missing. A gate that quietly
    /// declines to run is how the hole this file fills came to exist —
    /// AGENTS.md says so about `test-mirrorkit`, in almost these words — and
    /// the executable is a product of the same package as this test, so its
    /// absence is a broken build rather than a missing toolchain.
    private static func hostExecutable() throws -> URL {
        let candidate = Bundle(for: StdioTransportLivenessTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Host")
        guard FileManager.default.isExecutableFile(atPath: candidate.path)
        else {
            XCTFail("""
                No New Old World Host executable beside the test bundle at \
                \(candidate.path). It is a product of this same package, so \
                this is a build that did not produce it rather than a \
                missing tool — and this gate does not skip, because the \
                transport it covers has no other test.
                """)
            throw CocoaError(.fileNoSuchFile)
        }
        return candidate
    }
}
