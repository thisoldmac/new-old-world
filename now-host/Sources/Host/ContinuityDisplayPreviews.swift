import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/* Previews of the real screens inside the arrangement rectangles, so the
   tiles are recognisably the person's own desks rather than four grey
   rounded rectangles that all look alike.

   Two rules shape everything below. They are STILLS, refreshed on the few
   events that can change them - never a live stream, because a continuously
   running capture of every display to fill a 120-point rectangle is a cost
   nobody asked for. And a capture that cannot happen SAYS SO in the canvas:
   the failure mode this replaces is a black rectangle, which reads exactly
   like a broken preview and exactly like a display that is genuinely dark. */

/// What the arranger can say about a rectangle it could not fill.
enum ContinuityPreviewNote: Equatable, Sendable {
    case screenRecordingDenied
    case captureFailed

    var message: String {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission needed for previews"
        case .captureFailed:
            return "Display previews unavailable"
        }
    }
}

enum ContinuityPreviewError: Error, Equatable {
    /// Distinguished from every other failure because it is the one a person
    /// can act on, and the only one with a name worth putting on screen.
    case screenRecordingDenied
    case captureFailed
}

/// The two shapes of host capture, kept as a value so the CHOICE is testable
/// without a display, a permission grant, or a running compositor.
enum ContinuityDesktopFilterPlan: Equatable, Sendable {
    /// Wallpaper, desktop icons and the menu bar, with every running
    /// application's windows excluded. This is what was asked for: the
    /// arrangement is about screens, and someone else's open windows are
    /// noise in a 120-point tile - as well as the private half of the shot.
    case desktopExcludingApplications
    /// Everything on the display, windows included. Honest fallback for the
    /// OS versions whose still-capture entry point cannot take the filter
    /// above; named rather than silent so a windowed preview is explicable.
    case wholeDisplay
}

@MainActor
protocol ContinuityHostScreenCapturing: AnyObject {
    /// One still of a host display, already downscaled - the caller draws it
    /// into a rectangle a couple of hundred points wide and there is no
    /// reason for a 5120x2880 image to exist for that.
    func captureHostDisplay(id: CGDirectDisplayID,
                            maxPixelWidth: CGFloat) async throws -> CGImage
    /// Fires the one-shot Screen Recording prompt, if TCC has no decision
    /// recorded yet. Call this ONLY from the person's own act of turning
    /// previews on (`ContinuityDisplayPreviewStore.setEnabled(true)`) —
    /// never from a refresh, and never from page load, per the same rule
    /// `AccessibilityAuthorization.promptForTrust` documents: a prompt
    /// nobody asked for is as unhelpful as no prompt.
    func requestAccessIfNeeded()
}

/// Seam over the two Screen Recording TCC calls, the same shape as
/// `AccessibilityAuthorization` and for the same reason: the real calls
/// have process-wide side effects (one shows a system dialog) a test must
/// never invoke for real.
protocol ScreenRecordingAuthorization: Sendable {
    /// Whether this process currently holds Screen Recording access.
    /// Never prompts, never has a side effect. THE authority for whether a
    /// capture should even be attempted — see `SystemScreenRecordingAuthorization`
    /// for why this, and not a capture's own content, is what gates the
    /// attempt.
    func isGranted() -> Bool
    /// Asks macOS to show its Screen Recording prompt when the process has
    /// no TCC decision yet. A one-shot the same way Accessibility's is:
    /// once granted-and-reset even once, this returns silently forever and
    /// no dialog appears again for the install.
    func requestAccess()
}

/// `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`,
/// unwrapped from Core Graphics.
///
/// **Why preflight, and not the capture's own success or failure, is the
/// authority.** The previous version of this file trusted
/// `CGRequestScreenCaptureAccess()`'s return value to decide whether to
/// even attempt a capture, and separately trusted a captured image's own
/// pixel content (`ContinuityScreenCaptureKitSource.isEffectivelyBlack`)
/// to catch what that missed. Both are documented to be unreliable in the
/// same direction: `CGRequestScreenCaptureAccess()` can report `true`
/// once an app merely APPEARS in the Screen Recording list, independent of
/// whether the switch next to it is on, and a denied capture's "safe"
/// placeholder image is not uniformly black — it still draws the menu bar
/// and this app's own windows (self-capture is always allowed), which
/// defeated the 8×8 sampling grid outright (Michelle, 2026-08-16: black
/// host tile, menu bar visible). `CGPreflightScreenCaptureAccess()` is the
/// one call in this pair documented to report the actual TCC decision with
/// no side effect, so it is now the sole gate on whether a capture is
/// attempted at all — checked fresh on every capture, not cached from
/// whatever `requestAccess()` last returned.
struct SystemScreenRecordingAuthorization: ScreenRecordingAuthorization {
    func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestAccess() { _ = CGRequestScreenCaptureAccess() }
}

@MainActor
protocol ContinuityGuestScreenCapturing: AnyObject {
    /// One still of the guest screen, or nil when no guest is connected.
    func captureGuestScreen() async throws -> CGImage?
}

// MARK: - ScreenCaptureKit

@MainActor
final class ContinuityScreenCaptureKitSource: ContinuityHostScreenCapturing {
    /// The filter the still capture actually used, for the canvas to explain
    /// itself and for a person reading a bug report to know which they saw.
    private(set) var plan: ContinuityDesktopFilterPlan = .wholeDisplay
    private let authorization: ScreenRecordingAuthorization
    /// True once this instance has gone past the authorization gate in
    /// `captureHostDisplay` and attempted a real capture. Exists for
    /// `ContinuityDisplayPreviewTests.testCaptureRefusesImmediatelyWhenPreflightIsFalse`:
    /// on a machine whose OWN Screen Recording state also happens to be
    /// denied, a broken (removed) gate would still end up throwing
    /// `screenRecordingDenied` — just later, from the real capture call
    /// instead of the guard — and look identical to the correct behaviour
    /// from the outside. This flag is the only way to prove the refusal
    /// happened BEFORE any capture attempt, independent of what this
    /// machine's actual TCC state is.
    private(set) var attemptedRealCapture = false

    init(authorization: ScreenRecordingAuthorization
            = SystemScreenRecordingAuthorization()) {
        self.authorization = authorization
    }

    func requestAccessIfNeeded() {
        guard !authorization.isGranted() else { return }
        authorization.requestAccess()
    }

    func captureHostDisplay(id: CGDirectDisplayID,
                            maxPixelWidth: CGFloat) async throws -> CGImage {
        /* THE gate. Checked fresh here rather than trusted from whatever
           `requestAccessIfNeeded()` last returned, because a grant can be
           revoked mid-session and because `CGRequestScreenCaptureAccess`'s
           own return value is not reliable evidence (see
           `SystemScreenRecordingAuthorization`'s doc comment). A refusal
           here means no ScreenCaptureKit or CGDisplayCreateImage call is
           ever made — the note-plus-deep-link renders INSTEAD of a
           thumbnail, not after one comes back suspicious. */
        guard authorization.isGranted() else {
            throw ContinuityPreviewError.screenRecordingDenied
        }
        attemptedRealCapture = true

        let image: CGImage
        if #available(macOS 14.0, *) {
            image = try await captureViaScreenshotManager(
                id: id, maxPixelWidth: maxPixelWidth)
        } else {
            /* macOS 13 has SCContentFilter but no one-shot still API to hand
               it to, and standing up an SCStream to keep a single frame costs
               more than this preview is worth. CGDisplayCreateImage is
               TCC-gated the same way, so a denial is still a denial - it
               just cannot drop the windows. */
            plan = .wholeDisplay
            guard let captured = CGDisplayCreateImage(id) else {
                throw ContinuityPreviewError.captureFailed
            }
            image = Self.downscaled(captured, maxPixelWidth: maxPixelWidth)
        }
        /* SECONDARY guard, kept for the one gap preflight cannot close: a
           grant revoked in System Settings mid-session, before this process
           next calls `CGPreflightScreenCaptureAccess`, can still hand back
           a "successful" capture with nothing real in it. This is NOT the
           primary detector any more — the menu bar and this app's own
           on-screen windows are visible even in a denied capture's "safe"
           placeholder image (self-capture is always allowed), which is
           exactly what defeated the old whole-frame version of this check
           (Michelle, 2026-08-16). Sampling starts one row below the top of
           the 8×8 grid so that always-lit menu-bar strip cannot mask an
           otherwise-empty frame. */
        if Self.isEffectivelyBlack(image) {
            throw ContinuityPreviewError.screenRecordingDenied
        }
        return image
    }

    /// Whether a captured still is uniformly black BELOW its top eighth —
    /// the tell for a capture that "succeeded" (no thrown error) but
    /// delivered nothing but chrome, because the TCC decision behind it
    /// went stale between the preflight check and the capture itself. A
    /// real screen's body is never exactly (0,0,0) everywhere: even an
    /// all-black desktop picture still carries icons or a dock. The menu
    /// bar strip (this app's own windows are also always visible,
    /// self-capture being exempt from Screen Recording) is EXCLUDED from
    /// the sample on purpose: it is lit in both a genuine capture and in
    /// the OS's own denied-capture placeholder, so including it makes this
    /// check blind to exactly the failure it exists to catch.
    static func isEffectivelyBlack(_ image: CGImage) -> Bool {
        let side = 8
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // Row 0 is the top eighth of the frame - the menu-bar band on any
        // ordinary display - and is skipped entirely.
        for pixel in side ..< (side * side) {
            let base = pixel * 4
            // Skip the alpha channel (index 3 of each RGBA pixel): a fully
            // transparent black is a different fact from an opaque one, but
            // either way the colour channels being all-zero is the signal.
            if buffer[base] != 0 || buffer[base + 1] != 0
                || buffer[base + 2] != 0 {
                return false
            }
        }
        return true
    }

    @available(macOS 14.0, *)
    private func captureViaScreenshotManager(id: CGDirectDisplayID,
                                             maxPixelWidth: CGFloat)
        async throws -> CGImage {
        let image = try await Self.screenshotManagerCapture(
            id: id, maxPixelWidth: maxPixelWidth)
        plan = .desktopExcludingApplications
        return image
    }

    /* Deliberately nonisolated: SCShareableContent and SCContentFilter are
       not Sendable, and awaiting them from a MainActor method is a send
       some compilers refuse. Keeping the whole ScreenCaptureKit exchange
       off the actor means only the final CGImage crosses back. */
    @available(macOS 14.0, *)
    private nonisolated static func screenshotManagerCapture(
        id: CGDirectDisplayID, maxPixelWidth: CGFloat)
        async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            /* SCShareableContent is the call that fails when the grant is
               missing, so it - not the capture - is where a denial surfaces. */
            throw ContinuityPreviewError.screenRecordingDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == id })
        else { throw ContinuityPreviewError.captureFailed }

        /* Excluding every running application leaves the desktop picture,
           the desktop icons and the menu bar. `exceptingWindows: []` means
           no window earns its way back in.

           REVIEWED 2026-08-16, after Michelle reported the tile rendering
           black with only the menu bar visible: is this filter itself
           hiding the wallpaper? `SCContentFilter(display:excludingApplications:
           exceptingWindows:)` operates on ON-SCREEN WINDOWS belonging to
           the named applications; the desktop picture is compositied by
           the display capture directly and is not owned by any
           `SCRunningApplication`'s window list, so it survives this filter
           regardless of which apps `content.applications` names — this is
           Apple's own documented recipe for a windows-excluded desktop
           still, not a narrower one this file invented. The black tile
           Michelle saw is accounted for without a filter defect: a denied
           capture returns the OS's own "safe" placeholder (chrome and this
           app's self-capture-exempt windows only, everything else black),
           which is exactly what the new preflight gate above now refuses
           to even ask for. Filed as reviewed rather than fixed — there is
           nothing here to fix unless a live permission-granted run shows
           otherwise, which this change could not verify without a Mac to
           grant Screen Recording on. */
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications,
                                     exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        let scale = min(1, maxPixelWidth / max(1, CGFloat(display.width)))
        configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .nominal

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        } catch {
            throw ContinuityPreviewError.captureFailed
        }
    }

    static func downscaled(_ image: CGImage,
                           maxPixelWidth: CGFloat) -> CGImage {
        guard CGFloat(image.width) > maxPixelWidth, maxPixelWidth >= 1,
              let space = image.colorSpace else { return image }
        let scale = maxPixelWidth / CGFloat(image.width)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

// MARK: - The guest's own screen

/// One still of the guest, over the wire the Screen module already uses.
///
/// The lane is SINGLE: `GuestListener.requestCapture` replaces
/// `pendingCapture`, so a second requester leaves the first completion — the
/// Screenshots button's, with a person waiting behind it — never called. A
/// preview is the least important capture in the app, so it declines rather
/// than competing, and the tile falls back to its flat fill.
@MainActor
final class ContinuityGuestListenerCapture: ContinuityGuestScreenCapturing {
    private let listener: GuestListener

    init(listener: GuestListener) { self.listener = listener }

    func captureGuestScreen() async throws -> CGImage? {
        guard listener.activeContinuityTarget != nil,
              !listener.isCapturePending,
              listener.activeStreamId == nil else { return nil }

        let delivery: GuestListener.CaptureDelivery? =
            await withCheckedContinuation { continuation in
                listener.requestCapture(depth: nil) { result in
                    continuation.resume(returning: try? result.get())
                }
            }
        guard let delivery else { return nil }
        return ContinuityScreenCaptureKitSource.downscaled(
            delivery.image,
            maxPixelWidth: ContinuityDisplayPreviewStore.maxPreviewPixelWidth)
    }
}

// MARK: - Store

@MainActor
final class ContinuityDisplayPreviewStore: ObservableObject {
    /// Keyed by `HostDisplayDescriptor.id`, so a tile asks for its own screen
    /// and a display that failed simply has no entry.
    @Published private(set) var hostPreviews: [UInt32: CGImage] = [:]
    @Published private(set) var guestPreview: CGImage?
    /// nil when there is nothing to explain - either every preview arrived,
    /// or nobody has asked for one yet.
    @Published private(set) var note: ContinuityPreviewNote?
    /// Off by default. Screen Recording is a standing grant a person did not
    /// necessarily mean to give this app just by opening the arranger, so
    /// previews stay opt-in: nothing below reaches ScreenCaptureKit, TCC, or
    /// the guest capture lane until this is true.
    @Published private(set) var enabled: Bool

    /// The tiles are small; this is the widest a stored still ever needs to
    /// be. Full-resolution captures are downscaled before they are kept.
    static let maxPreviewPixelWidth: CGFloat = 480

    /// The Screen Recording pane of Privacy & Security — the same deep-link
    /// idiom `SystemAccessibilityAuthorization.settingsURL` already uses for
    /// Accessibility, so both permissions this feature depends on offer the
    /// identical affordance rather than one having a button and the other
    /// only a caption.
    static let screenRecordingSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    private static let enabledKey = "mirror.continuity.displayPreviews"

    private let hostSource: ContinuityHostScreenCapturing?
    private let guestSource: ContinuityGuestScreenCapturing?
    private let defaults: UserDefaults?
    private var refreshing = false
    /// Where this executable is running from — read once, at construction,
    /// the same way `ContinuityEdgeController` reads it for the
    /// Accessibility row. A denied-Screen-Recording note names it when the
    /// copy is somewhere a person would not have granted, for the identical
    /// reason: the pane can say granted while THIS copy has nothing.
    let runningCopy: RunningCopy

    init(hostSource: ContinuityHostScreenCapturing?
            = ContinuityScreenCaptureKitSource(),
         guestSource: ContinuityGuestScreenCapturing? = nil,
         defaults: UserDefaults? = ProductIdentity.defaults,
         runningCopy: RunningCopy = .current) {
        self.hostSource = hostSource
        self.guestSource = guestSource
        self.defaults = defaults
        self.runningCopy = runningCopy
        self.enabled = defaults?.bool(forKey: Self.enabledKey) ?? false
    }

    /// The button's action. A URL open with no TCC state behind it, unlike
    /// `AXIsProcessTrustedWithOptions` — it does the same thing every time
    /// it is pressed, which is exactly why it is the affordance that always
    /// works rather than a one-shot system prompt.
    func openScreenRecordingSettings() {
        guard let url = URL(string: Self.screenRecordingSettingsURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// A store that captures nothing, for the offscreen render gates: those
    /// draw the page without a person present, and the first thing a real
    /// capture does is ask TCC for Screen Recording. A test suite must not
    /// be able to raise that prompt.
    static var capturingNothing: ContinuityDisplayPreviewStore {
        ContinuityDisplayPreviewStore(hostSource: nil, guestSource: nil,
                                      defaults: nil)
    }

    /// The toggle's write path. Turning previews off clears whatever was
    /// held - a stale still of a display that has since changed is worse
    /// than the flat fill previews replaced. Turning on does not itself
    /// capture; the arranger's own refresh triggers on this becoming true,
    /// the same way it triggers on the arrangement changing shape.
    func setEnabled(_ isEnabled: Bool) {
        guard isEnabled != enabled else { return }
        enabled = isEnabled
        defaults?.set(isEnabled, forKey: Self.enabledKey)
        if isEnabled {
            /* The ONE place the system prompt is allowed to fire: the
               person's own act of turning previews on. `refresh` below
               never requests, only preflights — so a launch that restores
               `enabled == true` from a previous session, and whose `.task`
               fires a refresh on page appearance, never re-prompts either. */
            hostSource?.requestAccessIfNeeded()
        } else {
            clear()
        }
    }

    /// Called when the arranger appears and when the display configuration
    /// changes - the two moments a still can go stale. Never on a timer.
    /// Disabled is the hard gate: nothing past this line touches a host
    /// source, a guest source, or TCC while previews are off, independent
    /// of what the caller passes.
    func refresh(hosts: [HostDisplayDescriptor]) async {
        guard enabled else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        var captured: [UInt32: CGImage] = [:]
        var failure: ContinuityPreviewNote?
        for host in hosts where hostSource != nil {
            guard let hostSource else { break }
            do {
                captured[host.id] = try await hostSource.captureHostDisplay(
                    id: host.id, maxPixelWidth: Self.maxPreviewPixelWidth)
            } catch ContinuityPreviewError.screenRecordingDenied {
                /* A denial is about the grant, not about this display, so it
                   ends the sweep: asking four times produces one answer and
                   three more chances to prompt. */
                failure = .screenRecordingDenied
                captured.removeAll()
                break
            } catch {
                failure = .captureFailed
            }
        }
        hostPreviews = captured
        note = failure

        /* No guest source, or no guest connected, is not a failure and gets
           no note: the tile falls back to the flat fill with the guest name,
           which is what the arranger looked like before previews existed. */
        guestPreview = try? await guestSource?.captureGuestScreen()
    }

    func clear() {
        hostPreviews = [:]
        guestPreview = nil
        note = nil
    }
}
