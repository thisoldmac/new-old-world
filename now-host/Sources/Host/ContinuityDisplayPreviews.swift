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

    func captureHostDisplay(id: CGDirectDisplayID,
                            maxPixelWidth: CGFloat) async throws -> CGImage {
        /* Preflight rather than request: this asks TCC what we already have
           WITHOUT prompting, so the prompt below happens only once the
           arranger has genuinely asked for a picture. Nothing on the launch
           path reaches here. */
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw ContinuityPreviewError.screenRecordingDenied
            }
        }

        if #available(macOS 14.0, *) {
            return try await captureViaScreenshotManager(
                id: id, maxPixelWidth: maxPixelWidth)
        }
        /* macOS 13 has SCContentFilter but no one-shot still API to hand it
           to, and standing up an SCStream to keep a single frame costs more
           than this preview is worth. CGDisplayCreateImage is TCC-gated the
           same way, so a denial is still a denial - it just cannot drop the
           windows. */
        plan = .wholeDisplay
        guard let image = CGDisplayCreateImage(id) else {
            throw ContinuityPreviewError.captureFailed
        }
        return Self.downscaled(image, maxPixelWidth: maxPixelWidth)
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
           no window earns its way back in. */
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

    private static let enabledKey = "mirror.continuity.displayPreviews"

    private let hostSource: ContinuityHostScreenCapturing?
    private let guestSource: ContinuityGuestScreenCapturing?
    private let defaults: UserDefaults?
    private var refreshing = false

    init(hostSource: ContinuityHostScreenCapturing?
            = ContinuityScreenCaptureKitSource(),
         guestSource: ContinuityGuestScreenCapturing? = nil,
         defaults: UserDefaults? = ProductIdentity.defaults) {
        self.hostSource = hostSource
        self.guestSource = guestSource
        self.defaults = defaults
        self.enabled = defaults?.bool(forKey: Self.enabledKey) ?? false
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
        if !isEnabled { clear() }
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
