import Foundation

/// **What a drag is picking up, and what it would be dropped on.**
///
/// Renderer-free, like `HitTester`, and for the same reason: the headless head
/// and the live view must resolve a drag identically, or the thing an agent
/// drives and the thing a person sees stop being the same product.
///
/// ## The two questions, and why they are asked separately
///
/// A drag has a subject and a destination, and they fail differently. A
/// subject the mirror cannot place is a fact about **us** — we do not know
/// where the item is, so we could not put it back. A destination that is a
/// scroll bar is a fact about the **screen**. Rolling both into "the drag did
/// not work" is how a person ends up unable to tell a mirror bug from a
/// gesture that was never going to mean anything.
///
/// ## Why a subject must have a trustworthy home
///
/// The presentation contract says a drag that is not confirmed **snaps the
/// item back home** — on release before confirmation, and on a failed select.
/// So a drag may only begin on an item whose current position came from the
/// box the Finder actually drew (`Scene.PositionOrigin.drawn`). Every other
/// provenance is a position this side either inferred from the saved grid or
/// invented outright, and returning a file to an invented position is worse
/// than never picking it up: it is a wrong answer delivered confidently, with
/// a file attached.
///
/// That rule is only affordable because the geometry was repaired first —
/// folder windows by the list-view lane, the desktop and its disks by the
/// desktop clause in `FinderItems.windowsScript`. Before that it would have
/// refused every desktop drag.
///
/// ## What is deliberately NOT here
///
/// **Cross-machine file transfer.** Dropping a guest file onto the macOS
/// desktop, or the reverse, is its own plan: it needs promise types, a
/// transfer, and the guest's own Drag Manager. Everything below happens
/// entirely inside the mirrored guest.
public enum DragTargeting {

    // MARK: - Subject

    /// The thing being dragged, and where it lives.
    public enum Subject: Equatable {
        /// An icon on the desktop. Its box is already in global coords.
        case desktopItem(Scene.DesktopItem)
        /// An icon inside a Finder folder window. Its box is content-local to
        /// that window, which is why the window travels with it.
        case windowItem(windowID: String, item: Scene.DesktopItem)

        public var item: Scene.DesktopItem {
            switch self {
            case .desktopItem(let i): return i
            case .windowItem(_, let i): return i
            }
        }

        public var name: String { item.name }

        /// The container an item belongs to, which is what makes a drop a
        /// rearrangement rather than a move.
        public var container: Container {
            switch self {
            case .desktopItem: return .desktop
            case .windowItem(let id, _): return .window(id)
            }
        }
    }

    /// Where an item lives, or would live. Identity only — two windows
    /// showing the same folder are still two containers to a gesture.
    public enum Container: Equatable {
        case desktop
        case window(String)
    }

    // MARK: - Destination

    /// What the pointer is over at the end of the gesture.
    public enum Destination: Equatable {
        /// Bare desktop. The drop point is the pointer's.
        case desktop(x: Int, y: Int)
        /// The content of a Finder folder window — dropping here files the
        /// item into that folder.
        case finderWindow(windowID: String, path: String, x: Int, y: Int)
        /// The content of some other application's window. The Macintosh
        /// meaning is "give this file to that application"; whether the
        /// application accepts it is the application's business, and the
        /// mirror does not predict it.
        case applicationWindow(windowID: String, psn: String, app: String,
                               x: Int, y: Int)
        /// An application's ICON — the classic "open this document with that
        /// program" gesture. The point is the icon's own centre, never where
        /// the pointer happened to land, which is the discipline every other
        /// item target here already follows.
        case applicationIcon(name: String, x: Int, y: Int)
        /// A folder or disk icon: file the item inside it.
        case container(name: String, kind: String, x: Int, y: Int)
    }

    /// What the drop would mean. Named rather than inferred at the call site,
    /// because "same container" is the difference between rearranging an icon
    /// and moving a file, and a caller that had to work that out from two
    /// identifiers would eventually work it out differently somewhere else.
    public enum Intent: Equatable {
        /// Same container, new position — the ordinary Mac icon shuffle. It is
        /// explicitly NOT a no-op: Michelle asked for this by name.
        case rearrange
        /// A different container: the item moves.
        case move
        /// Onto an application icon: open the item with it.
        case openWith
    }

    /// A drag the mirror is prepared to carry out.
    public struct Plan: Equatable {
        public var subject: Subject
        /// The box the Finder drew, in **global guest coordinates** — the same
        /// space the destination points are in, so a snap-back and a drop
        /// never need a second frame of reference.
        public var home: Rect
        public var destination: Destination
        public var intent: Intent
    }

    /// Why a drag will not happen, in words meant for the status line.
    ///
    /// Every case says whose fact it is. `homeUnknown` is ours; the rest are
    /// the screen's.
    public enum Refusal: Equatable, Error {
        /// The gesture did not start on an item at all.
        case notAnItem(what: String)
        /// It started on an item whose position we cannot vouch for.
        case homeUnknown(name: String, origin: Scene.PositionOrigin?)
        /// It ended somewhere nothing can be dropped.
        case notADropTarget(what: String)
        /// It ended on the item it started on.
        case droppedOnItself(name: String)

        public var message: String {
            switch self {
            case .notAnItem(let what):
                return "\(what) is not something to drag"
            case .homeUnknown(let name, let origin):
                let where_ = origin.map(Self.describe) ?? "nothing said where"
                return "the mirror does not know where \(name) is "
                    + "(\(where_)) — it will not move something it cannot "
                    + "put back"
            case .notADropTarget(let what):
                return "\(what) is not a drop target"
            case .droppedOnItself(let name):
                return "\(name) was dropped on itself"
            }
        }

        private static func describe(_ o: Scene.PositionOrigin) -> String {
            switch o {
            case .drawn:   return "the Finder's own box"
            case .saved:   return "the saved icon grid, not the drawn box"
            case .unknown: return "the position was ours, not the guest's"
            }
        }
    }

    public typealias Outcome = Result<Plan, Refusal>

    // MARK: - Resolving

    /// Resolve a whole gesture: where it began, where it ended.
    public static func plan(_ scene: Scene,
                            from start: (x: Int, y: Int),
                            to end: (x: Int, y: Int)) -> Outcome {
        let picked: Subject
        switch subject(scene, x: start.x, y: start.y) {
        case .success(let s): picked = s
        case .failure(let r): return .failure(r)
        }
        guard let home = home(of: picked, in: scene) else {
            /* Unreachable through `subject`, which already required a drawn
               box — but a window that vanished between the two lookups is a
               real race, and the honest answer to it is the same refusal
               rather than a force-unwrap. */
            return .failure(.homeUnknown(name: picked.name,
                                         origin: picked.item.origin))
        }
        switch destination(scene, x: end.x, y: end.y, dragging: picked) {
        case .failure(let r):
            return .failure(r)
        case .success(let dest):
            return .success(.init(subject: picked, home: home,
                                  destination: dest,
                                  intent: intent(picked, dest, in: scene)))
        }
    }

    /// The item a press at this point picks up.
    public static func subject(_ scene: Scene, x: Int, y: Int)
        -> Result<Subject, Refusal> {
        let target = HitTester.hitTest(scene, x: x, y: y)
        let picked: Subject
        switch target {
        case .desktopItem(let name, _, _):
            guard let item = scene.desktopItems?.last(where: {
                $0.name == name
            }) else {
                return .failure(.notAnItem(what: name))
            }
            picked = .desktopItem(item)
        case .windowItem(let windowID, let name, _, _):
            guard let win = scene.windows.first(where: { $0.id == windowID }),
                  let item = win.items?.last(where: { $0.name == name }) else {
                return .failure(.notAnItem(what: name))
            }
            picked = .windowItem(windowID: windowID, item: item)
        default:
            return .failure(.notAnItem(what: describe(target)))
        }
        /* THE PHASE-0 GATE. Everything above this line found an item; this is
           the line that asks whether we could put it back. */
        guard picked.item.homeIsTrustworthy else {
            return .failure(.homeUnknown(name: picked.name,
                                         origin: picked.item.origin))
        }
        return .success(picked)
    }

    /// The item's box in global guest coordinates — its home, and the frame
    /// the provisional ghost starts in.
    public static func home(of subject: Subject, in scene: Scene) -> Rect? {
        let item = subject.item
        let box = HitTester.targetSize(item)
        switch subject {
        case .desktopItem:
            return Rect(l: item.x, t: item.y,
                        r: item.x + box.w, b: item.y + box.h)
        case .windowItem(let windowID, _):
            guard let win = scene.windows.first(where: { $0.id == windowID })
            else { return nil }
            let o = FinderItems.contentOrigin(win)
            return Rect(l: o.x + item.x, t: o.y + item.y,
                        r: o.x + item.x + box.w, b: o.y + item.y + box.h)
        }
    }

    /// What a release at this point would drop onto.
    public static func destination(_ scene: Scene, x: Int, y: Int,
                                   dragging: Subject)
        -> Result<Destination, Refusal> {
        let target = HitTester.hitTest(scene, x: x, y: y)
        switch target {
        case .desktop(let dx, let dy):
            return .success(.desktop(x: dx, y: dy))

        case .desktopItem(let name, let cx, let cy):
            guard name != dragging.name || dragging.container != .desktop else {
                return .failure(.droppedOnItself(name: name))
            }
            let kind = scene.desktopItems?.last { $0.name == name }?.kind
            return .success(itemDestination(name: name, kind: kind,
                                            x: cx, y: cy))

        case .windowItem(let windowID, let name, let cx, let cy):
            guard name != dragging.name
                    || dragging.container != .window(windowID) else {
                return .failure(.droppedOnItself(name: name))
            }
            let kind = scene.windows.first { $0.id == windowID }?
                .items?.last { $0.name == name }?.kind
            return .success(itemDestination(name: name, kind: kind,
                                            x: cx, y: cy))

        case .content(let windowID, let psn, _, let cx, let cy):
            guard let win = scene.windows.first(where: { $0.id == windowID })
            else { return .failure(.notADropTarget(what: "a closed window")) }
            if FinderItems.isFolderWindow(win) {
                /* The folder's HFS path is what a semantic move acts on, and
                   the poller carries it separately from the scene. A window
                   whose path we never learned is still a drop target — the
                   coordinate drop works — so an empty path travels rather
                   than becoming a refusal. */
                return .success(.finderWindow(windowID: windowID,
                                              path: win.title,
                                              x: cx, y: cy))
            }
            return .success(.applicationWindow(windowID: windowID, psn: psn,
                                               app: win.app, x: cx, y: cy))

        default:
            return .failure(.notADropTarget(what: describe(target)))
        }
    }

    /// An icon as a destination: an application opens the item, a folder or
    /// disk receives it, and anything else is not a container.
    private static func itemDestination(name: String, kind: String?,
                                        x: Int, y: Int) -> Destination {
        switch kind {
        case "application":
            return .applicationIcon(name: name, x: x, y: y)
        case "folder", "disk":
            return .container(name: name, kind: kind ?? "folder", x: x, y: y)
        default:
            /* A document dropped on a document. The Finder's own answer is to
               file it beside — the drop lands in the container the icon is
               in, which is where the pointer already is — so this is not a
               refusal, it is an ordinary drop at a point. */
            return .container(name: name, kind: kind ?? "file", x: x, y: y)
        }
    }

    /// Same container, new position, is a **rearrangement** and must behave
    /// like one. Michelle asked for this by name: "dragging within a Finder
    /// window or on the desktop moves the item the ordinary Mac way rather
    /// than becoming a no-op."
    private static func intent(_ subject: Subject, _ dest: Destination,
                               in scene: Scene) -> Intent {
        switch dest {
        case .applicationIcon:
            return .openWith
        case .desktop:
            return subject.container == .desktop ? .rearrange : .move
        case .finderWindow(let windowID, _, _, _),
             .applicationWindow(let windowID, _, _, _, _):
            return subject.container == .window(windowID) ? .rearrange : .move
        case .container:
            return .move
        }
    }

    /// A hit-test target in words, for a refusal a person reads. It names the
    /// KIND of thing rather than an identifier: "a scroll bar" is what someone
    /// needs to hear, and `ctl_0x0034ab10` is not.
    static func describe(_ target: HitTester.Target) -> String {
        switch target {
        case .menuTitle:         return "a menu"
        case .menubarBackground: return "the menu bar"
        case .widget:            return "a title-bar widget"
        case .growBox:           return "the grow box"
        case .control:           return "a control"
        case .dialogItem:        return "a dialog item"
        case .scrollbar:         return "a scroll bar"
        case .titlebar:          return "a title bar"
        case .content:           return "a window"
        case .desktop:           return "the desktop"
        case .windowItem(_, let name, _, _): return name
        case .desktopItem(let name, _, _):   return name
        }
    }
}
