import Combine
import Network
import XCTest
@testable import Host

/// The file-pull lane is one wide, and these pin the two ways it used to
/// stop being one wide without anybody finding out.
///
/// The symptom a person reported was a drag-out that left a filename
/// printed on the Desktop until NOW quit, after which no drag-out worked
/// again for the rest of the session. Neither half of that is drawn by this
/// app: the placeholder is Finder's own, still waiting on a promise whose
/// completion was dropped, and the freeze is `GuestFilePromiseExporter`
/// refusing new work because the promise it is still holding never ended.
@MainActor
final class GuestFileLaneGuardTests: XCTestCase {
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

    private func fileGetIDs(_ guest: FakeGuest) -> [Int] {
        guest.received.compactMap {
            guard case .fileGet(let get) = $0 else { return nil }
            return get.id
        }
    }

    /// The one that matters. `getFile` had no `pendingFile == nil` guard
    /// while all three of its siblings did, so the second ask overwrote the
    /// first waiter in a single unkeyed slot: the second caller was handed
    /// the FIRST file's bytes and the first caller was never called at all.
    /// A drag-out is the first caller, and a never-called completion is
    /// exactly the wedge.
    func testASecondPullIsRefusedRatherThanStealingTheFirstsWaiter()
        async throws {
        let guest = try await connectedGuest()
        var first: Result<GuestListener.FileDelivery,
                          GuestListener.FileFailure>?
        var second: Result<GuestListener.FileDelivery,
                           GuestListener.FileFailure>?

        listener.getFile(path: "First") { first = $0 }
        try await waitUntil("first file.get") {
            self.fileGetIDs(guest).count == 1
        }
        listener.getFile(path: "Second") { second = $0 }

        guard case .failure(let refusal) = try XCTUnwrap(second) else {
            return XCTFail("the second pull took the lane")
        }
        XCTAssertEqual(refusal.code, "busy")
        XCTAssertNil(first, "the first caller must still be waiting")
        XCTAssertEqual(fileGetIDs(guest).count, 1,
                       "a refused pull must not reach the guest either")

        // And the first pull still settles with its OWN bytes.
        let id = try XCTUnwrap(fileGetIDs(guest).first)
        let payload = Data("first\r".utf8)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 3, name: "First", container: "data",
            bytes: payload.count, dataBytes: payload.count, rsrcBytes: 0,
            fileType: "TEXT", creator: "ttxt", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 3, payload: payload))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 3, ok: true,
                                        sendMs: 1)))
        try await waitUntil("first delivery") { first != nil }
        guard case .success(let delivered) = try XCTUnwrap(first) else {
            return XCTFail("the first pull did not deliver")
        }
        XCTAssertEqual(delivered.name, "First")
        XCTAssertEqual(try Data(contentsOf: delivered.staged.url), payload)
    }

    /// The lane must reopen once the first pull settles — a guard that
    /// refuses forever would trade a wedge for a wedge.
    func testTheLaneReopensOnceTheFirstPullSettles() async throws {
        let guest = try await connectedGuest()
        var first: GuestListener.FileFailure?
        var second: Result<GuestListener.FileDelivery,
                           GuestListener.FileFailure>?

        listener.getFile(path: "First") {
            if case .failure(let failure) = $0 { first = failure }
        }
        try await waitUntil("first file.get") {
            self.fileGetIDs(guest).count == 1
        }
        let id = try XCTUnwrap(fileGetIDs(guest).first)
        try guest.send(.fileRefuse(FileRefuse(
            id: id, code: "not-found", reason: "no such file")))
        try await waitUntil("first refused") { first != nil }

        listener.getFile(path: "Second") { second = $0 }
        try await waitUntil("second file.get") {
            self.fileGetIDs(guest).count == 2
        }
        XCTAssertNil(second, "the second pull must be live, not refused")
    }

    /// `getDevelopmentProjectFile` shares the same slot and had the same
    /// hole. Reached from a different feature, so it needs its own line.
    func testTheProjectFilePullSharesTheSameOneWaiterRule() async throws {
        let guest = try await connectedGuest()
        var second: GuestListener.FileFailure?

        listener.getFile(path: "First") { _ in }
        try await waitUntil("first file.get") {
            self.fileGetIDs(guest).count == 1
        }
        listener.getDevelopmentProjectFile(
            projectID: "p", path: "main.c",
            stagingDirectory: FileManager.default.temporaryDirectory) {
            if case .failure(let failure) = $0 { second = failure }
        }

        XCTAssertEqual(second?.code, "busy")
    }
}

/// The exporter's own way out. Its only exit is a callback it does not own,
/// so it needs one that does not depend on the lane below behaving.
@MainActor
final class GuestFilePromiseSilenceTests: XCTestCase {
    private func entry(_ name: String) -> FileEntry {
        FileEntry(name: name, kind: "file", fileType: "TEXT",
                  creator: "ttxt", dataBytes: 4, rsrcBytes: 0,
                  modified: nil, identity: name)
    }

    private func row(_ name: String) -> FileRow {
        FileRow(entry: entry(name), path: name)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-silence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A completion that never arrives used to hold `active` for the life
    /// of the process, and `startNextIfIdle` refuses every later drag-out
    /// while it is held. That is "further drag-outs freeze", and no amount
    /// of correctness in the wire below removes the need for this: the queue
    /// must be able to give up on its own.
    func testALostCompletionDoesNotHoldTheLaneForTheRestOfTheSession()
        throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [String] = []
        var reported: [String] = []
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, _ in XCTFail("no folder in this test") },
            fetchFile: { row, _, _ in
                started.append(row.name)
                /* The defect being modelled: the callback is dropped. */
            },
            onFailure: { reported.append($0.localizedDescription) })

        var firstResult: Result<Void, Error>?
        var secondResult: Result<Void, Error>?
        exporter.enqueue(row("Lost"),
                         to: root.appendingPathComponent("Lost")) {
            firstResult = $0
        }
        exporter.enqueue(row("Next"),
                         to: root.appendingPathComponent("Next")) {
            secondResult = $0
        }
        XCTAssertEqual(started, ["Lost"],
                       "the queue is one wide, so only the first starts")
        XCTAssertNil(firstResult)

        exporter.expireSilenceForTesting()

        XCTAssertNotNil(firstResult, "the abandoned promise must settle")
        if case .success = try XCTUnwrap(firstResult) {
            XCTFail("an abandoned promise did not succeed")
        }
        XCTAssertEqual(started, ["Lost", "Next"],
                       "the lane must reopen for the promise behind it")
        XCTAssertEqual(reported.count, 1,
                       "the person is told once, by name")
        XCTAssertTrue(reported[0].contains("Lost"))
        XCTAssertNil(secondResult, "the second promise is live, not failed")
    }

    /// Abandoning bumps the generation on purpose: the callback was
    /// abandoned because it was missing, and a missing callback may still
    /// turn up. If it did, it must not publish a file into a destination
    /// AppKit has already been told about, nor settle the promise twice.
    func testALateCompletionFromAnAbandonedPromiseIsIgnored() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var held: [(URL, (Result<Void, Error>) -> Void)] = []
        let exporter = GuestFilePromiseExporter(
            listPage: { _, _, _ in XCTFail("no folder in this test") },
            fetchFile: { _, staging, completion in
                held.append((staging, completion))
            })

        var settlements = 0
        let destination = root.appendingPathComponent("Lost")
        exporter.enqueue(row("Lost"), to: destination) { _ in
            settlements += 1
        }
        exporter.expireSilenceForTesting()
        XCTAssertEqual(settlements, 1)

        let (staging, completion) = try XCTUnwrap(held.first)
        FileManager.default.createFile(atPath: staging.path, contents: Data())
        completion(.success(()))

        XCTAssertEqual(settlements, 1,
                       "a late completion must not settle it a second time")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "nor publish into a destination already given up on")
    }
}
