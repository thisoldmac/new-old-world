import Foundation
@testable import Host
import XCTest

final class MCPStdioTombstoneTests: XCTestCase {
    func testDiagnosticIsOneBoundedSecretFreeLine() throws {
        let pipe = Pipe()
        MCPStdioTombstone.writeDiagnostic(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let text = String(decoding:
            pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(text, MCPStdioTombstone.diagnostic + "\n")
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertLessThanOrEqual(text.utf8.count, 512)
        XCTAssertTrue(text.contains("Streamable HTTP"))
        XCTAssertTrue(text.contains(MCPStdioTombstone.supportURL))
        XCTAssertFalse(text.contains("/Users/"))
    }

    func testRemovedEntryPointFailsWithoutWritingProtocolOutput() throws {
        let process = Process()
        process.executableURL = try Self.hostExecutable()
        process.arguments = ["--mcp-stdio"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading
            .readDataToEndOfFile().isEmpty)
        let diagnostic = String(decoding: error.fileHandleForReading
            .readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(diagnostic, MCPStdioTombstone.diagnostic + "\n")
    }

    private static func hostExecutable() throws -> URL {
        let directory = Bundle(for: MCPStdioTombstoneTests.self).bundleURL
            .deletingLastPathComponent()
        for name in ["Host", "Host-product"] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
