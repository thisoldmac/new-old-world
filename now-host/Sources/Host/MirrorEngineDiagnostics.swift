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

    init(limit: Int = 64) { self.limit = max(1, limit) }

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
        differences.append(.init(
            sequence: engine.sequence,
            legacyApps: legacy.apps.count, engineApps: engine.scene.apps.count,
            legacyWindows: legacy.windows.count,
            engineWindows: engine.scene.windows.count,
            summary: changed, observedAt: date))
        if differences.count > limit {
            differences.removeFirst(differences.count - limit)
        }
    }
}
