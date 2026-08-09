import XCTest
@testable import Host

/// The two visible projections of a guest's disk — the open listing and
/// Places — refresh together at connection and at the person's request.
@MainActor
final class FilesRefreshTests: XCTestCase {
    private var listener: GuestListener!
    private var model: FilesModuleModel!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "files.refresh.\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    func testConnectingAutomaticallyRefreshesTheListingAndPlaces()
        async throws {
        let fixture = try await connectedFixture()
        model.connection = try connectedState()

        try await waitUntil("connection listing") {
            self.model.rows.map(\.name) == ["item-1"]
        }
        try await waitUntil("connection Places sweep") {
            self.model.locations.map(\.path) == [""]
        }
        XCTAssertEqual(fixture.rootRequests, 1,
                       "one root listing serves both projections")
    }

    func testBrowserRefreshReloadsTheListingAndPlaces() async throws {
        let fixture = try await connectedFixture()
        model.connection = try connectedState()
        try await waitUntil("initial browser refresh") {
            self.model.rows.map(\.name) == ["item-1"]
                && !self.model.isDiscoveringLocations
        }
        let firstSweepRequests = fixture.softwareRequests
        let firstRootRequests = fixture.rootRequests

        fixture.listingItem = 2
        model.refreshBrowser()

        try await waitUntil("manual listing refresh") {
            self.model.rows.map(\.name) == ["item-2"]
        }
        try await waitUntil("manual Places refresh") {
            fixture.softwareRequests > firstSweepRequests
                && !self.model.isDiscoveringLocations
        }
        XCTAssertEqual(fixture.rootRequests, firstRootRequests + 1,
                       "manual refresh does not duplicate the root request")
    }

    func testAPlacesReplyFromBeforeDisconnectCannotRepopulateTheSidebar()
        async throws {
        let fixture = try await connectedFixture(holdRoot: true)
        model.connection = try connectedState()
        try await waitUntil("held root request") {
            !fixture.heldRootRequests.isEmpty
        }
        model.connection = .disconnected
        fixture.holdRoot = false
        for request in fixture.heldRootRequests {
            try fixture.guest.send(.fileListing(FileListing(
                id: request.id, path: "", entries: [], more: false,
                cursor: nil, root: "Macintosh HD:")))
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.locations.isEmpty,
                      "the disconnected machine no longer owns the sidebar")
        XCTAssertFalse(model.isDiscoveringLocations)
    }

    private func connectedFixture(holdRoot: Bool = false) async throws
        -> Fixture {
        let fixture = Fixture(
            guest: FakeGuest(port: listener.boundPort ?? 0),
            holdRoot: holdRoot)
        fixture.guest.start()
        try fixture.guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        fixture.guest.onMessage = { [weak self, weak fixture] message in
            guard let self, let fixture else { return }
            switch message {
            case .fileList(let request):
                if request.path.isEmpty {
                    fixture.rootRequests += 1
                    if fixture.holdRoot {
                        fixture.heldRootRequests.append(request)
                    } else {
                        try? fixture.guest.send(.fileListing(FileListing(
                            id: request.id, path: "",
                            entries: [self.entry(fixture.listingItem)],
                            more: false, cursor: nil,
                            root: "Macintosh HD:")))
                    }
                } else {
                    try? fixture.guest.send(.fileRefuse(FileRefuse(
                        id: request.id, code: "no-such-folder",
                        reason: "not here")))
                }
            case .softwareList(let request):
                fixture.softwareRequests += 1
                try? fixture.guest.send(.softwareListing(SoftwareListing(
                    id: request.id, domain: request.domain, entries: [],
                    more: false, cursor: nil, note: nil)))
            default:
                break
            }
        }
        return fixture
    }

    private func connectedState() throws -> GuestConnectionState {
        .connected(name: "PowerBook 1400",
                   key: try XCTUnwrap(listener.activeKey))
    }

    private func entry(_ n: Int) -> FileEntry {
        FileEntry(name: "item-\(n)", kind: "file", fileType: "TEXT",
                  creator: "ttxt", dataBytes: 10, rsrcBytes: 0,
                  modified: nil, identity: "id-\(n)")
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

    private final class Fixture {
        let guest: FakeGuest
        var listingItem = 1
        var softwareRequests = 0
        var rootRequests = 0
        var holdRoot: Bool
        var heldRootRequests: [FileList] = []

        init(guest: FakeGuest, holdRoot: Bool) {
            self.guest = guest
            self.holdRoot = holdRoot
        }
    }
}
