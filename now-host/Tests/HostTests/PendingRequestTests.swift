import Combine
import Network
import XCTest
@testable import Host

/// A guest that connects and then goes silent — the modal-dialog case.
@MainActor
final class PendingRequestTests: XCTestCase {
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

    // MARK: - Nothing is dropped when a session dies

    func testEverythingPendingFailsWhenTheSessionCloses() async throws {
        let guest = try await connectedGuest()
        var captureFailed = false
        var fileFailed = false
        var listingFailed = false
        var commandFailed = false

        listener.requestCapture(depth: 8) { result in
            if case .failure = result { captureFailed = true }
        }
        listener.getFile(path: "Read Me") { result in
            if case .failure = result { fileFailed = true }
        }
        listener.listFiles(path: "") { result in
            if case .failure = result { listingFailed = true }
        }
        listener.runCommand("gestalt") { result in
            if !result.ok { commandFailed = true }
        }
        try await waitUntil("requests sent") { guest.received.count >= 4 }

        // The guest vanishes without a bye — the wedged-app case.
        guest.connection.cancel()

        try await waitUntil("all settled") {
            captureFailed && fileFailed && listingFailed && commandFailed
        }
        XCTAssertNil(listener.captureProgress)
    }

    // MARK: - Silence is bounded

    func testASilentGuestTimesOutInsteadOfHangingForever() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        // The listing watchdog is 15s; drive it directly rather than
        // sleeping the test out.
        listener.listFiles(path: "") { result in
            if case .failure(let f) = result { failure = f }
        }
        try await waitUntil("file.list sent") {
            guest.received.contains {
                if case .fileList = $0 { return true }
                return false
            }
        }
        listener.expireWatchdogsForTesting()
        try await waitUntil("timed out") { failure != nil }
        XCTAssertEqual(failure?.code, "timeout")
        XCTAssertTrue(failure?.message.contains("did not answer") == true
                      || failure?.message.contains("stopped answering")
                          == true)
    }

    // MARK: - Cancel always means "stop waiting"

    func testCancelSettlesEvenBeforeTheTransferStarts() async throws {
        let guest = try await connectedGuest()
        var failure: String?
        listener.requestCapture(depth: 8) { result in
            if case .failure(let f) = result { failure = f.message }
        }
        try await waitUntil("capture.request sent") {
            guest.received.contains {
                if case .captureRequest = $0 { return true }
                return false
            }
        }
        // The guest never answers — it is showing a dialog.
        listener.cancelCapture()
        try await waitUntil("cancelled") { failure != nil }
        XCTAssertEqual(failure, "Capture cancelled")
    }

    func testBulkAfterACancelIsDiscardedNotFatal() async throws {
        let guest = try await connectedGuest()
        var settled = false
        listener.requestCapture(depth: 8) { _ in settled = true }
        var requestId: Int?
        try await waitUntil("capture.request") {
            for message in guest.received {
                if case .captureRequest(let request) = message {
                    requestId = request.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(requestId)
        let palette = [UInt8](repeating: 0, count: 768)
        try guest.send(.captureBegin(CaptureBegin(
            id: id, transfer: 4, width: 4, height: 2, depth: 8,
            rowBytes: 4, bytes: palette.count + 8, paletteBytes: 768,
            encoding: "raw", frame: nil, rects: nil,
            captureMs: 1, encodeMs: 1)))
        try await waitUntil("begin seen") { self.listener.captureProgress != nil }

        listener.cancelCapture()
        try await waitUntil("cancel settled") { settled }

        // The guest drains its in-flight frame after the cancel; those
        // bytes must not be read as a protocol violation.
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 4,
            payload: Data(palette + [1, 1, 1, 1, 1, 1, 1, 1])))
        try guest.send(.captureEnd(CaptureEnd(id: id, transfer: 4,
                                              ok: false, sendMs: 5)))
        try await Task.sleep(nanoseconds: 300_000_000)

        if case .connected = listener.state {
            // Still connected: the session survived the abandoned bytes.
        } else {
            XCTFail("session died on post-cancel bulk: \(listener.state)")
        }
        // And the connection is immediately usable again.
        var second = false
        listener.requestCapture(depth: 8) { _ in second = true }
        try await waitUntil("second request accepted") {
            guest.received.filter {
                if case .captureRequest = $0 { return true }
                return false
            }.count == 2
        }
        listener.cancelCapture()
        try await waitUntil("second settled") { second }
    }
}
