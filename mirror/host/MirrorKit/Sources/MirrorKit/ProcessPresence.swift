import Foundation

/// What a process IS, and what we know about what it HAS.
///
/// ## The vocabulary
///
/// Two words, and the split between them is who the fact is about
/// (`scene.h`'s `_present` "looked-at-all" bit is the precedent):
///
/// - **empty** — we looked, and there are none. A fact about **the
///   machine**.
/// - **unknown** — we did not, or could not, establish it. A fact about
///   **us**, and it always carries a reason.
///
/// A **kind** is neither: it is what the thing is, not a measurement of
/// it. `headless` is a kind.
///
/// ## The states that shared one error word
///
/// Until 2026-08-07 every one of these arrived as `ax_oracle_not_found`:
///
/// 1. **A faceless background application** — Control Strip Extension,
///    Folder Actions, an `appe` worker. It has no user interface **by
///    declaration**, so it never could have had an anchor. A kind:
///    `headless`.
/// 2. **An application with a face and nothing open right now** —
///    SimpleText with every document closed. `empty`, and **transient**:
///    it changes from moment to moment on a healthy machine, which is why
///    folding it into either neighbour is wrong half the time.
/// 3. **An application whose windows exist and which we failed to read.**
///    `unknown`, with the guest's own token for why.
///
/// One word for all three meant nobody could tell them apart, and it made
/// a permanently-false health signal: a coverage claim that can never
/// settle because it is waiting for processes that have nothing to cover.
///
/// ## The fourth condition, and why `empty` is earned rather than assumed
///
/// There is a fact about us that looks exactly like `empty` and is not:
/// **we have never been in a position to look.** An application acquires
/// an anchor slot only after it has been frontmost at least once since
/// NOW armed — measured 2026-08-07 at 451 armed passes and *one* slot
/// scan, because `capture_anchor`'s A5 fast path skips the scan unless
/// the context changed. A process that has never come forward is not
/// failing to be observed; the filter has never run inside it.
///
/// So `empty` is not the default answer for "no windows in the scene".
/// It is granted only when the guest reported a SUCCESSFUL enumeration —
/// no error token — and every one of those never-front processes carries
/// `ax_oracle_not_found`, which lands them in `unknown` where they
/// belong. Reading them as `empty` would be the confident wrong answer
/// this whole arc exists to kill, and it would be indistinguishable from
/// the real thing.
///
/// This is why the classifier consults the **error first** and the window
/// count second. The error is the walk's own account of whether it
/// enumerated; the count only ever splits two states that are both
/// already known to be enumerations.
///
/// ## One signal, not two
///
/// The Application menu's membership is **the same bit one remove away**,
/// not independent corroboration: the Process Manager omits a
/// `modeOnlyBackground` application from it. (That is why the mirror's own
/// *synthesised* switcher listing background processes read as wrong
/// beside the real one — open-issues, Cycle 20.) Reading that menu back to
/// learn what a process is would put a walked UI artifact in the path of a
/// fact the Process Manager hands over directly, and would fail for the
/// very processes it is asked about. There is one source, and it is the
/// declaration.
public enum ProcessPresence: String, Equatable, Sendable, CaseIterable {
    /// A KIND: declared `modeOnlyBackground`, no user interface by design.
    /// Having no windows is this process's normal, permanent state.
    case headless
    /// Enumerated, and it has windows.
    case windowed
    /// Enumerated, and it has none open right now. A fact about the
    /// machine, normal and transient — **not** a smaller `headless`.
    case empty
    /// We did not, or could not, establish what this process has.
    /// `Verdict.reason` always says why.
    case unknown

    /// True when this process legitimately has nothing for a window-level
    /// census to cover — so counting it as a coverage failure would keep a
    /// health signal permanently, and falsely, unsettled.
    ///
    /// `unknown` is deliberately NOT included: a gap we cannot explain is
    /// exactly what a coverage claim should still be reporting.
    public var hasNothingToCover: Bool {
        self == .headless
    }
}

public extension ProcessPresence {
    struct Verdict: Equatable, Sendable {
        public var presence: ProcessPresence
        /// Why, for `unknown`. Never invented here: the guest's own
        /// `ax_oracle_*` / `now_*` token, or one of this side's reasons
        /// below. Non-nil whenever `presence == .unknown`.
        public var reason: String?

        public init(_ presence: ProcessPresence, reason: String? = nil) {
            self.presence = presence
            self.reason = reason
        }
    }

    /// This side's own reason, distinct from the guest's tokens: the scene
    /// carried neither a declaration nor an enumeration failure, so we
    /// cannot tell `headless` from `empty`. A guest that predates
    /// `backgroundOnly` produces exactly this, and it is reported as
    /// unknown rather than given the comfortable answer.
    static let noDeclarationReason = "now_no_declaration"

    /// Classify one application row against the scene it came from.
    ///
    /// - Parameter windowCount: windows the scene attributes to this
    ///   process. Used **only** to split `windowed` from `empty`, both of
    ///   which are already known to be successful enumerations — never to
    ///   decide whether a process has a face, and never to earn `empty`
    ///   on its own.
    static func classify(_ app: Scene.AppRef,
                         windowCount: Int) -> Verdict {
        // The declaration comes first and answers on its own. A faceless
        // process's missing anchor is not a failure to report.
        if app.backgroundOnly == true {
            return Verdict(.headless)
        }
        if let error = app.error {
            // Staleness is reported BESIDE data rather than instead of
            // it, so a stale row that carries windows was still
            // enumerated — it is old, not unread. Every other token means
            // the walk did not happen or did not finish, and that
            // includes the never-been-frontmost case.
            if error == "ax_oracle_stale", windowCount > 0 {
                return Verdict(.windowed)
            }
            return Verdict(.unknown, reason: error)
        }
        if windowCount > 0 {
            return Verdict(.windowed)
        }
        // No error means the guest enumerated this process, so zero
        // windows is a measured emptiness rather than an unexamined one.
        // Without the declaration key we cannot rule out `headless`, so an
        // older guest gets `unknown` rather than a flattering `empty`.
        return app.backgroundOnly == nil
            ? Verdict(.unknown, reason: noDeclarationReason)
            : Verdict(.empty)
    }

    /// Every application in a scene, classified. Window counts are taken
    /// from the scene's own attribution.
    static func classify(_ scene: Scene) -> [String: Verdict] {
        var windows: [String: Int] = [:]
        for w in scene.windows {
            windows[w.psn, default: 0] += 1
        }
        var out: [String: Verdict] = [:]
        for app in scene.apps {
            out[app.psn] = classify(app, windowCount: windows[app.psn] ?? 0)
        }
        return out
    }
}
