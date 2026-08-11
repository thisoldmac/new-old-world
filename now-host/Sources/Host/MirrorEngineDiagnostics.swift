import Foundation
import MirrorKit

/// Bounded shadow comparisons. A difference is evidence to inspect, not a
/// reason to patch the visible scene or to declare the new engine right.
@MainActor
final class MirrorEngineDiagnostics {
    struct Difference: Equatable {
        var sequence: Int
        var legacyApps: Int
        var engineApps: Int
        var legacyWindows: Int
        var engineWindows: Int
        var summary: String
        var observedAt: Date
    }

    private(set) var differences: [Difference] = []
    private let limit: Int
    private let note: @MainActor (Difference) -> Void

    /// **A difference nobody can read is not evidence.** This ring was
    /// recorded and never surfaced — not logged, not shown in the
    /// Diagnostics pane, not exported — so the one instrument that can say
    /// "the projection and the document disagreed about the MENU BAR at
    /// 02:41" kept the answer in memory until the app quit. That is exactly
    /// what the empty-menu-bar report needed and could not get
    /// (docs/open-issues.md, 2026-08-06): the guest, the wire, the decoder,
    /// the reducer and the renderer were each cleared by a test, and what
    /// remained was a question about live projection state that left no
    /// trace. Now it leaves one.
    ///
    /// Injectable so a test can watch the line without a log file, and so
    /// this stays a comparison rather than becoming a logger.
    init(limit: Int = 64,
         note: @escaping @MainActor (Difference) -> Void =
         { difference in
             HostLog.shared.write(
                 .warn, "mirror",
                 "shadow engine differs from the visible scene at seq "
                 + "\(difference.sequence): \(difference.summary) "
                 + "(apps \(difference.legacyApps)/\(difference.engineApps), "
                 + "windows \(difference.legacyWindows)/"
                 + "\(difference.engineWindows))")
         }) {
        self.limit = max(1, limit)
        self.note = note
    }

    func compare(legacy: Scene, engine: MirrorProjection, at date: Date) {
        let appDelta = legacy.apps.count != engine.scene.apps.count
        let windowDelta = legacy.windows.count != engine.scene.windows.count
        let menubarDelta = legacy.menubar != engine.scene.menubar
        guard appDelta || windowDelta || menubarDelta else { return }
        let changed = [
            appDelta ? "applications" : nil,
            windowDelta ? "windows" : nil,
            menubarDelta ? "menubar" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        let difference = Difference(
            sequence: engine.sequence,
            legacyApps: legacy.apps.count, engineApps: engine.scene.apps.count,
            legacyWindows: legacy.windows.count,
            engineWindows: engine.scene.windows.count,
            summary: changed, observedAt: date)
        differences.append(difference)
        note(difference)
        if differences.count > limit {
            differences.removeFirst(differences.count - limit)
        }
    }
}
