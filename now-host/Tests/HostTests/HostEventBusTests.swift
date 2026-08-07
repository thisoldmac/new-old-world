import AppKit
import XCTest
@testable import Host

/// The bus itself: who hears what, and — the half that matters on a desk
/// with two Macs on the wire — who does NOT.
///
/// Every guard below was watched to fail. The mutations are named beside
/// the tests they belong to, because "this test passes" says nothing about
/// a filter that was never exercised: the scoping tests all pass against a
/// bus that delivers everything to everybody unless the assertion is the
/// negative one.
@MainActor
final class HostEventBusTests: XCTestCase {
    private var bus: HostEventBus!
    private let mac = GuestKey.synthetic("pb1400c")
    private let other = GuestKey.synthetic("pb180c")

    override func setUp() {
        bus = HostEventBus()
    }

    // MARK: - Fan-out

    /// One event, every subscriber. The mechanism the whole file rests on:
    /// the old shape had one hook per fact and so exactly one listener.
    /// (Mutation: deliver to `subscribers.values.first` — this fails, the
    /// scoping tests below do not.)
    func testEverySubscriberHearsOneEvent() {
        var heard = [0, 0, 0]
        var watches: [HostEventSubscription] = []
        for index in 0..<3 {
            watches.append(bus.subscribe { _ in heard[index] += 1 })
        }
        bus.publish(.rosterChanged)
        XCTAssertEqual(heard, [1, 1, 1])
        XCTAssertEqual(watches.count, 3)
    }

    func testAReleasedSubscriptionStopsHearing() {
        var heard = 0
        var watch: HostEventSubscription? = bus.subscribe { _ in heard += 1 }
        XCTAssertNotNil(watch)
        bus.publish(.rosterChanged)
        // The AnyCancellable shape: nothing holds it, so nothing is
        // subscribed. A model that outlives its page relies on this.
        watch = nil
        bus.publish(.rosterChanged)
        XCTAssertEqual(heard, 1, "a subscription nobody holds is gone")
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testUnsubscribingIsImmediateAndIdempotent() {
        var heard = 0
        let watch = bus.subscribe { _ in heard += 1 }
        watch.unsubscribe()
        watch.unsubscribe()
        bus.publish(.rosterChanged)
        XCTAssertEqual(heard, 0)
    }

    /// A handler that publishes while being delivered to — a page that
    /// refreshes, which settles a request, which moves state — must not
    /// re-enter the fan-out. Otherwise the second event reaches half the
    /// subscribers before the first reaches the rest.
    ///
    /// (Mutation: publish recursively instead of queueing. The order comes
    /// back `["a:1", "b:1", "a:2", "b:2"]` reversed at the tail — b hears
    /// the inner event before a hears the outer one — and this fails.)
    func testAPublishFromInsideDeliveryQueuesBehindIt() {
        var order: [String] = []
        var again = true
        let first = bus.subscribe { [weak bus] event in
            order.append("a:\(Self.tag(event))")
            if again, case .rosterChanged = event {
                again = false
                bus?.publish(.focusChanged(to: nil))
            }
        }
        let second = bus.subscribe { event in
            order.append("b:\(Self.tag(event))")
        }
        bus.publish(.rosterChanged)
        XCTAssertEqual(order, ["a:roster", "b:roster", "a:focus", "b:focus"])
        first.unsubscribe()
        second.unsubscribe()
    }

    // MARK: - Guest scoping

    /// The rule this host needs most: an event about one Mac never repaints
    /// a page showing another.
    ///
    /// (Mutation: make `subscribe(scopedTo:)` ignore its filter and call
    /// `subscribe` — this fails on the second assertion. The fan-out tests
    /// above stay green, which is why this one exists separately.)
    func testAnEventAboutAnotherMacIsNotDelivered() {
        var heard: [HostEvent] = []
        let watch = bus.subscribe(scopedTo: { [mac] in mac }) {
            heard.append($0)
        }
        bus.publish(.processListChanged(mac))
        XCTAssertEqual(heard.count, 1, "its own machine's event arrives")
        bus.publish(.processListChanged(other))
        XCTAssertEqual(heard.count, 1,
                       "the other Mac's event must not repaint this page")
        watch.unsubscribe()
    }

    /// The focus is read at delivery. A page that is re-pointed at another
    /// Mac starts hearing that Mac immediately, and stops hearing the one it
    /// left — a filter that closed over the key at subscription time would
    /// get this exactly backwards.
    ///
    /// (Mutation: capture `focus()` once into a `let` at subscribe time —
    /// this fails; nothing else in the file does.)
    func testScopingFollowsTheFocusRatherThanTheSubscription() {
        var focus: GuestKey? = mac
        var heard = 0
        let watch = bus.subscribe(scopedTo: { focus }) { _ in heard += 1 }
        bus.publish(.processListChanged(other))
        XCTAssertEqual(heard, 0)
        focus = other
        bus.publish(.processListChanged(other))
        XCTAssertEqual(heard, 1, "the page moved; its events moved with it")
        bus.publish(.processListChanged(mac))
        XCTAssertEqual(heard, 1, "and the Mac it left went quiet")
        watch.unsubscribe()
    }

    /// A page with no Mac selected has nothing it could truthfully repaint,
    /// so a guest-scoped event while focused on nothing is dropped rather
    /// than treated as "any machine".
    func testAScopedSubscriberFocusedOnNothingHearsNoMachine() {
        var heard = 0
        let watch = bus.subscribe(scopedTo: { nil }) { _ in heard += 1 }
        bus.publish(.captureArrived(mac, Self.delivery()))
        XCTAssertEqual(heard, 0)
        bus.publish(.rosterChanged)
        XCTAssertEqual(heard, 1, "host-wide events still arrive")
        watch.unsubscribe()
    }

    /// Host-wide events are not guest events wearing a nil. Every case that
    /// is about this side of the wire reaches every subscriber whatever it
    /// is focused on, and the focus change itself is one of them —
    /// filtering it by the focus it announces would mean nobody heard it.
    func testHostWideEventsCarryNoMachineAndReachEveryone() {
        XCTAssertNil(HostEvent.rosterChanged.guest)
        XCTAssertNil(HostEvent.linkStateChanged(.idle).guest)
        XCTAssertNil(HostEvent.focusChanged(to: mac).guest,
                     "a scoped page finds out it moved from this event")
        var heard = 0
        let watch = bus.subscribe(scopedTo: { [mac] in mac }) { _ in
            heard += 1
        }
        bus.publish(.focusChanged(to: other))
        XCTAssertEqual(heard, 1)
        watch.unsubscribe()
    }

    /// Every guest-scoped case reports the machine it was built with. The
    /// guard against a case being added with its key in the wrong position,
    /// or `guest` gaining a `default:` that swallows the next one.
    func testEveryGuestScopedCaseReportsItsMachine() {
        let cases: [HostEvent] = [
            .guestConnected(mac),
            .guestDisconnected(mac, reason: "the wire dropped"),
            .guestRenamed(mac, id: GuestID("pb1400c")!),
            .captureArrived(mac, Self.delivery()),
            .streamFrame(mac, Self.delivery()),
            .streamStateChanged(mac, id: 3),
            .transferProgressed(mac, received: 1, expected: 2),
            .transferEnded(mac),
            .fileReceived(mac, url: URL(fileURLWithPath: "/tmp/a"),
                          bytes: 1, guestName: "PowerBook"),
            .fileTreeChanged(mac, side: .guest, path: "Disk:Folder"),
            .processListChanged(mac),
            .guestReportedError(mac, ErrorMessage(
                id: nil, code: "not-implemented", message: "no")),
        ]
        for event in cases {
            XCTAssertEqual(event.guest, mac, "\(event) lost its machine")
        }
    }

    // MARK: - What the listener publishes

    /// The listener's own state is the truth, and moving it announces
    /// itself. Published from `didSet` rather than from the functions that
    /// assign it, so this holds for an assignment nobody has written yet.
    func testMovingTheLinkStatePublishesOnce() async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var states: [GuestListener.State] = []
        let watch = listener.events.subscribe { event in
            if case .linkStateChanged(let state) = event {
                states.append(state)
            }
        }
        defer { watch.unsubscribe(); listener.stop() }
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = listener.state { return true }
            return false
        }
        XCTAssertEqual(states.count, 1, "one move, one event")
        if case .listening = states[0] {} else {
            XCTFail("expected the listening state, got \(states[0])")
        }
    }

    /// A machine arriving announces itself twice, and the two mean
    /// different things: it is HERE (`guestConnected`) and it is the one
    /// being driven (`focusChanged`). The second is what re-points every
    /// guest-scoped page; the first is not, because a second Mac dialling
    /// in must not move the window off the one somebody is using.
    ///
    /// (Mutation: drop the `guestConnected` publish — this fails naming it.
    /// Nothing in the bus-only tests above notices.)
    func testAMachineArrivingIsAnnouncedAndTakesTheFocus() async throws {
        let (listener, guest) = try await connectedListener()
        defer { listener.stop() }
        var events: [HostEvent] = []
        let watch = listener.events.subscribe { events.append($0) }
        defer { watch.unsubscribe() }

        // A SECOND machine, so the first is already focused: the arrival is
        // announced, and the focus does not move off the Mac in use.
        let second = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        second.start()
        try second.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 180c", os: "7.5", chunk: 8192)))
        try await waitUntil("two guests") { listener.guests.count == 2 }

        let arrived = events.compactMap { event -> GuestKey? in
            guard case .guestConnected(let key) = event else { return nil }
            return key
        }
        XCTAssertEqual(arrived.count, 1, "the second machine announced itself")
        XCTAssertFalse(events.contains { event in
            if case .focusChanged = event { return true }
            return false
        }, "a second Mac arriving must not move the window off the first")
        XCTAssertTrue(events.contains { event in
            if case .rosterChanged = event { return true }
            return false
        }, "the roster grew and said so")
        _ = guest
    }

    // MARK: - Fixtures

    private static func tag(_ event: HostEvent) -> String {
        switch event {
        case .rosterChanged: return "roster"
        case .focusChanged: return "focus"
        default: return "other"
        }
    }

    private static func delivery() -> GuestListener.CaptureDelivery {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        return GuestListener.CaptureDelivery(
            image: rep.cgImage!,
            format: CaptureFormat(width: 2, height: 2, depth: 8, rowBytes: 2,
                                  bytes: 4, paletteBytes: 0, packed: false,
                                  captureMs: 1, encodeMs: 1),
            transferMs: 1, wireBytes: 4)
    }
}
