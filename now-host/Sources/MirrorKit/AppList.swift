import Foundation

/// Enumeration of the guest's applications, for `mirror.app {op:"list"}`.
///
/// The service surface is element-first: an agent must be able to discover what
/// is running and then act on it without ever computing a coordinate. A row's
/// `psn` is exactly what `mirror.app {op:"activate"|"quit"}` takes, so the list
/// is directly actionable — that is the whole point of it existing separately
/// from `mirror.scene`'s `apps` array, which an agent would otherwise have to
/// reach into and re-filter by hand.
///
/// The qualifying rule is NOT ours: it is `HitTester.switchableApps`, the same
/// predicate the mirror's own Application menu lists. An app earns a row by
/// having a window or by being frontmost, because the guest runs faceless
/// background processes (the mirror agent itself, `tbt-worker`, Control Strip
/// Extension) that the real Mac OS Application menu does not show either.
/// Keeping the two on one predicate means the agent-facing list and the
/// human-facing menu can never drift.
public enum AppList {

    /// One enumerated application.
    public struct Row: Equatable, Sendable {
        /// `hi.lo` process serial number — the handle `activate`/`quit` take.
        public var psn: String
        public var name: String
        public var front: Bool
        /// True when this row is only present because `includeBackground` asked
        /// for it: a faceless process the Application menu would not show.
        /// Always carried, in both modes, so the row shape is stable and a
        /// consumer never has to infer it from which flag it passed.
        public var background: Bool
        /// Windows the scene attributes to this psn. Explains the row's
        /// classification directly (`windows > 0 || front` is exactly the
        /// switchable rule). Note the Finder's desktop backdrop counts here,
        /// which is why the Finder is never background.
        public var windows: Int
        /// Per-app oracle error (`ax_oracle_*`), surfaced rather than hidden —
        /// an app whose sample failed is still running. Absent when clean.
        public var error: String?

        public init(psn: String, name: String, front: Bool,
                    background: Bool, windows: Int, error: String? = nil) {
            self.psn = psn
            self.name = name
            self.front = front
            self.background = background
            self.windows = windows
            self.error = error
        }
    }

    /// Enumerate the scene's applications.
    ///
    /// - Parameter includeBackground: when true, faceless processes are kept
    ///   (flagged `background: true`) instead of filtered out. Default false —
    ///   the honest default for "what can I switch to" is what a user would see
    ///   in the Application menu, and a list padded with the mirror's own agent
    ///   invites an agent to `quit` the thing it is talking through.
    /// - Returns: rows in scene order, frontmost app's row carrying `front`.
    public static func rows(_ scene: Scene,
                            includeBackground: Bool = false) -> [Row] {
        let switchable = Set(switchableApps(scene).map(\.psn))
        var windowCount: [String: Int] = [:]
        for w in scene.windows {
            windowCount[w.psn, default: 0] += 1
        }
        var out: [Row] = []
        for app in scene.apps {
            let background = !switchable.contains(app.psn)
            if background && !includeBackground { continue }
            out.append(Row(psn: app.psn, name: app.name, front: app.front,
                           background: background,
                           windows: windowCount[app.psn] ?? 0,
                           error: app.error))
        }
        return out
    }

    /// Indirection kept deliberately thin so the predicate has ONE definition.
    private static func switchableApps(_ scene: Scene) -> [Scene.AppRef] {
        HitTester.switchableApps(scene)
    }
}
