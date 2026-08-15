import Foundation
import XCTest
@testable import Host

final class MacBinaryDecoderTests: XCTestCase {
    func testWriteFailureNamesTheFork() {
        XCTAssertEqual(
            MacBinaryFile.DecodeError.couldNotWriteFork("resource")
                .errorDescription,
            "The resource fork could not be written to the setup image.")
    }

    func testDecoderRestoresNameMetadataAndBothForks() throws {
        let dataFork = Data([1, 2, 3, 4, 5])
        let resourceFork = Data([6, 7, 8])
        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Native App", type: "APPL", creator: "NOWo",
            dataFork: dataFork, resourceFork: resourceFork))

        let decoded = try MacBinaryFile.decode(encoded)

        XCTAssertEqual(decoded.name, "Native App")
        XCTAssertEqual(decoded.type, "APPL")
        XCTAssertEqual(decoded.creator, "NOWo")
        XCTAssertEqual(decoded.dataFork, dataFork)
        XCTAssertEqual(decoded.resourceFork, resourceFork)
    }

    func testDecoderRefusesTruncatedEnvelope() throws {
        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Native App", type: "APPL", creator: "NOWo",
            dataFork: Data(repeating: 1, count: 200)))

        XCTAssertThrowsError(try MacBinaryFile.decode(encoded.dropLast()))
    }

    func testNativeWriterRestoresFinderInfoAndResourceFork() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = MacBinaryFile(
            name: "Native App", type: "APPL", creator: "NOWo",
            finderFlags: 0x0100, dataFork: Data([1, 2]),
            resourceFork: Data([3, 4, 5]))

        let url = try file.write(to: temporary)

        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath:
            url.path + "/..namedfork/rsrc")), Data([3, 4, 5]))
        let finderInfo = try XCTUnwrap(try url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
        XCTAssertNotNil(finderInfo)
        let xattr = try finderInfoBytes(at: url)
        XCTAssertEqual(String(bytes: xattr[0..<4], encoding: .ascii), "APPL")
        XCTAssertEqual(String(bytes: xattr[4..<8], encoding: .ascii), "NOWo")
        XCTAssertEqual(xattr[8], 1)
    }

    func testPromiseMaterializerConsumesEnvelopeAndRestoresPromisedFile()
        throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let envelope = temporary.appendingPathComponent(".incoming.bin")
        let promised = temporary.appendingPathComponent("Promised Name")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Guest Name", type: "APPL", creator: "NOWo",
            dataFork: Data([1, 2]), resourceFork: Data([3, 4, 5])))
        try encoded.write(to: envelope)

        try MacBinaryFile.materializePromise(
            envelope: envelope, destination: promised, modified: modified)

        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path),
                       "the transport envelope must be consumed")
        XCTAssertEqual(try Data(contentsOf: promised), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath:
            promised.path + "/..namedfork/rsrc")), Data([3, 4, 5]))
        let xattr = try finderInfoBytes(at: promised)
        XCTAssertEqual(String(bytes: xattr[0..<4], encoding: .ascii), "APPL")
        XCTAssertEqual(String(bytes: xattr[4..<8], encoding: .ascii), "NOWo")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: promised.path)
        let writtenDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(writtenDate.timeIntervalSince1970,
                       modified.timeIntervalSince1970, accuracy: 1)
    }

    func testPromiseMaterializerPreservesAnExistingDestination() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let envelope = temporary.appendingPathComponent(".incoming.bin")
        let promised = temporary.appendingPathComponent("Promised Name")
        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Guest Name", type: "APPL", creator: "NOWo",
            dataFork: Data("guest".utf8), resourceFork: Data()))
        try encoded.write(to: envelope)
        try Data("mine".utf8).write(to: promised)

        XCTAssertThrowsError(try MacBinaryFile.materializePromise(
            envelope: envelope, destination: promised, modified: nil))

        XCTAssertEqual(try Data(contentsOf: promised), Data("mine".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testPromiseMaterializerKeepsFinderInfoWithoutAResourceFork() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let envelope = temporary.appendingPathComponent(".incoming.bin")
        let promised = temporary.appendingPathComponent("Notes.txt")
        let encoded = try XCTUnwrap(MacBinaryEncoder.data(
            name: "Notes.txt", type: "TEXT", creator: "ttxt",
            dataFork: Data("hello".utf8), resourceFork: Data()))
        try encoded.write(to: envelope)

        try MacBinaryFile.materializePromise(
            envelope: envelope, destination: promised, modified: nil)

        let finderInfo = try finderInfoBytes(at: promised)
        XCTAssertEqual(String(bytes: finderInfo[0..<4], encoding: .ascii),
                       "TEXT")
        XCTAssertEqual(String(bytes: finderInfo[4..<8], encoding: .ascii),
                       "ttxt")
    }

    private func finderInfoBytes(at url: URL) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = url.path.withCString { path in
            "com.apple.FinderInfo".withCString { attribute in
                getxattr(path, attribute, &bytes, bytes.count, 0, 0)
            }
        }
        guard result == bytes.count else { throw TestError.couldNotRead }
        return bytes
    }

    private enum TestError: Error {
        case couldNotRead
    }
}
