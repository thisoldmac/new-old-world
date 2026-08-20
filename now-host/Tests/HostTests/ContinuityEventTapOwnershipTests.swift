import XCTest
import CoreGraphics
@testable import Host

/// **No test process may own a consuming input tap.**
///
/// `AppKitContinuityKeyboardEnvironment` builds a session-wide CONSUMING
/// `CGEventTap`, which puts its process in front of every keystroke on the
/// Mac. The running app services that tap's mach port off its main runloop in
/// milliseconds. An `xctest` process does not: its main thread is inside a
/// test, the port goes unserviced, and the window server waits out the tap's
/// timeout for every key the person at the keyboard presses.
///
/// It shipped that way. `ContinuityEdgeController` defaulted its keyboard
/// environment to the AppKit one, thirty-two of the suite's thirty-nine
/// constructions named a pointer stub and let the keyboard default, and any
/// of them that drove the pointer across the edge installed the real tap.
/// `CGGetEventTapList` caught it mid-run holding 5.6 seconds of average
/// latency — a suite that froze the human's typing for as long as it ran.
///
/// The guard asks the WINDOW SERVER rather than our own source, because the
/// property is about what this process owns, not about which line created it:
/// the pointer environment builds a consuming tap too, and a future default
/// that reaches either one fails here.
@MainActor
final class ContinuityEventTapOwnershipTests: XCTestCase {
    func testDrivingTheEdgeActiveInstallsNoConsumingTap() {
        XCTAssertEqual(consumingTapsOwnedByThisProcess(), [],
                       "a tap was already live before this test ran")

        let layout = ContinuityDisplayLayout(
            hostDisplays: [HostDisplayDescriptor(
                id: 41, name: "Studio Display",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pixelSize: CGSize(width: 2880, height: 1800),
                isPrimary: true)],
            guestSize: CGSize(width: 800, height: 600),
            defaults: nil, observeScreens: false)
        let driver = ContinuityEdgeControllerTests.Driver()
        let environment = ContinuityEdgeControllerTests.Environment()
        /* Deliberately NO `keyboardEnvironment:` — this reproduces what
           thirty-two constructions in this suite do. */
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { _, _ in })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 3, y: 0), buttonsDown: false))
        controller.transportPhaseChanged(.active)
        /* The plane must be armed for this to mean anything: keyboard
           capture starts on the way into `.active`, so a controller left in
           `.arming` would hold no tap for a reason that has nothing to do
           with the property under test. */
        XCTAssertEqual(controller.state, .active,
                       "the edge never went active; this run tested nothing")

        XCTAssertEqual(
            consumingTapsOwnedByThisProcess(), [],
            """
            This test process now owns a consuming CGEventTap. Whatever \
            installed it stands in front of every keystroke on this Mac for \
            as long as the suite runs, and the person at the keyboard sees \
            typing stall or vanish. Inject an environment stub; the real tap \
            belongs to the running app alone.
            """)
    }

    /// The masks of every consuming tap this process owns, as hex, so a
    /// failure names WHICH events were taken rather than only that one was.
    private func consumingTapsOwnedByThisProcess() -> [String] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var taps = [CGEventTapInformation](repeating: .init(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else {
            return []
        }
        let mine = pid_t(ProcessInfo.processInfo.processIdentifier)
        return taps.prefix(Int(count))
            .filter { $0.tappingProcess == mine
                && $0.options == .defaultTap }
            .map { String(format: "0x%llx", $0.eventsOfInterest) }
    }
}
