import AppKit
import CoreGraphics
import XCTest
@testable import Host

@MainActor
final class ContinuityDisplayPreviewTests: XCTestCase {
    private let studio = HostDisplayDescriptor(
        id: 41, name: "Studio Display",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
    private let builtIn = HostDisplayDescriptor(
        id: 42, name: "Built-in Retina Display",
        frame: CGRect(x: 1440, y: 0, width: 982, height: 638),
        pixelSize: CGSize(width: 3024, height: 1964), isPrimary: false)

    func testEachHostDisplayGetsItsOwnStill() async {
        let hosts = FakeHostCapture()
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)
        store.setEnabled(true)

        await store.refresh(hosts: [studio, builtIn])

        XCTAssertEqual(Set(store.hostPreviews.keys), [41, 42])
        XCTAssertEqual(hosts.requested, [41, 42])
        XCTAssertNil(store.note)
        // Stills are downscaled before they are kept: the tiles are tiny and
        // a retained 5120-wide capture per display is pure resident cost.
        XCTAssertEqual(hosts.requestedWidths,
                       [ContinuityDisplayPreviewStore.maxPreviewPixelWidth,
                        ContinuityDisplayPreviewStore.maxPreviewPixelWidth])
    }

    /* The failure this whole seam exists to avoid is a black rectangle, which
       reads identically to a display that is genuinely dark. A denial must
       leave NO images and a NAMED note. */
    func testDeniedScreenRecordingFallsBackToFlatFillsWithANamedNote() async {
        let hosts = FakeHostCapture(
            failure: .screenRecordingDenied)
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)
        store.setEnabled(true)

        await store.refresh(hosts: [studio, builtIn])

        XCTAssertTrue(store.hostPreviews.isEmpty)
        XCTAssertEqual(store.note, .screenRecordingDenied)
        XCTAssertEqual(store.note?.message,
                       "Screen Recording permission needed for previews")
        // One denial answers for the whole sweep - asking per display would
        // only buy more chances to prompt.
        XCTAssertEqual(hosts.requested, [41])
    }

    func testAnOrdinaryCaptureFailureIsNamedButNotBlamedOnPermission() async {
        let hosts = FakeHostCapture(failure: .captureFailed)
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)
        store.setEnabled(true)

        await store.refresh(hosts: [studio])

        XCTAssertTrue(store.hostPreviews.isEmpty)
        XCTAssertEqual(store.note, .captureFailed)
        XCTAssertNotEqual(store.note, .screenRecordingDenied)
    }

    func testNoGuestConnectedLeavesTheFlatGuestTileAndNoNote() async {
        let store = ContinuityDisplayPreviewStore(
            hostSource: FakeHostCapture(), guestSource: FakeGuestCapture(image: nil),
            defaults: nil)
        store.setEnabled(true)

        await store.refresh(hosts: [studio])

        XCTAssertNil(store.guestPreview)
        XCTAssertNil(store.note, "an absent guest is not a preview failure")
    }

    func testConnectedGuestContributesItsOwnStill() async {
        let guest = FakeGuestCapture(image: Self.image(width: 640, height: 480))
        let store = ContinuityDisplayPreviewStore(
            hostSource: FakeHostCapture(), guestSource: guest, defaults: nil)
        store.setEnabled(true)

        await store.refresh(hosts: [studio])

        XCTAssertNotNil(store.guestPreview)
        XCTAssertEqual(guest.calls, 1)
    }

    // MARK: - The toggle

    /// The default-off gate. This is the mutation-watched test: the guard in
    /// `refresh` is the only thing standing between opening the arranger and
    /// ScreenCaptureKit asking TCC for Screen Recording.
    func testPreviewsAreOffByDefaultAndRequestNothing() async {
        let hosts = FakeHostCapture()
        let guest = FakeGuestCapture(image: Self.image(width: 640, height: 480))
        let store = ContinuityDisplayPreviewStore(
            hostSource: hosts, guestSource: guest, defaults: nil)

        XCTAssertFalse(store.enabled)
        await store.refresh(hosts: [studio, builtIn])

        XCTAssertTrue(hosts.requested.isEmpty)
        XCTAssertEqual(guest.calls, 0)
        XCTAssertTrue(store.hostPreviews.isEmpty)
        XCTAssertNil(store.guestPreview)
        XCTAssertNil(store.note)
    }

    func testEnablingThenRefreshingRequestsStills() async {
        let hosts = FakeHostCapture()
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)

        store.setEnabled(true)
        await store.refresh(hosts: [studio, builtIn])

        XCTAssertEqual(hosts.requested, [41, 42])
        XCTAssertEqual(Set(store.hostPreviews.keys), [41, 42])
    }

    func testDisablingClearsHeldImages() async {
        let hosts = FakeHostCapture()
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)
        store.setEnabled(true)
        await store.refresh(hosts: [studio])
        XCTAssertFalse(store.hostPreviews.isEmpty)

        store.setEnabled(false)

        XCTAssertTrue(store.hostPreviews.isEmpty)
        XCTAssertNil(store.guestPreview)
        XCTAssertNil(store.note)

        // And it stays off: a refresh call after disabling requests nothing.
        await store.refresh(hosts: [studio])
        XCTAssertEqual(hosts.requested, [41], "no second request after being disabled")
    }

    func testPreferenceIsPersistedPerDefaultsSuite() {
        let suite = "ContinuityDisplayPreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        ContinuityDisplayPreviewStore(hostSource: FakeHostCapture(),
                                       defaults: defaults).setEnabled(true)

        let restored = ContinuityDisplayPreviewStore(
            hostSource: FakeHostCapture(), defaults: defaults)
        XCTAssertTrue(restored.enabled)
    }

    func testDownscaleShrinksToTheRequestedWidthAndKeepsAspect() {
        let large = Self.image(width: 5120, height: 2880)

        let small = ContinuityScreenCaptureKitSource.downscaled(
            large, maxPixelWidth: 480)

        XCTAssertEqual(small.width, 480)
        XCTAssertEqual(small.height, 270)
        // Already-small images are passed through rather than re-rendered.
        let tiny = Self.image(width: 100, height: 50)
        XCTAssertEqual(
            ContinuityScreenCaptureKitSource.downscaled(tiny, maxPixelWidth: 480)
                .width, 100)
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }
}

@MainActor
private final class FakeHostCapture: ContinuityHostScreenCapturing {
    private(set) var requested: [CGDirectDisplayID] = []
    private(set) var requestedWidths: [CGFloat] = []
    private let failure: ContinuityPreviewError?

    init(failure: ContinuityPreviewError? = nil) { self.failure = failure }

    func captureHostDisplay(id: CGDirectDisplayID,
                            maxPixelWidth: CGFloat) async throws -> CGImage {
        requested.append(id)
        requestedWidths.append(maxPixelWidth)
        if let failure { throw failure }
        let context = CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }
}

@MainActor
private final class FakeGuestCapture: ContinuityGuestScreenCapturing {
    private let image: CGImage?
    private(set) var calls = 0

    init(image: CGImage?) { self.image = image }

    func captureGuestScreen() async throws -> CGImage? {
        calls += 1
        return image
    }
}
