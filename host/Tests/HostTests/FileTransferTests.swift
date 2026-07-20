import Combine
import Network
import XCTest
@testable import Host

@MainActor
final class FileWireTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    func testListingPagesThroughTheShare() async throws {
        let guest = try await connectedGuest()
        var pages: [FileListing] = []

        listener.listFiles(path: "") { result in
            if case .success(let listing) = result { pages.append(listing) }
        }
        var listId: Int?
        try await waitUntil("file.list") {
            for message in guest.received {
                if case .fileList(let list) = message {
                    listId = list.id
                    return list.path == ""
                }
            }
            return false
        }
        let id = try XCTUnwrap(listId)
        try guest.send(.fileListing(FileListing(
            id: id, path: "",
            entries: [
                FileEntry(name: "Lab", kind: "folder", fileType: nil,
                          creator: nil, dataBytes: nil, rsrcBytes: nil,
                          modified: 3_400_000_000),
                FileEntry(name: "Read Me", kind: "file", fileType: "TEXT",
                          creator: "ttxt", dataBytes: 1200, rsrcBytes: 0,
                          modified: 3_400_000_100),
            ],
            more: true, cursor: 3)))

        try await waitUntil("listing") { pages.count == 1 }
        XCTAssertEqual(pages[0].entries.count, 2)
        XCTAssertTrue(pages[0].entries[0].isFolder)
        XCTAssertEqual(pages[0].entries[1].fileType, "TEXT")
        XCTAssertTrue(pages[0].more)
        XCTAssertEqual(pages[0].cursor, 3)
    }

    func testRefusalFailsTheListing() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.listFiles(path: "Nope") { result in
            if case .failure(let f) = result { failure = f }
        }
        var listId: Int?
        try await waitUntil("file.list") {
            for message in guest.received {
                if case .fileList(let list) = message {
                    listId = list.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileRefuse(FileRefuse(
            id: try XCTUnwrap(listId), code: "not-found",
            reason: "no such folder in the share")))
        try await waitUntil("refusal") { failure != nil }
        XCTAssertEqual(failure?.code, "not-found")
    }

    func testPullDeliversBytesAndClearsProgress() async throws {
        let guest = try await connectedGuest()
        var delivered: GuestListener.FileDelivery?
        listener.getFile(path: "Read Me") { result in
            if case .success(let file) = result { delivered = file }
        }
        var getId: Int?
        try await waitUntil("file.get") {
            for message in guest.received {
                if case .fileGet(let get) = message {
                    getId = get.id
                    return get.path == "Read Me"
                }
            }
            return false
        }
        let id = try XCTUnwrap(getId)
        // Classic text: MacRoman bytes with CR line endings.
        let payload = Data("First\rSecond\r".utf8)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 7, name: "Read Me", container: "data",
            bytes: payload.count, dataBytes: payload.count, rsrcBytes: 0,
            fileType: "TEXT", creator: "ttxt", modified: 3_400_000_100)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 7, payload: payload))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 7, ok: true,
                                        sendMs: 12)))

        try await waitUntil("delivery") { delivered != nil }
        let file = try XCTUnwrap(delivered)
        XCTAssertEqual(file.name, "Read Me")
        XCTAssertEqual(file.container, "data")
        XCTAssertEqual(file.bytes, payload)
        XCTAssertNil(listener.captureProgress,
                     "progress must clear when the file lands")
    }

    func testTruncatedPullIsRejected() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.getFile(path: "Big") { result in
            if case .failure(let f) = result { failure = f }
        }
        var getId: Int?
        try await waitUntil("file.get") {
            for message in guest.received {
                if case .fileGet(let get) = message {
                    getId = get.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(getId)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 9, name: "Big", container: "data",
            bytes: 1000, dataBytes: 1000, rsrcBytes: 0, fileType: "BINA",
            creator: "????", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 9,
            payload: Data(repeating: 0, count: 10)))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 9, ok: true,
                                        sendMs: 1)))
        try await waitUntil("truncation refused") { failure != nil }
        XCTAssertTrue(failure?.message.contains("truncated") == true)
    }
}

final class FileConverterTests: XCTestCase {
    func testClassicTextBecomesUTF8WithUnixEndings() {
        // "café" in MacRoman: é is 0x8E.
        let bytes = Data([0x63, 0x61, 0x66, 0x8E, 0x0D, 0x6F, 0x6B, 0x0D])
        let out = FileConverter.convert(name: "Read Me", container: "data",
                                        fileType: "TEXT", bytes: bytes)
        XCTAssertEqual(String(data: out.data, encoding: .utf8), "café\nok\n")
        XCTAssertNotNil(out.note)
    }

    func testBinaryFilesArePassedThroughUntouched() {
        let bytes = Data([0x00, 0x0D, 0xFF, 0x0D])
        let out = FileConverter.convert(name: "thing.dat", container: "data",
                                        fileType: "BINA", bytes: bytes)
        XCTAssertEqual(out.data, bytes)
        XCTAssertNil(out.note)
    }

    func testMacBinaryKeepsItsBytesAndGainsTheExtension() {
        let bytes = Data(repeating: 7, count: 128)
        let out = FileConverter.convert(name: "SimpleText",
                                        container: "macbinary",
                                        fileType: "APPL", bytes: bytes)
        XCTAssertEqual(out.data, bytes)
        XCTAssertEqual(out.name, "SimpleText.bin")
    }

    func testTextDetectionUsesTypeThenExtension() {
        XCTAssertTrue(FileConverter.isText(fileType: "TEXT", name: "x"))
        XCTAssertTrue(FileConverter.isText(fileType: nil, name: "notes.md"))
        XCTAssertFalse(FileConverter.isText(fileType: "PICT",
                                            name: "shot.pict"))
    }

    func testRoundTripToClassicRestoresCR() {
        let classic = FileConverter.toClassicText("a\nb\r\nc")
        XCTAssertEqual(classic, Data([0x61, 0x0D, 0x62, 0x0D, 0x63]))
    }

    func testUnmappableCharactersAreSubstitutedNotDropped() {
        let classic = FileConverter.toClassicText("a→b")
        XCTAssertEqual(classic.count, 3)
        XCTAssertEqual(classic.first, UInt8(ascii: "a"))
        XCTAssertEqual(classic.last, UInt8(ascii: "b"))
    }

    func testClassicEpochConverts() throws {
        // 1904-01-01 + 3_400_000_000s lands in 2011.
        let date = try XCTUnwrap(ClassicDate.date(from: 3_400_000_000))
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: date)
        XCTAssertEqual(year, 2011)
        XCTAssertNil(ClassicDate.date(from: 0))
    }
}
