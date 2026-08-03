import Foundation

/// **A thing on the guest that can be acted upon.**
///
/// ## Why the object comes first
///
/// The action model beside this one is gesture-first: a click resolves
/// straight to "what to send", and the identity of the thing clicked
/// survives only as far as the verb needs it. That reads naturally and
/// has two costs that took a long time to see.
///
/// The first is that a gesture with nowhere to go becomes nothing. A
/// click on a desktop icon resolved to "click at a point", and a driver
/// with no positional click verb could only refuse — even though the
/// Finder knows that icon by name and will happily select it if asked.
/// The information needed to ask was present at the hit and thrown away
/// one line later.
///
/// The second is that the same gesture on the same pixel means different
/// things, and only the object knows which. A press at the bottom of a
/// scroll bar is a line-down; ten pixels lower it is a grow box; in a
/// menu it is a command. Resolving "what was pressed" and "what should
/// happen" in one step means every driver re-derives the first to vary
/// the second.
///
/// So: a point resolves to an **object with identity**, the gesture is
/// **metadata carried alongside it**, and the driver decides. A click on
/// bare desktop is still an act on an object — the Finder's desktop —
/// and that is what makes it serveable at all.
///
/// ## What an object is
///
/// Something the guest can be asked about by name. Every case carries
/// the identity its own subsystem uses: a `now-window-…` reference, a
/// PSN, a menu id, a file name in a container. Geometry rides along
/// because a driver often needs it (a part code is derived from where
/// inside a control the press landed), but geometry is never the
/// identity — that lesson is the whole `18/20` history of this project.
public enum MirrorObject: Equatable, Sendable {

    /// A window, by the reference its guest minted. `ref` is optional
    /// because a producer may honestly have none — NOW's own Carbon
    /// window is not readable at the classic offsets — and a window
    /// without one can still be described, drawn and hit, just not acted
    /// upon. The driver says so rather than this pretending otherwise.
    case window(Window)

    /// A control inside a window. Carries the owning window because
    /// several acts need both, and because a control's rect is
    /// content-relative and means nothing without it.
    case control(Control)

    /// A menu in the menu bar. Opening one is mirror-local — no guest is
    /// involved until a row is chosen — so this exists mainly so a
    /// driver can be ASKED and answer "nothing to do", rather than the
    /// caller having to know that.
    case menu(Menu)

    /// One row of an open menu. The command a person actually meant.
    case menuItem(MenuItem)

    /// A running application, by PSN.
    case app(App)

    /// **The Finder's desktop**, and WHOSE it is. The object that makes a
    /// click on empty space expressible; the owner is what makes that
    /// click do what a Mac does, which is bring the Finder forward.
    ///
    /// Optional because a scene may not name the desktop's owner - then
    /// a click can still clear the selection, which is the rest of what
    /// the gesture means.
    case desktop(App?)

    /// An icon, on the desktop or inside a Finder window. Identified by
    /// NAME in a container, which is how the Finder itself addresses it
    /// — and therefore how it can be reached without clicking a pixel.
    case finderItem(FinderItem)

    // MARK: - The shapes

    public struct Window: Equatable, Sendable {
        public var id: String            // the scene's rendering key
        public var ref: String?          // the guest's act reference
        public var psn: String
        public var title: String
        public var rect: Rect            // the IR box (content grown up)
        public var kind: Int?
        public var isFront: Bool
        /// Which piece of the window the point landed on. The gesture's
        /// meaning depends on it and no driver should re-derive it.
        public var part: WindowPart

        public init(id: String, ref: String?, psn: String, title: String,
                    rect: Rect, kind: Int?, isFront: Bool,
                    part: WindowPart) {
            self.id = id; self.ref = ref; self.psn = psn
            self.title = title; self.rect = rect; self.kind = kind
            self.isFront = isFront; self.part = part
        }
    }

    public enum WindowPart: Equatable, Sendable {
        case titleBar
        case closeBox
        case zoomBox
        case collapseBox
        case growBox
        case content
    }

    public struct Control: Equatable, Sendable {
        public var ref: String
        public var role: String
        public var title: String
        /// Content-relative, as IR v1 defines it.
        public var rect: Rect?
        public var value: Int?
        public var min: Int?
        public var max: Int?
        public var isEnabled: Bool
        public var window: Window
        /// For a live scroll bar, the region the point landed in. nil for
        /// anything that is not one — a button has no parts.
        public var part: Scrollbar.Part?

        public init(ref: String, role: String, title: String, rect: Rect?,
                    value: Int?, min: Int?, max: Int?, isEnabled: Bool,
                    window: Window, part: Scrollbar.Part?) {
            self.ref = ref; self.role = role; self.title = title
            self.rect = rect; self.value = value; self.min = min
            self.max = max; self.isEnabled = isEnabled
            self.window = window; self.part = part
        }
    }

    public struct Menu: Equatable, Sendable {
        public var id: Int
        public var title: String
        public var left: Int
        public var isApple: Bool
        public init(id: Int, title: String, left: Int, isApple: Bool) {
            self.id = id; self.title = title
            self.left = left; self.isApple = isApple
        }
    }

    public struct MenuItem: Equatable, Sendable {
        public var menu: Menu
        /// 1-based, as the Menu Manager counts.
        public var index: Int
        public var title: String
        /// The command-key character, empty when the item has none.
        public var cmd: String
        public var isEnabled: Bool
        public var isSeparator: Bool
        public init(menu: Menu, index: Int, title: String, cmd: String,
                    isEnabled: Bool, isSeparator: Bool) {
            self.menu = menu; self.index = index; self.title = title
            self.cmd = cmd; self.isEnabled = isEnabled
            self.isSeparator = isSeparator
        }
    }

    public struct App: Equatable, Sendable {
        public var psn: String
        public var name: String
        public var isFront: Bool
        public init(psn: String, name: String, isFront: Bool) {
            self.psn = psn; self.name = name; self.isFront = isFront
        }
    }

    public struct FinderItem: Equatable, Sendable {
        public var name: String
        /// nil means the desktop. A window means that folder's window,
        /// and the Finder addresses the two differently.
        public var container: Window?
        /// Where the FINDER says the icon is, not where the pointer
        /// landed — kept because a driver with no other route can still
        /// click it, and because it is how the icon is drawn.
        public var point: Point
        public init(name: String, container: Window?, point: Point) {
            self.name = name; self.container = container; self.point = point
        }
    }

    // MARK: - Reading an object

    /// A short phrase naming this object, for a status line a person
    /// reads. "the close box of System Folder" beats "widget".
    public var describedForAPerson: String {
        switch self {
        case .window(let w):
            let what: String
            switch w.part {
            case .titleBar: what = "the title bar of"
            case .closeBox: what = "the close box of"
            case .zoomBox: what = "the zoom box of"
            case .collapseBox: what = "the collapse box of"
            case .growBox: what = "the size box of"
            case .content: what = "the content of"
            }
            return "\(what) \(w.title.isEmpty ? "an untitled window" : w.title)"
        case .control(let c):
            if let part = c.part { return "the \(part) of a scroll bar" }
            return c.title.isEmpty ? "a control" : "\"\(c.title)\""
        case .menu(let m):
            return m.isApple ? "the Apple menu" : "the \(m.title) menu"
        case .menuItem(let i):
            return "\"\(i.title)\""
        case .app(let a):
            return a.name
        case .desktop:
            return "the desktop"
        case .finderItem(let f):
            return "\"\(f.name)\""
        }
    }

    /// The window this object belongs to, when it belongs to one. Used
    /// by drivers that must front a window before acting in it.
    public var owningWindow: Window? {
        switch self {
        case .window(let w): return w
        case .control(let c): return c.window
        case .finderItem(let f): return f.container
        case .menu, .menuItem, .app, .desktop: return nil
        }
    }
}

/// A point on the guest's screen, in its own coordinates.
public struct Point: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// **What the hand did.** The point rides HERE, as metadata, rather than
/// being the thing acted upon — a driver may use it (to pick a scroll
/// bar part), ignore it (a menu command is the same wherever the row was
/// drawn), or refuse to be positioned by it at all.
public enum MirrorGesture: Equatable, Sendable {
    /// `at` is where the press landed, in guest coordinates. Present
    /// even when nothing needs it, because a driver that wants to fall
    /// back to a positional click should not have to re-derive it.
    case click(count: Int, mods: Int, at: Point)
    case drag(from: Point, to: Point, mods: Int)
    /// Scroll wheel, in notches. Positive scrolls the content down.
    case scroll(notches: Int, at: Point)
    /// Text a person typed, to land wherever the guest's focus is.
    case type(String)
    /// One keystroke. `code` is the virtual keycode, which is what a
    /// Mac's MenuEvent matches on - the character alone is not enough
    /// and that has cost this project a day before.
    case key(code: Int, char: Int, mods: Int)
}

/// One thing a person did to one thing on the guest.
public struct Interaction: Equatable, Sendable {
    public var object: MirrorObject
    public var gesture: MirrorGesture
    public init(object: MirrorObject, gesture: MirrorGesture) {
        self.object = object
        self.gesture = gesture
    }
}
