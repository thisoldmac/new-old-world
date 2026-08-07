import Foundation

/// What a process IS, and what we know about what it HAS.
///
/// ## The three states that shared one error word
///
/// Until 2026-08-07 every one of these arrived as `ax_oracle_not_found`:
///
/// 1. **A faceless background application** — Control Strip Extension,
///    Folder Actions, an `appe` worker. It has no user interface **by
///    declaration**, so it never could have had an anchor. Normal, and
///    permanent.
/// 2. **An application with a face and nothing open right now** —
///    SimpleText with every document closed. Normal, and **transient**:
///    it changes from moment to moment on a healthy machine, which is why
///    folding it into either neighbour is wrong half the time.
/// 3. **An application whose windows exist and which we failed to read.**
///    The only failure of the three.
///
/// One word for all three meant nobody could tell them apart, and it made
/// a permanently-false health signal: a coverage claim that can never
/// settle because it is waiting for processes that have nothing to cover.
///
/// ## Absence known versus absence unknown
///
/// The distinction between 2 and 3 is the one the render ladder already
/// draws between "the machine drew nothing here" and "we could not
/// attribute this rectangle" — moved from rectangles to processes. It is
/// also the same shape as the anchor counters' open question, *"armed and
/// capturing nothing"* versus *"the filter never ran in a foreign
/// context"*: a reader who has met one will recognise the other.
///
/// So the answer comes from **the walk's own report**, never from the
/// host counting windows. `error == nil` means the guest enumerated this
/// process; zero windows under that is a measured emptiness. An `error`
/// means it did not, and says why.
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
/// very processes it is asked about — the Application Switcher is itself a
/// process, and it was among the eight that could not be read on slice 3's
/// bad boot. There is one source, and it is the declaration.
public enum ProcessPresence: String, Equatable, Sendable, CaseIterable {
    /// Declared `modeOnlyBackground`: no user interface, by design.
    /// Having no windows is this process's normal, permanent state.
    case headless
    /// Enumerated, and it has windows.
    case windowed
    /// Enumerated, and it has none open right now. Normal and transient —
    /// **not** a smaller version of `headless`.
    case idle
    /// We could not enumerate this process. `ProcessPresence.Verdict.reason`
    /// carries the guest's own token for why.
    case unobserved
    /// Neither the declaration nor an enumeration result was available.
    /// Reported as unknown rather than folded into a normal state:
    /// inventing a comfortable classification for something we could not
    /// read is exactly the plausible-wrong-answer this work exists to
    /// kill.
    case unclassified

    /// True when this process legitimately has nothing for a window-level
    /// census to cover — so counting it as a coverage failure would keep a
    /// health signal permanently, and falsely, unsettled.
    public var hasNothingToCover: Bool {
        self == .headless
    }
}

public extension ProcessPresence {
    struct Verdict: Equatable, Sendable {
        public var presence: ProcessPresence
        /// The guest's own token, for `unobserved` and `unclassified`.
        /// Never invented here: an `ax_oracle_*` / `now_*` word from the
        /// scene, or a word this side owns and defines below.
        public var reason: String?

        public init(_ presence: ProcessPresence, reason: String? = nil) {
            self.presence = presence
            self.reason = reason
        }
    }

    /// This side's own reasons, distinct from the guest's tokens.
    ///
    /// `now_no_declaration` is the honest floor for a scene produced
    /// before `backgroundOnly` existed and carrying no error either: we
    /// have neither signal, so we say so.
    static let noDeclarationReason = "now_no_declaration"

    /// Classify one application row against the scene it came from.
    ///
    /// - Parameter windowCount: windows the scene attributes to this
    ///   process. Used **only** to split `windowed` from `idle`, both of
    ///   which are already known to be successful enumerations — never to
    ///   decide whether a process has a face.
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
            // enumerated. Everything else is a failure to enumerate.
            if error == "ax_oracle_stale", windowCount > 0 {
                return Verdict(.windowed)
            }
            return Verdict(.unobserved, reason: error)
        }
        if windowCount > 0 {
            return Verdict(.windowed)
        }
        // No error means the guest enumerated this process. Zero windows
        // under that is a measured emptiness — the case the host must not
        // guess at. Without the declaration key we cannot rule out
        // `headless`, so an older guest gets `unclassified` rather than a
        // flattering `idle`.
        return app.backgroundOnly == nil
            ? Verdict(.unclassified, reason: noDeclarationReason)
            : Verdict(.idle)
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
