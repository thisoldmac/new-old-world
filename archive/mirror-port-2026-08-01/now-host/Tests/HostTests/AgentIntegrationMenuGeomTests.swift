import XCTest
@testable import Host
import NOWAgentIntegration

/// **`menugeom`'s own wire lane** — read outright, like `textget`/`textset`,
/// never through `dispatch()`'s `Dispatch` row (`menugeom` answers no such
/// row; see `AgentIntegrationActControl.menuGeom`'s own comment). This file
/// is the adapter half of lane L7 item 2; `DropdownGeometryTests`
/// (`MirrorKitUITests`) is the consuming half — the renderer's drawing and
/// hit test against a `MirrorKit.MenuGeometry` this file never constructs
/// directly from a fixture, only from what a fake guest answered.
@MainActor
final class AgentIntegrationMenuGeomTests: XCTestCase {
    private static let session = "5b6d9a44-0000-4000-8000-000000000001"

    private func adapter(_ listener: GuestListener) -> AgentIntegrationActControl {
        AgentIntegrationActControl(
            listener: listener,
            currentSessionID: { UUID(uuidString: Self.session) },
            commandTimeout: 5,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            audit: { _, _ in })
    }

    /// The guest's own row shape, exactly as `now_act_run_menugeom` writes
    /// it: `Menu`, `Items`, `Width`, `Height`, then `Item 1`… as
    /// `"top, left, bottom, right"` strings — never reordered here.
    private func reply(menu: Int, width: Int, height: Int,
                       items: [(Int, Int, Int, Int)]) -> [[String]] {
        var rows = [["Menu", "\(menu)"], ["Items", "\(items.count)"],
                    ["Width", "\(width)"], ["Height", "\(height)"]]
        for (i, r) in items.enumerated() {
            rows.append(["Item \(i + 1)", "\(r.0), \(r.1), \(r.2), \(r.3)"])
        }
        return rows
    }

    /// The ordinary case: three items, one of them a real 6px separator —
    /// the exact mismatch this verb exists to answer for — parsed into the
    /// keyed, 1-based-index shape every consumer reads.
    func testParsesTheGuestsRowsIntoAKeyedReceipt() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "menugeom" else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["menugeom": self.reply(
                    menu: 129, width: 100, height: 42,
                    items: [(0, 0, 16, 100), (16, 0, 22, 100),
                           (22, 0, 42, 100)])],
                error: nil)))
        }

        let result = await adapter(listener).menuGeom(.init(menu: 129))

        guard case .completed(let receipt) = result else {
            return XCTFail("a well-formed reply must complete: \(result)")
        }
        XCTAssertEqual(receipt.menu, 129)
        XCTAssertEqual(receipt.width, 100)
        XCTAssertEqual(receipt.height, 42)
        XCTAssertEqual(receipt.items.count, 3)
        XCTAssertEqual(receipt.items[1],
                      .init(top: 16, left: 0, bottom: 22, right: 100),
                      "the separator's own thin rect, not a uniform row")
    }

    /// `serialHi`/`serialLo` cross only when BOTH are given — half a serial
    /// names no process, the same rule `activate`'s own args carry.
    func testSendsBothSerialsOrNeitherNeverHalf() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let seen = Box<[String: String]?>(nil)
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "menugeom" else { return }
            seen.value = request.args
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["menugeom": self.reply(
                    menu: 129, width: 10, height: 10, items: [])],
                error: nil)))
        }

        _ = await adapter(listener).menuGeom(
            .init(menu: 129, serialHi: 0, serialLo: 8421376))

        XCTAssertEqual(seen.value?["serialHi"], "0")
        XCTAssertEqual(seen.value?["serialLo"], "8421376")
    }

    func testHalfASerialIsRefusedBeforeItReachesTheWire() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        let asked = Box(false)
        guest.onMessage = { message in
            if case .commandRequest = message { asked.value = true }
        }

        let result = await adapter(listener).menuGeom(
            .init(menu: 129, serialHi: 0, serialLo: nil))

        XCTAssertFalse(asked.value, "half a serial must never reach the guest")
        guard case .refused = result else {
            return XCTFail("half a serial must be refused: \(result)")
        }
    }

    /// A menu the guest could not find (a stale id, a menu that has since
    /// closed) crosses as the guest's OWN sentence, forwarded rather than
    /// replaced — the same discipline every other act on this lane holds.
    func testAGuestRefusalCrossesInItsOwnWords() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "menugeom" else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: false, output: nil,
                error: .init(code: "now-menu-no-menu",
                            message: "no menu 999 in this process"))))
        }

        let result = await adapter(listener).menuGeom(.init(menu: 999))

        guard case .refused(let failure) = result else {
            return XCTFail("a guest refusal is a refusal: \(result)")
        }
        XCTAssertTrue(failure.message.contains("no menu 999"),
                      "the guest's own sentence, not a replacement: "
                          + failure.message)
    }

    /// A row missing entirely — the extension answered `ok` but the reply
    /// carries no `Item N` for one of the `Items` it claimed — must not be
    /// silently treated as zero items: the count and the array disagreeing
    /// is exactly the shape a truncated or malformed reply takes, and this
    /// side does not draw a menu shorter than the guest actually reported.
    func testAMissingItemRowRefusesRatherThanSilentlyShorteningTheList() async throws {
        let (listener, guest) = try await connectedListener()
        defer { guest.connection.cancel(); listener.stop() }
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "menugeom" else { return }
            try? guest.send(.commandResult(.init(
                id: request.id, ok: true,
                output: ["menugeom": [["Menu", "129"], ["Items", "2"],
                                      ["Width", "100"], ["Height", "32"],
                                      ["Item 1", "0, 0, 16, 100"]]],
                // Item 2 missing entirely, despite Items: 2.
                error: nil)))
        }

        let result = await adapter(listener).menuGeom(.init(menu: 129))

        guard case .refused = result else {
            return XCTFail("a reply that claims 2 items and answers 1 must "
                               + "refuse rather than complete short: \(result)")
        }
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
