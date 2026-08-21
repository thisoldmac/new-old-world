import XCTest
@testable import Host

@MainActor
final class NOWAPIHostAdapterTests: XCTestCase {
    func testAdapterProjectsRememberedGuestAndConfiguredListenerPorts() throws {
        let suite = "now-api-host-adapter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsModel(defaults: defaults)
        settings.listenPort = 55250
        let registry = GuestRegistry()
        _ = registry.identify(
            address: GuestAddress(text: "127.0.0.1"),
            name: "PowerBook 1400c", operatingSystem: "Mac OS 9.1",
            occupiedSlots: [], listenPort: 55251,
            now: Date(timeIntervalSince1970: 1_000))
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"),
            registry: registry)
        let adapter = NOWAPIHostAdapter(listener: listener,
                                        settings: settings)

        let guests = adapter.apiGuests()
        XCTAssertEqual(guests.count, 1)
        XCTAssertEqual(guests[0].id, "guest-1")
        XCTAssertEqual(guests[0].displayName, "PowerBook 1400c")
        XCTAssertFalse(guests[0].connected)
        XCTAssertNil(guests[0].sessionID)

        let status = adapter.apiListener()
        XCTAssertEqual(status.state, "idle")
        XCTAssertEqual(status.desiredPorts, [55250, 55251])
        XCTAssertTrue(status.boundPorts.isEmpty)
        XCTAssertFalse(adapter.apiDisconnect(sessionID: "guest-1"))
    }
}
