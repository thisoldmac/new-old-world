import Foundation

/// **Did the content plane ever LOOK at this window?**
///
/// P3 is a per-window spotlight, not a plane: `qdtrace start` takes exactly
/// one `window` address and refuses an all-windows arm by name, so the host
/// arms the front window and no other. At best one window interior can exist
/// at a time (docs/open-issues.md, 2026-08-07, "one window interior at a
/// time"), and every other window arrives at the renderer with
/// `display == nil`.
///
/// So did the window the plane was armed on and found nothing in. **Those two
/// drew the identical hatch**, captioned with a claim about the guest —
/// "Guest content not reported" — that was only ever true of one of them.
/// A window nobody looked at is not a window that reported nothing, and the
/// difference is exactly the difference between a product limit and a
/// defect. Four render sweeps' worth of hatched interiors could not be
/// attributed to either without it.
///
/// This is the distinction, and it is deliberately the ONLY thing this type
/// carries. It says what this host did; it does not rank, explain or excuse.
///
/// ## What it is not
///
/// - **Not staleness.** A lapsed or superseded arm does not hatch — it keeps
///   publishing the last settled ops, which is a different lie (it looks
///   current) answered in a different place, by ``DisplayEpoch/stale``.
/// - **Not "content is missing".** `armed` with no ops is a real and healthy
///   answer: an application whose drawing the plane cannot express, or one
///   that has not redrawn since the arm.
public enum ContentPlaneAttention: String, Equatable, Sendable {
    /// The plane has never been armed on this exact window. Nothing was
    /// asked, so nothing about the guest follows from the empty interior.
    case notAttempted
    /// The plane has been armed on this exact window at least once in this
    /// session. Whatever the interior shows — ops, or nothing — is an answer.
    case armed
}
