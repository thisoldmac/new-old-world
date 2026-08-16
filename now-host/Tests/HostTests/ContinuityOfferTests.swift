import Network
import XCTest
@testable import Host

/// The host→guest half of cross-edge file drag: publishing `continuity.offer`
/// and serving the guest's inverted `continuity.grab` for it — the mirror of
/// `HostServingTests`' ordinary file pulls, over the same real loopback wire
/// so this exercises dispatch and lifetime together, not just the service in
/// isolation.
@MainActor
final class ContinuityOfferTests: XCTestCase {
    private var listener: GuestListener!
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-offer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
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

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Publishing

    func testPublishingAnOfferSendsItemFactsOnTheWire() async throws {
        let file = try write("Notes.txt", "one\ntwo\n")
        let guest = try await connectedGuest()
        let key = try XCTUnwrap(listener.activeKey)

        let item = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 1, fileAt: file)
        XCTAssertEqual(item.name, "Notes.txt")
        XCTAssertNil(item.nameAdjusted, "an already-legal name crosses unchanged")

        try await waitUntil("continuity.offer") {
            guest.received.contains { if case .continuityOffer = $0 { return true }
                                      else { return false } }
        }
        guard case .continuityOffer(let offer)? = guest.received.last(where: {
            if case .continuityOffer = $0 { return true } else { return false }
        }) else { return XCTFail("no offer") }
        XCTAssertEqual(offer.epoch, 9)
        XCTAssertEqual(offer.generation, 1)
        XCTAssertEqual(offer.item?.name, "Notes.txt")
        XCTAssertEqual(offer.item?.fileType, "TEXT")
        XCTAssertEqual(offer.item?.isFolder, false)
    }

    func testClearingAnOfferSendsAnAbsentItem() async throws {
        let file = try write("Notes.txt", "hi")
        let guest = try await connectedGuest()
        let key = try XCTUnwrap(listener.activeKey)
        _ = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 1, fileAt: file)
        listener.clearContinuityOffer(guestKey: key, epoch: 9, generation: 2)

        try await waitUntil("the clearing offer") {
            guest.received.contains {
                if case .continuityOffer(let o) = $0 { return o.generation == 2 }
                return false
            }
        }
        guard case .continuityOffer(let offer)? = guest.received.last(where: {
            if case .continuityOffer = $0 { return true } else { return false }
        }) else { return XCTFail("no offer") }
        XCTAssertNil(offer.item, "a fresh generation with no item tears "
            + "down whatever the guest was drawing")
    }

    // MARK: - The inverted grab

    func testGuestCanGrabThePublishedOffer() async throws {
        let file = try write("Notes.txt", "one\ntwo\n")
        let guest = try await connectedGuest()
        let key = try XCTUnwrap(listener.activeKey)
        _ = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 1, fileAt: file)

        try guest.send(.continuityGrab(ContinuityGrab(
            version: 4, id: 41, epoch: 9, generation: 1, container: nil)))
        try await waitUntil("the transfer to end") {
            guest.received.contains { if case .fileEnd = $0 { return true }
                                      else { return false } }
        }
        guard case .fileBegin(let begin)? = guest.received.first(where: {
            if case .fileBegin = $0 { return true } else { return false }
        }) else { return XCTFail("no begin") }
        XCTAssertEqual(begin.id, 41)
        XCTAssertEqual(begin.name, "Notes.txt")
        XCTAssertEqual(begin.bytes, guest.bulkReceived.count)
        XCTAssertEqual(String(data: guest.bulkReceived, encoding: .macOSRoman),
                       "one\rtwo\r", "line endings the classic Mac reads")
        XCTAssertFalse(guest.received.contains {
            if case .fileRefuse = $0 { return true } else { return false }
        })
    }

    func testAGrabForAnEpochThisMacDidNotOfferIsRefusedBadEpoch() async throws {
        let file = try write("Notes.txt", "hi")
        let guest = try await connectedGuest()
        let key = try XCTUnwrap(listener.activeKey)
        _ = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 1, fileAt: file)

        try guest.send(.continuityGrab(ContinuityGrab(
            version: 4, id: 42, epoch: 10, generation: 1, container: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.id, 42)
        XCTAssertEqual(refuse.code, "bad-epoch")
    }

    func testAGrabForAnOlderGenerationIsRefusedStaleSelection() async throws {
        let fileA = try write("A.txt", "a")
        let fileB = try write("B.txt", "b")
        let guest = try await connectedGuest()
        let key = try XCTUnwrap(listener.activeKey)
        _ = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 1, fileAt: fileA)
        _ = try listener.publishContinuityOffer(
            guestKey: key, epoch: 9, generation: 2, fileAt: fileB)

        try guest.send(.continuityGrab(ContinuityGrab(
            version: 4, id: 43, epoch: 9, generation: 1, container: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.code, "stale-selection")
    }

    func testAGrabWithNothingPublishedIsRefusedNoSelection() async throws {
        let guest = try await connectedGuest()
        try guest.send(.continuityGrab(ContinuityGrab(
            version: 4, id: 44, epoch: 1, generation: 1, container: nil)))
        try await waitUntil("a refusal") {
            guest.received.contains { if case .fileRefuse = $0 { return true }
                                      else { return false } }
        }
        guard case .fileRefuse(let refuse)? = guest.received.last(where: {
            if case .fileRefuse = $0 { return true } else { return false }
        }) else { return XCTFail("no refusal") }
        XCTAssertEqual(refuse.code, "no-selection")
    }
}

// MARK: - ContinuityOfferService, off the wire

/// The lifetime bound and its refusal in isolation — a fake clock, so the
/// 30s window is proven without a test that sleeps 30 seconds.
@MainActor
final class ContinuityOfferServiceTests: XCTestCase {
    private func plan(_ name: String = "F") -> OutboundFile.Plan {
        OutboundFile.Plan(name: name, container: "data",
                          bytes: Data("x".utf8), fileType: "TEXT",
                          creator: "ttxt", modified: nil, note: nil)
    }

    private func item(_ name: String = "F") -> ContinuityOffer.Item {
        ContinuityOffer.Item(name: name, nameAdjusted: nil, fileType: "TEXT",
                             creator: "ttxt", dataSize: 1, resourceSize: nil,
                             modifiedAt: nil, isFolder: false, icon: nil)
    }

    func testAFreshOfferServesImmediately() {
        let service = ContinuityOfferService()
        let key = GuestKey(machine: GuestID("guest-1")!, session: UUID())
        service.publish(guestKey: key, epoch: 1, generation: 1,
                        url: URL(fileURLWithPath: "/tmp/f"), plan: plan(),
                        item: item())
        guard case .serve = service.grab(guestKey: key, epoch: 1,
                                         generation: 1) else {
            return XCTFail("expected the offer to serve")
        }
    }

    /// The bound is stated in ONE place — `offerLifetimeSeconds` — and this
    /// is the mutation target: change the comparison from `>` to `>=`, or
    /// the constant, and this test must fail.
    func testAnOfferStaysServeableUntilTheBoundThenExpires() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let service = ContinuityOfferService(clock: { now })
        let key = GuestKey(machine: GuestID("guest-1")!, session: UUID())
        service.publish(guestKey: key, epoch: 1, generation: 1,
                        url: URL(fileURLWithPath: "/tmp/f"), plan: plan(),
                        item: item())
        service.endEpoch()

        now = now.addingTimeInterval(
            ContinuityOfferService.offerLifetimeSeconds - 1)
        guard case .serve = service.grab(guestKey: key, epoch: 1,
                                         generation: 1) else {
            return XCTFail("still inside the window")
        }

        now = now.addingTimeInterval(2)
        guard case .refuse(let code, _) = service.grab(
            guestKey: key, epoch: 1, generation: 1) else {
            return XCTFail("expected offer-expired")
        }
        XCTAssertEqual(code, "offer-expired")
    }

    func testANewGenerationEndsThePriorOnesWindowImmediately() {
        let service = ContinuityOfferService()
        let key = GuestKey(machine: GuestID("guest-1")!, session: UUID())
        service.publish(guestKey: key, epoch: 1, generation: 1,
                        url: URL(fileURLWithPath: "/tmp/a"), plan: plan("A"),
                        item: item("A"))
        service.publish(guestKey: key, epoch: 1, generation: 2,
                        url: URL(fileURLWithPath: "/tmp/b"), plan: plan("B"),
                        item: item("B"))
        guard case .refuse(let code, _) = service.grab(
            guestKey: key, epoch: 1, generation: 1) else {
            return XCTFail("the old generation must not still serve")
        }
        XCTAssertEqual(code, "stale-selection")
    }

    func testLinkDroppingEndsTheOfferForThatGuestOnly() {
        let service = ContinuityOfferService()
        let mine = GuestKey(machine: GuestID("guest-1")!, session: UUID())
        let other = GuestKey(machine: GuestID("guest-2")!, session: UUID())
        service.publish(guestKey: mine, epoch: 1, generation: 1,
                        url: URL(fileURLWithPath: "/tmp/f"), plan: plan(),
                        item: item())
        service.linkDropped(guestKey: other)
        XCTAssertNotNil(service.current, "a different guest's link ending "
            + "must not end this one's offer")
        service.linkDropped(guestKey: mine)
        XCTAssertNil(service.current)
    }
}

// MARK: - ClassicName.adjustment

final class ClassicNameAdjustmentTests: XCTestCase {
    func testAnAlreadyLegalNameIsUnadjusted() {
        XCTAssertNil(ClassicName.adjustment(for: "Notes.txt"))
    }

    func testATooLongNameIsTruncated() {
        let long = String(repeating: "a", count: 60) + ".txt"
        XCTAssertEqual(ClassicName.adjustment(for: long), "truncated")
    }

    func testAnUnencodableCharacterIsTransliterated() {
        // Within HFS's 31-byte cap but MacRoman cannot spell an emoji.
        XCTAssertEqual(ClassicName.adjustment(for: "notes🙂.txt"),
                       "transliterated")
    }

    func testBothTooLongAndUnencodableIsBoth() {
        let long = "notes🙂" + String(repeating: "a", count: 40) + ".txt"
        XCTAssertEqual(ClassicName.adjustment(for: long), "both")
    }
}
