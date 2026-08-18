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

    // MARK: - The toggle is the only place that may prompt

    /// `setEnabled(true)` is the one call site allowed to ask for Screen
    /// Recording — never a refresh, and never page load. This is the store
    /// half of that rule; `testRequestAccessIfNeededOnlyAsksWhenNotAlreadyGranted`
    /// below is the capture-source half.
    func testSetEnabledTrueRequestsAccessButRefreshNeverDoes() async {
        let hosts = FakeHostCapture()
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)

        XCTAssertEqual(hosts.accessRequests, 0)
        store.setEnabled(true)
        XCTAssertEqual(hosts.accessRequests, 1)

        await store.refresh(hosts: [studio])
        await store.refresh(hosts: [studio])
        XCTAssertEqual(hosts.accessRequests, 1,
                       "a refresh must never itself request access")
    }

    func testSetEnabledFalseNeverRequestsAccess() {
        let hosts = FakeHostCapture()
        let store = ContinuityDisplayPreviewStore(hostSource: hosts,
                                                   defaults: nil)
        store.setEnabled(false)
        XCTAssertEqual(hosts.accessRequests, 0)
    }

    // MARK: - Preflight is the authority

    /// `ContinuityScreenCaptureKitSource.captureHostDisplay` refuses BEFORE
    /// attempting any real capture when preflight says no — the note and
    /// deep link render instead of a thumbnail, not after one comes back
    /// suspicious.
    func testCaptureRefusesImmediatelyWhenPreflightIsFalse() async {
        let source = ContinuityScreenCaptureKitSource(
            authorization: FakeScreenRecordingAuthorization(granted: false))

        do {
            _ = try await source.captureHostDisplay(id: 1, maxPixelWidth: 100)
            XCTFail("expected screenRecordingDenied")
        } catch ContinuityPreviewError.screenRecordingDenied {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // Not just that the error came back - that it came back BEFORE any
        // real capture was attempted. On a machine whose own Screen
        // Recording state also happens to be denied, a broken (removed)
        // gate would still throw the same error, just later - this is the
        // assertion that actually distinguishes the two.
        XCTAssertFalse(source.attemptedRealCapture,
                       "must refuse before any real capture attempt")
    }

    /// The one-shot rule, on the capture source itself: already granted
    /// means `requestAccessIfNeeded` is a no-op, because
    /// `CGRequestScreenCaptureAccess` re-asking a person who already said
    /// yes is exactly the unwanted-prompt failure mode this seam exists to
    /// avoid.
    func testRequestAccessIfNeededOnlyAsksWhenNotAlreadyGranted() {
        let notGranted = FakeScreenRecordingAuthorization(granted: false)
        ContinuityScreenCaptureKitSource(authorization: notGranted)
            .requestAccessIfNeeded()
        XCTAssertEqual(notGranted.requestCount, 1)

        let alreadyGranted = FakeScreenRecordingAuthorization(granted: true)
        ContinuityScreenCaptureKitSource(authorization: alreadyGranted)
            .requestAccessIfNeeded()
        XCTAssertEqual(alreadyGranted.requestCount, 0,
                       "already granted - no need to ask again")
    }

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

    // MARK: - The silent-black tell

    /* The defect the black-frame check exists for: ScreenCaptureKit and
       CGDisplayCreateImage are both TCC-gated the same way Accessibility is
       (docs/open-issues.md, the 2026-08-15 arc) — bound to a COPY on disk,
       re-checked lazily — so a grant revoked mid-session, or a launch from
       a copy TCC never approved, can come back a perfectly valid CGImage
       that is uniformly black, with no thrown error at all. That is the
       exact silent-black rendering this whole preview feature exists to
       never do, and it is the one failure mode `note.message` alone cannot
       catch because nothing THROWS to produce a note. */
    func testIsEffectivelyBlackDetectsAUniformlyBlackCapture() {
        let black = Self.solidImage(width: 40, height: 30,
                                    red: 0, green: 0, blue: 0)
        XCTAssertTrue(ContinuityScreenCaptureKitSource.isEffectivelyBlack(black))
    }

    func testIsEffectivelyBlackIsFalseForAnOrdinaryCapture() {
        // A real desktop is never uniformly (0,0,0) - wallpaper, icons and
        // the menu bar all put SOME colour on screen.
        let real = Self.solidImage(width: 40, height: 30,
                                   red: 128, green: 64, blue: 200)
        XCTAssertFalse(ContinuityScreenCaptureKitSource.isEffectivelyBlack(real))
    }

    /// A single stray non-black pixel BELOW the excluded top strip is
    /// enough to disqualify "uniformly black" — this is the check that
    /// would catch a mutation loosening the sample loop to an
    /// early-exit-on-first-pixel or similar shortcut. (Placed at the
    /// BOTTOM corner, deliberately: the top corner is exactly what
    /// `testMenuBarOnlyFrameStillCountsAsEffectivelyBlack` below proves is
    /// excluded on purpose.)
    func testIsEffectivelyBlackIsFalseWhenOnlyOneCornerHasColour() {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 7, y: 0, width: 1, height: 1))
        let image = context.makeImage()!

        XCTAssertFalse(ContinuityScreenCaptureKitSource.isEffectivelyBlack(image))
    }

    /* THE defect this test exists to name: Michelle's 2026-08-16 screenshot
       showed the host tile black except for a lit strip across the top —
       exactly the OS's own "Screen Recording denied" placeholder (chrome
       and this app's self-capture-exempt windows only, everything else
       black). The whole-frame version of `isEffectivelyBlack` sampled that
       lit strip along with everything else, so ANY non-zero pixel in it —
       which a real menu bar always has — made the check report "not
       black" and the permission path never fired: a denied capture with a
       menu bar sailed through as if it were content. Watched failing
       against the OLD (unexcluded) implementation before the exclusion was
       added, by temporarily reverting the skip and confirming this
       assertion flipped to failing. */
    func testMenuBarOnlyFrameStillCountsAsEffectivelyBlack() {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        // The menu bar: a lit strip across the very top of the frame.
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 7, width: 8, height: 1))
        let image = context.makeImage()!

        XCTAssertTrue(ContinuityScreenCaptureKitSource.isEffectivelyBlack(image),
                      "a frame that is black except the menu-bar strip is "
                      + "still effectively black — the permission path "
                      + "must fire for it")
    }

    /// Black with full transparency is still the same tell: a fully
    /// transparent capture is exactly as uninformative as an opaque black
    /// one, and this asserts the alpha channel is deliberately excluded
    /// from the "has colour" test rather than accidentally saving it.
    func testIsEffectivelyBlackIgnoresAlphaAndOnlyLooksAtColour() {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!

        XCTAssertTrue(ContinuityScreenCaptureKitSource.isEffectivelyBlack(image))
    }

    private static func solidImage(width: Int, height: Int, red: UInt8,
                                   green: UInt8, blue: UInt8) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                             blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
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
    private(set) var accessRequests = 0
    private let failure: ContinuityPreviewError?

    init(failure: ContinuityPreviewError? = nil) { self.failure = failure }

    func requestAccessIfNeeded() { accessRequests += 1 }

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

/// Stands in for `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess`
/// — the real calls have a process-wide side effect (one shows a system
/// dialog) a test must never invoke.
private final class FakeScreenRecordingAuthorization: ScreenRecordingAuthorization,
    @unchecked Sendable {
    var granted: Bool
    private(set) var requestCount = 0

    init(granted: Bool) { self.granted = granted }

    func isGranted() -> Bool { granted }

    func requestAccess() {
        requestCount += 1
        granted = true
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
