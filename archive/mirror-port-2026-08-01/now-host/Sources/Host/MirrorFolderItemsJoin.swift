import Foundation
import MirrorKit

/// **The join that turns a folder window from an island into a model.**
///
/// `MirrorKit.FinderItems` is the measured half of this lane — the script,
/// the parse, the geometry — ported verbatim and unit-tested against fixture
/// text. Nothing on that side reaches a machine (`NoSecondWireTests`'s
/// rule). This file is the other half: the one control-lane round trip that
/// asks a connected Mac's Finder what its own windows are showing right now,
/// and folds the answer onto the scene the same way `MirrorContentJoin`
/// folds a `qdtrace` drain onto it — after the scene is on screen, not
/// instead of it.
///
/// ## Transport posture
///
/// One `script` call for every open Finder window: `FinderItems.windowsScript`
/// already loops the guest's whole window list inside a single `OSADoScript`,
/// which is the hazard rule this lane must keep faith with — a folder's
/// items are read by `items of window i`, never by a volume-wide search (the
/// 12-minute wedge `FinderItems`'s own header names). This call rides the
/// CONTROL lane `MirrorSceneProbe` and `MirrorContentJoin` already use, not
/// the transfer lane a scene takes.
///
/// ## Draw, not aim
///
/// This is the CACHE half. It runs once per landed scene (automatically —
/// unlike `MirrorContentJoin`, which is fetch-on-ask — because a folder
/// window with no items in it reads as an empty folder, and that is the
/// wrong lie for a page whose whole claim is what the Finder is showing).
/// The AIM half, `MirrorFolderItemsAim`, never reads what this cached: a
/// position old enough to draw from is not old enough to click from, so the
/// act path re-runs this same script itself, immediately before deciding
/// anything.
@MainActor
final class MirrorFolderItemsJoin {

    /// What one join came to.
    enum Outcome: Equatable {
        /// `windows` folder windows were matched by title and given items
        /// (`items` total across them). Zero of each is not a failure — a
        /// scene with no Finder folder window open asks nothing and joins
        /// nothing.
        case joined(windows: Int, items: Int)
        /// The guest was asked and said no, in its own words.
        case refused(String)
        /// The reply could not be read as a window walk at all.
        case unavailable(String)
    }

    private let listener: GuestListener

    /// Titles the LAST join could not place items for, because two open
    /// Finder windows answered under the same title. A page reads this to
    /// say why one of its windows drew no items rather than leaving the gap
    /// unexplained.
    private(set) var lastAmbiguous: Set<String> = []

    init(listener: GuestListener) {
        self.listener = listener
    }

    /// One fetch, folded onto `scene`'s Finder folder windows by TITLE — the
    /// one identity the Finder's own reply and a scene window both carry.
    /// Every other window (a dialog, a non-Finder application, the desktop
    /// backdrop) is left exactly as it arrived: this join has nothing to say
    /// about a window it cannot ask the Finder about.
    func join(into scene: MirrorKit.Scene,
              completion: @escaping (MirrorKit.Scene, Outcome) -> Void) {
        guard scene.windows.contains(where: FinderItems.isFolderWindow) else {
            completion(scene, .joined(windows: 0, items: 0))
            return
        }
        listener.runCommand(
            "script", args: ["source": FinderItems.windowsScript()]
        ) { [weak self] result in
            guard let self else { return }
            let (joined, outcome) = self.apply(result, to: scene)
            completion(joined, outcome)
        }
    }

    // MARK: - the decision, which is pure and therefore tested

    /// Turn one `script` reply into a scene and an outcome. No wire in it, so
    /// the title-matching and the ambiguity rule are unit-testable without a
    /// socket.
    func apply(_ result: CommandResult,
              to scene: MirrorKit.Scene) -> (MirrorKit.Scene, Outcome) {
        guard result.ok else {
            let error = result.error
            return (scene, .refused(
                error.map { "\($0.message) [\($0.code)]" }
                    ?? "The Mac refused the window walk without saying why."))
        }
        guard let output = Self.scriptOutput(result) else {
            return (scene, .unavailable(
                "The Mac's script reply carried no readable \"output\" row, "
                    + "so there is no window walk to read items from."))
        }
        let reports = FinderItems.parse(output)

        /* Two open windows wearing the same title are one Finder limit this
           layer inherits rather than papers over: `window "X"` in the
           Finder's OWN scripting terminology cannot pick one out of two
           either, and guessing which report belongs to which scene window
           would put one window's items in its neighbour's. Recorded by
           title, not silently dropped — a page is owed the reason. */
        var byTitle: [String: FinderItems.WindowReport] = [:]
        var ambiguous: Set<String> = []
        for report in reports {
            if byTitle[report.title] != nil { ambiguous.insert(report.title) }
            byTitle[report.title] = report
        }
        lastAmbiguous = ambiguous

        var joined = scene
        var windowsJoined = 0
        var itemsJoined = 0
        for i in joined.windows.indices {
            guard FinderItems.isFolderWindow(joined.windows[i]) else {
                continue
            }
            let title = joined.windows[i].title
            guard !ambiguous.contains(title), let report = byTitle[title]
            else { continue }
            /* No catalog to join identity from here — this walk answers a
               NAMED window's own items, not a listing this host already
               took. `FinderItems.merge` states plainly what an uncataloged
               name gets: a plain file, with the position that makes it
               addressable, which is the part this lane exists to add. */
            let placed = FinderItems.merge(placed: report.items, catalog: [])
            joined.windows[i].items = placed
            windowsJoined += 1
            itemsJoined += placed.count
        }
        return (joined, .joined(windows: windowsJoined, items: itemsJoined))
    }

    /// The `script` command's own `output` row (`input_cmds.c:437`), the
    /// Finder's reply exactly as `FinderItems.parse` expects it — quoted
    /// SOURCE-form text, because `OSADoScript` result is escaped and wrapped
    /// rather than re-shaped on the guest.
    static func scriptOutput(_ result: CommandResult) -> String? {
        guard let rows = result.rows("script"),
              let row = rows.first(where: { $0.first == "output" }),
              row.count > 1 else { return nil }
        return row[1]
    }
}
