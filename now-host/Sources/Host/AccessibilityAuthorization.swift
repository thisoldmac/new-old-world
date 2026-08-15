import AppKit
import ApplicationServices
import Foundation

/// Seam over the AX trust calls Continuity's host input capture depends
/// on, plus the one escape hatch that works when the prompt does not.
/// Deliberately narrow — nothing here checks any OTHER macOS privacy
/// permission — because the real prompt is a one-shot system dialog and a
/// test that called it for real would need to grant Accessibility trust to
/// whatever process runs the suite.
protocol AccessibilityAuthorization: Sendable {
    /// Whether this process currently holds Accessibility trust. Reflects
    /// live system state; this call itself never prompts and never has a
    /// side effect.
    func isProcessTrusted() -> Bool
    /// Asks macOS to show its Accessibility settings prompt when the
    /// process is not already trusted. Either way this call also lists the
    /// app in the Accessibility pane, which is the whole point of using the
    /// `WithOptions` form instead of the plain trust check.
    ///
    /// **This is a request, not a guarantee, and it is a one-shot macOS has
    /// often already spent.** TCC shows the dialog only while it holds no
    /// decision record for this bundle identifier; once the app has been
    /// granted-and-reset even once, the call returns silently forever and
    /// no dialog will ever appear again for that install. That is not a
    /// hypothetical: it is exactly what the 2026-08-14 metal round
    /// measured — 29 arm requests, 31 permission-missing audit lines, and
    /// no dialog. So this stays as the cheap first attempt and
    /// `openAccessibilitySettings` is the affordance that always works.
    func promptForTrust()
    /// Opens System Settings at the Accessibility pane. Unlike the prompt
    /// this has no one-shot behaviour and no TCC state behind it: it is a
    /// URL open, and it does the same thing on the eleventh build of the
    /// day as on the first. It is the reliable half of the pair.
    func openAccessibilitySettings()
}

/// Where this executable is running FROM, which is a different question
/// from which app it claims to be — and on 2026-08-15 that difference cost
/// an attended metal round.
///
/// macOS attaches Accessibility trust to a **copy on disk**, not to a
/// bundle identifier. Michelle granted the permission, System Settings
/// showed "New Old World.app" switched on, and the running process logged
/// the untrusted branch on every arm anyway: the grant was on
/// `/Applications/New Old World.app` while PID 82098 was
/// `/Volumes/New Old World 10/New Old World.app` — same identifier, same
/// team, same signing time, different copy. Eleven DMG volumes were
/// mounted, so every launch that day had been from a different path.
///
/// That is the most confusing state this feature can reach: the pane says
/// granted, the app says missing, and both are telling the truth. Nothing
/// in the log said which executable was speaking. This type exists so
/// something does.
struct RunningCopy: Sendable, Equatable {
    let path: String

    /// Whether this copy lives where a granted copy normally lives. A
    /// deliberately blunt test, and the bound on how clever this gets: it
    /// does NOT detect App Translocation, does NOT enumerate other copies
    /// on disk, and does NOT claim to know where the grant actually went.
    /// It answers only "am I running from somewhere a person would not
    /// have granted", which is enough to offer a remedy the Accessibility
    /// pane cannot.
    var isInApplicationsFolder: Bool {
        path.hasPrefix("/Applications/")
    }

    static var current: RunningCopy {
        RunningCopy(path: Bundle.main.bundleURL.path)
    }
}

struct SystemAccessibilityAuthorization: AccessibilityAuthorization {
    /// The Accessibility pane of Privacy & Security. Same scheme the
    /// Connections module already uses for Local Network, which is the
    /// established pattern in this app for "the permission is missing and
    /// the person needs to go turn it on".
    static let settingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptForTrust() {
        /* The constant itself is `not concurrency-safe` by the compiler's
           reckoning — it is an unmanaged CFString global — even though the
           process reads it once, immediately, and never mutates it. Naming
           it as a literal sidesteps the diagnostic without touching the
           real API. */
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: Self.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
