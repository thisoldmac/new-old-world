import ApplicationServices
import Foundation

/// Seam over the two AX trust calls Continuity's host input capture depends
/// on. Deliberately narrow — nothing here checks any OTHER macOS privacy
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
    func promptForTrust()
}

struct SystemAccessibilityAuthorization: AccessibilityAuthorization {
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
}
