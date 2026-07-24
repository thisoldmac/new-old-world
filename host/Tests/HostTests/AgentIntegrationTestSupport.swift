import XCTest
@testable import Host

private struct AgentIntegrationWaitTimeout: Error {
    let what: String
}

@MainActor
func waitUntil(
    _ what: String,
    timeout: TimeInterval = 5,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("timed out waiting for \(what)")
            throw AgentIntegrationWaitTimeout(what: what)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
func connectedListener() async throws -> (GuestListener, FakeGuest) {
    let listener = GuestListener(
        identity: .init(version: "0.1-test", name: "Test Host"),
        timing: .init(idleTimeout: 60))
    listener.start(port: 0)
    try await waitUntil("listener ready") {
        if case .listening = listener.state { return true }
        return false
    }

    let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
    guest.start()
    try guest.send(.hello(Hello(
        contract: Contract.revision,
        side: "guest",
        version: "0.1.0",
        name: "PowerBook 1400",
        os: "9.1",
        chunk: 8192)))
    try await waitUntil("connected guest") {
        if case .connected = listener.state { return true }
        return false
    }
    return (listener, guest)
}
