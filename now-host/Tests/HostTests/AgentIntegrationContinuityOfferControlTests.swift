import Network
import XCTest
@testable import Host

/// The testable seam itself — a thin wrapper an agent command or debug
/// console verb calls, proven independent of any drag gesture.
@MainActor
final class AgentIntegrationContinuityOfferControlTests: XCTestCase {
    private var listener: GuestListener!
    private var control: AgentIntegrationContinuityOfferControl!
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-offer-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        control = AgentIntegrationContinuityOfferControl(listener: listener)
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        try? FileManager.default.removeItem(at: scratch)
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

    func testPublishingWithNoGuestConnectedIsReportedRatherThanCrashing() {
        let outcome = control.publish(
            fileAt: scratch.appendingPathComponent("Nope.txt"),
            epoch: 1, generation: 1)
        guard case .guestUnavailable = outcome else {
            return XCTFail("expected guestUnavailable, got \(outcome)")
        }
    }

    func testPublishingAMissingFileIsReportedRatherThanCrashing()
        async throws {
        _ = try await connectedGuest()
        let outcome = control.publish(
            fileAt: scratch.appendingPathComponent("Nope.txt"),
            epoch: 1, generation: 1)
        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
    }

    func testPublishReachesTheConnectedGuest() async throws {
        let file = scratch.appendingPathComponent("Read Me.txt")
        try "hi".data(using: .utf8)!.write(to: file)
        let guest = try await connectedGuest()

        let outcome = control.publish(fileAt: file, epoch: 5, generation: 1)
        guard case .published(let item) = outcome else {
            return XCTFail("expected published, got \(outcome)")
        }
        XCTAssertEqual(item.name, "Read Me.txt")

        try await waitUntil("continuity.offer") {
            guest.received.contains { if case .continuityOffer = $0 { return true }
                                      else { return false } }
        }
    }
}
