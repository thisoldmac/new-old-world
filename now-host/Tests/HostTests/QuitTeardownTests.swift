import Foundation
import Network
import XCTest
@testable import Host

/// What ⌘Q owes a connected Mac.
///
/// `bye` is a write, and a write needs a turn of the run loop to leave. The
/// existing `stop()` hands it to the connection and returns, which is right
/// for stopping a listener and wrong for quitting a process: terminating in
/// the same turn takes the socket down with the farewell still queued, and
/// the guest — which auto-reconnects — spends its keepalive window (~65 s)
/// dialling a host that no longer exists, then reports a timeout rather than
/// a shutdown. On OS 9 an unannounced close also leaks a T_DISCONNECT
/// indication, which is why the contract asks for `bye` at all.
///
/// So the invariant is a sequencing one: **shutDown does not report until the
/// socket has taken the farewell.** That is what a test on this side can
/// actually see — `contentProcessed` says the kernel has the bytes, not that
/// the PowerBook has read them — and it is the thing that was wrong. Whether
/// the guest then draws the right conclusion is metal work, and unverified.
@MainActor
final class QuitTeardownTests: XCTestCase {

    private func listening() async throws -> GuestListener {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .listening = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .listening = listener.state else {
            throw XCTSkip("could not bind a loopback port")
        }
        return listener
    }

    func testTheFarewellIsSentAndWaitedFor() async throws {
        let listener = try await listening()
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "PowerBook 1400",
                                    os: "9.1", chunk: nil)))
        let connected = Date().addingTimeInterval(8)
        while Date() < connected {
            if case .connected = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 1400"))

        var reported = false
        listener.shutDown { reported = true }
        // The guard that matters: with a guest connected, the report cannot
        // come back in the same turn, because the write has not been handed
        // to the socket yet. A shutDown that reports here is one that lets
        // NSApp terminate with the farewell still queued — the whole defect.
        XCTAssertFalse(reported, """
            shutDown reported synchronously, so it waited for nothing: the \
            process would terminate with `bye` still queued and the guest \
            would sit reconnecting until its keepalive gave up.
            """)

        let deadline = Date().addingTimeInterval(5)
        while !reported, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(reported,
                      "shutDown never reported — ⌘Q would hang, because "
                      + "terminateLater waits for this")

        while Date() < deadline,
              !guest.received.contains(where: {
                  if case .bye = $0 { return true }
                  return false
              }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let byes = guest.received.compactMap { message -> Bye? in
            if case .bye(let bye) = message { return bye }
            return nil
        }
        XCTAssertEqual(byes.count, 1,
                       "the guest must be told: \(guest.received)")
        XCTAssertEqual(byes.first?.code, .shuttingDown,
                       "\"shutting down\" is what distinguishes a quit from "
                       + "a dropped wire, and it is the whole reason to wait")
        XCTAssertEqual(listener.state, .idle)
    }

    /// No guest, and ⌘Q must still quit. `applicationShouldTerminate` returns
    /// `terminateLater`, so a completion that never fires is an app that never
    /// goes away — the failure mode of fixing ⌘Q badly.
    func testShutDownReportsWithNoGuestConnected() async throws {
        let listener = try await listening()
        var reported = false
        listener.shutDown { reported = true }
        XCTAssertTrue(reported,
                      "with nothing to say goodbye to there is nothing to "
                      + "wait for")
        XCTAssertEqual(listener.state, .idle)
    }

    /// A guest that has stopped reading is exactly the one that most needs
    /// telling, and exactly the one that cannot be told. The wait is bounded
    /// so the quit still happens.
    func testShutDownGivesUpOnAGuestThatWillNotListen() async throws {
        let listener = try await listening()
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "Wedged",
                                    os: "9.1", chunk: nil)))
        let connected = Date().addingTimeInterval(8)
        while Date() < connected {
            if case .connected = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Vanish without a close, the way a lid coming down does.
        guest.connection.cancel()

        var reported = false
        let started = Date()
        listener.shutDown(timeout: 0.2) { reported = true }
        let deadline = Date().addingTimeInterval(5)
        while !reported, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(reported, "the quit must not wait on a dead socket")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4,
                          "and it must give up promptly")
    }

    /// Once is once: the completion drives `reply(toApplicationShouldTerminate:)`,
    /// and a second reply is a runtime complaint from AppKit.
    func testTheCompletionFiresExactlyOnce() async throws {
        let listener = try await listening()
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "PowerBook 1400",
                                    os: "9.1", chunk: nil)))
        let connected = Date().addingTimeInterval(8)
        while Date() < connected {
            if case .connected = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        var count = 0
        listener.shutDown(timeout: 0.1) { count += 1 }
        // Past the timeout, so both the flush and the deadline have fired.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(count, 1)
    }
}
