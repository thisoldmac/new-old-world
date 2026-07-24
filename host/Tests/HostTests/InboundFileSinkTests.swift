import Foundation
import XCTest
@testable import Host

final class InboundFileSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-inbound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testChunksLandInOneBoundedTemporaryFile() throws {
        let chunks = [
            Data(repeating: 0x11, count: 32 * 1024),
            Data(repeating: 0x22, count: 32 * 1024),
            Data(repeating: 0x33, count: 17),
        ]
        let expected = chunks.reduce(0) { $0 + $1.count }
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: expected)

        for chunk in chunks {
            try sink.append(chunk)
        }
        let staged = try sink.finish(expectedCRC32: nil)

        XCTAssertEqual(staged.byteCount, expected)
        XCTAssertEqual(
            try Data(contentsOf: staged.url),
            chunks.reduce(into: Data()) { $0.append($1) })
        XCTAssertTrue(staged.url.deletingLastPathComponent()
            .standardizedFileURL == directory.standardizedFileURL)
    }

    func testChecksumMismatchDeletesThePartial() throws {
        let payload = Data("not the promised file".utf8)
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: payload.count)
        let partial = sink.temporaryURL
        try sink.append(payload)

        XCTAssertThrowsError(try sink.finish(expectedCRC32: 0x1234_5678))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testTruncationDeletesThePartial() throws {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: 100)
        let partial = sink.temporaryURL
        try sink.append(Data(repeating: 0, count: 10))

        XCTAssertThrowsError(try sink.finish(expectedCRC32: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testAbortDeletesThePartial() throws {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: 100)
        let partial = sink.temporaryURL
        try sink.append(Data(repeating: 0, count: 10))

        sink.abort()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRejectsAChunkPastTheAnnouncedLength() throws {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: 4)

        XCTAssertThrowsError(
            try sink.append(Data(repeating: 0, count: 5)))
    }

    func testBinaryMaterializationAtomicallyConsumesTheStagedFile() throws {
        let payload = Data(repeating: 0xA5, count: 1024 * 1024)
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: payload.count)
        try sink.append(payload)
        let staged = try sink.finish(expectedCRC32:
            TransferIdentity.crc32(payload))
        let source = staged.url
        let destination = directory.appendingPathComponent("Artifact.bin")

        let note = try FileConverter.materialize(
            name: "Artifact.bin", container: "data", fileType: "BINA",
            staged: staged, to: destination)

        XCTAssertNil(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testTextMaterializationStreamsAcrossACRLFChunkBoundary() throws {
        var payload = Data(repeating: UInt8(ascii: "A"),
                           count: 64 * 1024 - 1)
        payload.append(UInt8(ascii: "\r"))
        payload.append(UInt8(ascii: "\n"))
        payload.append(contentsOf: [UInt8(ascii: "B"),
                                    UInt8(ascii: "\r")])
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: payload.count)
        try sink.append(payload)
        let staged = try sink.finish(expectedCRC32: nil)
        let source = staged.url
        let destination = directory.appendingPathComponent("Read Me")

        let note = try FileConverter.materialize(
            name: "Read Me", container: "data", fileType: "TEXT",
            staged: staged, to: destination)

        XCTAssertEqual(note, "MacRoman → UTF-8, CR → LF")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "conversion consumed the staged source even while its owner lives")
        let result = try Data(contentsOf: destination)
        XCTAssertEqual(result.count, 64 * 1024 + 2)
        XCTAssertEqual(result.suffix(3), Data([UInt8(ascii: "\n"),
                                               UInt8(ascii: "B"),
                                               UInt8(ascii: "\n")]))
    }

    func testClassicTextBecomesUTF8WithUnixEndings() throws {
        // "café" in MacRoman: é is 0x8E.
        let payload = Data(
            [0x63, 0x61, 0x66, 0x8E, 0x0D, 0x6F, 0x6B, 0x0D])
        let sink = try InboundFileSink(
            directory: directory, expectedBytes: payload.count)
        try sink.append(payload)
        let staged = try sink.finish(expectedCRC32: nil)
        let destination = directory.appendingPathComponent("Read Me")

        let note = try FileConverter.materialize(
            name: "Read Me", container: "data", fileType: "TEXT",
            staged: staged, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "café\nok\n")
        XCTAssertNotNil(note)
    }

    func testMacBinaryKeepsItsBytesAndGainsTheExtension() throws {
        let payload = Data(repeating: 7, count: 128)
        let sink = try InboundFileSink(
            directory: directory, expectedBytes: payload.count)
        try sink.append(payload)
        let staged = try sink.finish(expectedCRC32: nil)
        let outputName = FileConverter.outputName(
            name: "SimpleText", container: "macbinary")
        let destination = directory.appendingPathComponent(outputName)

        let note = try FileConverter.materialize(
            name: "SimpleText", container: "macbinary", fileType: "APPL",
            staged: staged, to: destination)

        XCTAssertEqual(outputName, "SimpleText.bin")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(note, "MacBinary (both forks)")
    }

    func testProgressReportsAreBatchedAndAlwaysIncludeTheEnd() throws {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: 40 * 1024)
        try sink.append(Data(repeating: 1, count: 8 * 1024))
        XCTAssertNil(sink.takeProgressReport())
        try sink.append(Data(repeating: 1, count: 24 * 1024))
        XCTAssertEqual(sink.takeProgressReport(), 32 * 1024)
        try sink.append(Data(repeating: 1, count: 8 * 1024))
        XCTAssertEqual(sink.takeProgressReport(), 40 * 1024)
    }

    func testIncreasingPayloadsDoNotIncreaseTheInMemoryWriteBound() throws {
        let chunk = Data(repeating: 0x6D, count: 32 * 1024)
        for size in [256 * 1024, 2 * 1024 * 1024, 16 * 1024 * 1024] {
            let sink = try InboundFileSink(
                directory: directory, expectedBytes: size)
            var remaining = size
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try sink.append(chunk.prefix(count))
                remaining -= count
            }
            let staged = try sink.finish(expectedCRC32: nil)
            XCTAssertEqual(staged.byteCount, size)
            XCTAssertEqual(sink.maximumAppendBytes, 32 * 1024)
        }
    }
}
