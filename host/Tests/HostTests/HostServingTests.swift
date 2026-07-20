import Combine
import Network
import XCTest
@testable import Host

/// The half of the file family the host answers rather than asks: a
/// guest that browses, pulls, and pushes without anyone at this end
/// doing anything. Everything here runs over a real loopback wire, so
/// it exercises the dispatch, not just the share.
@MainActor
final class HostServingTests: XCTestCase {
    private var listener: GuestListener!
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.share.root = root
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A connected guest, past the handshake.
    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "PowerBook 1400",
                                    os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    private func write(_ name: String, _ text: String) throws {
        try text.data(using: .utf8)!
            .write(to: root.appendingPathComponent(name))
    }

    // MARK: - Browsing

    func testGuestCanListWhatTheHostShares() async throws {
        try write("Notes.txt", "hello")
        let guest = try await connectedGuest()

        try guest.send(.fileList(FileList(id: 1, path: "", cursor: nil)))
        try await waitUntil("a listing") {
            guest.received.contains { if case .fileListing = $0 { return true }
                                      else { return false } }
        }
        guard case .fileListing(let listing)? = guest.received.last(where: {
            if case .fileListing = $0 { return true } else { return false }
        }) else { return XCTFail("no listing") }
        XCTAssertEqual(listing.id, 1)
        XCTAssertEqual(listing.entries.map(\.name), ["Notes.txt"])
    }

    func testListingAPathOutsideTheShareIsRefused() async throws {
        let guest = try await connectedGuest()
        try guest.send(.fileList(FileList(id: 2, path: "..", cursor: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.id, 2)
        XCTAssertEqual(refuse.code, "bad-path")
    }

    // MARK: - Pulling

    func testGuestCanPullAFileAndGetsItConverted() async throws {
        try write("Notes.txt", "one\ntwo\n")
        let guest = try await connectedGuest()

        try guest.send(.fileGet(FileGet(id: 3, path: "Notes.txt",
                                        container: nil)))
        try await waitUntil("the transfer to end") {
            guest.received.contains { if case .fileEnd = $0 { return true }
                                      else { return false } }
        }
        guard case .fileBegin(let begin)? = guest.received.first(where: {
            if case .fileBegin = $0 { return true } else { return false }
        }) else { return XCTFail("no begin") }
        XCTAssertEqual(begin.id, 3)
        XCTAssertEqual(begin.name, "Notes.txt")
        XCTAssertEqual(begin.bytes, guest.bulkReceived.count)
        XCTAssertEqual(String(data: guest.bulkReceived, encoding: .macOSRoman),
                       "one\rtwo\r", "line endings the classic Mac reads")
    }

    func testPullingAMissingFileIsRefused() async throws {
        let guest = try await connectedGuest()
        try guest.send(.fileGet(FileGet(id: 4, path: "Nope", container: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.code, "not-found")
    }

    // MARK: - Pushing

    func testGuestCanSendAFileAndItLandsInTheShare() async throws {
        let guest = try await connectedGuest()
        let bytes = "sent from the PowerBook\r".data(using: .macOSRoman)!

        try guest.send(.fileOffer(FileOffer(
            id: 5, name: "Sent.txt", path: "", container: "data",
            bytes: bytes.count, fileType: "TEXT", creator: "ttxt",
            modified: nil, overwrite: nil)))
        try await waitUntil("an accept") {
            guest.received.contains { if case .fileAccept = $0 { return true }
                                      else { return false } }
        }
        try guest.send(.fileBegin(FileBegin(
            id: 5, transfer: 1, name: "Sent.txt", container: "data",
            bytes: bytes.count, dataBytes: nil, rsrcBytes: nil,
            fileType: "TEXT", creator: "ttxt", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(channel: .bulk, transfer: 1,
                                            payload: bytes))
        try guest.send(.fileEnd(FileEnd(id: 5, transfer: 1, ok: true,
                                        sendMs: nil)))

        try await waitUntil("a receipt") {
            guest.received.contains { if case .fileDone = $0 { return true }
                                      else { return false } }
        }
        guard case .fileDone(let done)? = guest.received.last(where: {
            if case .fileDone = $0 { return true } else { return false }
        }) else { return XCTFail("no receipt") }
        XCTAssertTrue(done.ok, done.reason ?? "")

        let landed = root.appendingPathComponent("Sent.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8),
                       "sent from the PowerBook\n",
                       "line endings this Mac reads")
        XCTAssertEqual(listener.received.first?.lastPathComponent, "Sent.txt")
    }

    func testATruncatedPushIsNotSavedAsAWholeFile() async throws {
        let guest = try await connectedGuest()
        try guest.send(.fileOffer(FileOffer(
            id: 6, name: "Half.bin", path: "", container: "data",
            bytes: 64, fileType: nil, creator: nil, modified: nil,
            overwrite: nil)))
        try await waitUntil("an accept") {
            guest.received.contains { if case .fileAccept = $0 { return true }
                                      else { return false } }
        }
        guest.sendRaw(try FrameCodec.encode(channel: .bulk, transfer: 1,
                                            payload: Data(repeating: 7,
                                                          count: 32)))
        try guest.send(.fileEnd(FileEnd(id: 6, transfer: 1, ok: true,
                                        sendMs: nil)))
        try await waitUntil("a receipt") {
            guest.received.contains { if case .fileDone = $0 { return true }
                                      else { return false } }
        }
        guard case .fileDone(let done)? = guest.received.last(where: {
            if case .fileDone = $0 { return true } else { return false }
        }) else { return XCTFail("no receipt") }
        XCTAssertFalse(done.ok)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Half.bin").path))
    }

    func testPushingOverAnExistingFileIsRefused() async throws {
        try write("Sent.txt", "already here")
        let guest = try await connectedGuest()
        try guest.send(.fileOffer(FileOffer(
            id: 7, name: "Sent.txt", path: "", container: "data",
            bytes: 4, fileType: nil, creator: nil, modified: nil,
            overwrite: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.code, "exists")
        XCTAssertEqual(try String(contentsOf: root
            .appendingPathComponent("Sent.txt"), encoding: .utf8),
                       "already here")
    }
}
