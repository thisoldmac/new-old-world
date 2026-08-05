import Foundation
import MirrorKit

/// The one spelling of a Mirror entity's id.
///
/// The read side mints these and the drive side resolves them, so two
/// copies of the grammar would not fail to build when they drifted — they
/// would fail to AGREE, and the symptom would be an agent naming exactly
/// what the snapshot showed it and being told no such window exists. That
/// is the shared-header lesson in `docs/mirror-measurement-method.md`
/// wearing different clothes, and it was very nearly shipped here: the
/// first wiring of `now_mirror_drive` resolved `window:<psn>:<sceneID>`
/// against ids published as `window:<process incarnation>:<window
/// incarnation>`.
enum MirrorEntityID {
    static func process(_ incarnation: String) -> String {
        "process:" + incarnation
    }

    static func window(processIncarnation: String,
                       windowIncarnation: String) -> String {
        "window:" + processIncarnation + ":" + windowIncarnation
    }

    /// The id a scene window is published under, or nil when the scene
    /// cannot name its owner — an unowned window is describable and not
    /// addressable, and saying so beats inventing a key.
    static func window(_ window: MirrorKit.Scene.Window,
                       in scene: MirrorKit.Scene) -> String? {
        guard let incarnation = window.incarnation,
              let owner = (scene.processes ?? []).first(where: {
                  $0.psn == window.psn
              })?.incarnation else { return nil }
        return self.window(processIncarnation: owner,
                           windowIncarnation: incarnation)
    }
}
