import Foundation

/// Finder folder windows as **named items**, not pixels.
///
/// A folder window was the last surface the mirror showed as a photograph: an
/// island of captured pixels, which an agent can see and cannot address. This
/// is the model that replaces it.
///
/// ## Where the numbers come from (measured 2026-07-31, mac99, OS 9.1)
///
/// The Finder answers three questions about a window it is showing, and each
/// answer was checked against the guest rather than against our own
/// arithmetic — the oracle for a position is *clicking it and being told which
/// file got selected*.
///
/// | Question | Answer | How it was checked |
/// |---|---|---|
/// | `item of window i` | the folder's HFS path | resolves subfolders, disk roots |
/// | `position of` an item | **live, window-content-local, scroll-compensated** | scrolling the window by 128 px moved every reported `y` by exactly −128 |
/// | `bounds of` an item | `position … position + 32` | the icon box is 32×32 with its top-left at `position` |
///
/// So an item's point on screen is simply the window's content origin plus its
/// position, and that was measured by clicking: 13/13 visible items selected
/// themselves, across both a scrolled and an unscrolled window.
///
/// ### `position` is NOT `fdLocation`
///
/// This is the correction that made the feature possible. The earlier attempt
/// read `fdLocation` out of the catalog (the `list` verb) and rendered items a
/// few pixels off, which is cosmetically fine and functionally fatal — a click
/// computed from a wrong position hits the wrong file. `fdLocation` is the
/// *saved* icon grid; the Finder's `position` is where the Finder has actually
/// laid the icon out **now**. On the probe folder the two differed by a
/// constant (52, 25) at rest and diverged completely once the window scrolled,
/// which is exactly the case the saved grid cannot see.
///
/// ### The table above was measured in ONE view (corrected 2026-08-07)
///
/// Every number above was taken from a window in **icon view**, and the row
/// that says `position of` is "live, window-content-local, scroll-compensated"
/// is only true there. Measured on mac99 / OS 9.1 against a window drawing a
/// ten-row list, with a screendump beside the answer:
///
/// | View (`view of window 1`) | `position of` item 1 | `bounds of` item 1 |
/// |---|---|---|
/// | `icon` | 34, 25 | 34, 25, 66, 57 — position + 32 |
/// | `small icon` | 35, 25 (a DIFFERENT grid) | 16×16 |
/// | `name` (the list) | **2, 42 — the saved icon grid, not a row** | 22, 43, 38, 59 — the row's icon, 19-px pitch |
///
/// So in a list view `position` answers the icon grid the window is not
/// drawing, and a reader that trusts it computes a click for a layout that is
/// not on screen. This is the defect Michelle named as "unable to select items
/// in list view".
///
/// **`bounds of` is the cure, and it is one property in every view.** It is
/// the box the Finder actually drew: identical to `position … position + 32`
/// in icon view (so nothing that was right becomes wrong), the live 16×16 row
/// icon in list view, and the live small-icon box in small-icon view. It also
/// answers for `every item of desktop`. Every producer here therefore asks for
/// `bounds` and none asks for `position`.
///
/// ### The Finder's view vocabulary, measured (2026-08-07, mac99 / OS 9.1)
///
/// Recorded because it had never been measured, and guessing it was the reason
/// this defect was left open rather than closed with a plausible wrong answer.
///
/// - `view of window 1` **works**. Its class renders as `«class pvew»`.
/// - Its value has no string coercion: `(view of window 1) as string` raises
///   **-1700**, "Can't make «class pvew» of window 1 ... into a string".
///   Concatenating it (`"[" & v & "]"`) does render it, as a bare word.
/// - The words, raw: **`icon`**, **`name`** (this is the list view — confirmed
///   against a screendump of the window drawing rows), **`small icon`**. They
///   are also the setter's vocabulary: `set view of window 1 to name` works.
///
/// What did NOT work, recorded because a failure saves the next reader a VM:
///
/// - `current view of window 1` — not a term. **osaErr -1753 for the whole
///   script**, which is the trap: an unknown term is a COMPILE failure, so a
///   `try` block around it does not catch it and it takes every other phrasing
///   in the same script down with it. Probe one phrasing per script.
/// - `properties of window 1` — **-1728**, "Can't get properties of window 1".
///   There is no property dump to enumerate the vocabulary from.
/// - `set view of window 1 to list view` / `button view` — **-1728**, "Can't
///   get view"; `buttons` / `button` — **-2753**, "The variable ... is not
///   defined". These are the modern Finder's words and OS 9 does not have
///   them. `set view of window 1 to list` compiles and raises **-15279**,
///   "Value out of range" — `list` is the class, not the view.
/// - The raw four-character enum was not pinned. Comparing against
///   `«constant ****icnv»`, `nmev`, `lisv`, `ivew`, `nvew`, `bvew`, `sicv`,
///   `btnv` answered false or silently did nothing; only `«constant ****smic»`
///   round-tripped, to `small icon`. The bare words are what reaches the wire
///   and what the code uses, so this was left unfinished rather than guessed.
/// - A guest `script` source is capped at **2048 bytes** — a batched probe
///   over more than ~5 phrasings is refused with `too-large`.
///
/// Nothing in this project reads the view today: `bounds` made the geometry
/// right in every view, so a carried `view` would be a field with no reader,
/// which is its own defect class. It is written down here so that the next
/// lane that needs it does not spend a VM re-deriving it.
///
/// ### The standing hazard
///
/// A whole-disk Finder search wedged a real machine for ~12 minutes (lab
/// finding, 2026-07-05). Every script here is scoped to a window the Finder is
/// already showing — `window i`, `items of window i` — and never searches for
/// a name.
public enum FinderItems {

    /// The icon VIEW's box: `bounds of` an item is `position … position+32`
    /// there. Measured, not assumed (see the table above) — and it is the
    /// icon view's number only, which is why nothing computes a box from it
    /// any more when the Finder was asked for one.
    public static let iconSize = 32

    /// Cap on items reported per window. A folder with a thousand files would
    /// blow the guest's 4 KB script-result buffer and cost seconds of Finder
    /// time; the cap makes the truncation explicit instead.
    public static let maxItemsPerWindow = 60

    // MARK: - The script

    /// Every Finder window: its name, its folder path, and its items with the
    /// Finder's own live positions.
    ///
    /// One call for all windows, because a call costs ~1–2 s of Finder time
    /// (measured) — far too much to pay per window, let alone per poll.
    public static func windowsScript(maxItems: Int = maxItemsPerWindow) -> String {
        [
            "tell application \"Finder\"",
            "set r to \"\"",
            "repeat with i from 1 to (count windows)",
            "set w to window i",
            "set p to \"\"",
            "try",
            "set p to (item of w) as text",
            "end try",
            "set r to r & \"W|\" & (name of w) & \"|\" & p & \";;\"",
            "set n to 0",
            "try",
            "repeat with t in (get items of w)",
            "set n to n + 1",
            "if n > \(maxItems) then",
            "set r to r & \"T|;;\"",
            "exit repeat",
            "end if",
            /* `bounds`, never `position`: in a LIST view `position` answers
               the saved icon grid the window is not drawing. See the view
               table in this file's header. */
            "set q to bounds of t",
            "set r to r & \"I|\" & (name of t) & \"|\" & (item 1 of q) & \",\""
                + " & (item 2 of q) & \",\" & (item 3 of q) & \",\""
                + " & (item 4 of q) & \";;\"",
            "end repeat",
            "end try",
            "end repeat",
            "return r",
            "end tell",
        ].joined(separator: "\n")
    }

    /// One Finder window as the script reported it.
    public struct WindowReport: Equatable {
        public var title: String
        /// HFS path of the folder the window shows; empty when the Finder
        /// would not say (a window that is not a folder view).
        public var path: String
        public var items: [Placed]
        /// The Finder had more items than `maxItems`.
        public var truncated: Bool
    }

    /// A name and the Finder's live window-content-local BOX for it — the
    /// top-left is the old `position`, and the size is what tells a 16×16
    /// list row from a 32×32 icon.
    public struct Placed: Equatable {
        public var name: String
        public var x: Int
        public var y: Int
        /// nil when the record carried a bare `x,y` pair: an older fixture,
        /// or a producer that has not been moved to `bounds` yet.
        public var w: Int?
        public var h: Int?

        public init(name: String, x: Int, y: Int,
                    w: Int? = nil, h: Int? = nil) {
            self.name = name; self.x = x; self.y = y
            self.w = w; self.h = h
        }
    }

    /// Parse the script's `W|`/`I|`/`T|` record stream.
    ///
    /// A trailing partial record (the guest truncated the result at its buffer
    /// cap) has no `;;` terminator and is dropped by construction — a half-read
    /// position would be a plausible lie, which is the one thing this lane may
    /// not ship.
    public static func parse(_ output: String) -> [WindowReport] {
        var raw = output
        // OSADoScript renders its result in SOURCE form, so a text result
        // arrives wrapped in quotes.
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        var out: [WindowReport] = []
        for record in raw.components(separatedBy: ";;") where !record.isEmpty {
            let fields = record.components(separatedBy: "|")
            switch fields.first {
            case "W":
                guard fields.count >= 3 else { continue }
                out.append(.init(title: fields[1], path: fields[2],
                                 items: [], truncated: false))
            case "I":
                guard fields.count >= 3, !out.isEmpty else { continue }
                /* Two numbers is a bare position (an older record); four is
                   `bounds`. Anything else is a partial read and is dropped
                   rather than half-believed. */
                let coords = fields[2].split(separator: ",").map {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
                guard coords.count == 2 || coords.count == 4,
                      !coords.contains(where: { $0 == nil }) else { continue }
                let n = coords.map { $0! }
                out[out.count - 1].items.append(
                    .init(name: fields[1], x: n[0], y: n[1],
                          w: coords.count == 4 ? n[2] - n[0] : nil,
                          h: coords.count == 4 ? n[3] - n[1] : nil))
            case "T":
                if !out.isEmpty { out[out.count - 1].truncated = true }
            default:
                continue
            }
        }
        return out
    }

    // MARK: - Joining identity to position

    /// The Finder says *what is in the window and where*; the catalog (`list`)
    /// says *what each thing is*. Each source answers only what it knows.
    ///
    /// The Finder is authoritative on membership: an item it does not show is
    /// not in the window, whatever the catalog holds (invisible files, and the
    /// items past a truncation cap). An item the Finder shows but the catalog
    /// did not describe is still carried — with a position, which is the part
    /// that makes it addressable — as a plain file.
    public static func merge(placed: [Placed],
                             catalog: [Scene.DesktopItem]) -> [Scene.DesktopItem] {
        var byName: [String: Scene.DesktopItem] = [:]
        for entry in catalog { byName[entry.name] = entry }
        return placed.map { p in
            var item = byName[p.name] ?? .init(
                name: p.name, kind: "file", type: nil, creator: nil,
                x: 0, y: 0, placed: false, alias: false, invisible: false)
            item.x = p.x
            item.y = p.y
            item.w = p.w
            item.h = p.h
            item.placed = true      // the Finder drew it; that IS placement
            return item
        }
    }

    // MARK: - Geometry

    /// The window's content origin in guest coords. The scene's window `rect`
    /// is the content port grown upward by the title bar, which is the same
    /// convention `HitTester` uses to make control rects content-local.
    public static func contentOrigin(_ win: Scene.Window) -> (x: Int, y: Int) {
        (win.rect.l, win.rect.t + SceneBuilder.titleBarHeight)
    }

    /// The part of a Finder window's content where icons are actually visible
    /// and clickable — content-local.
    ///
    /// Derived from the window's OWN scrollbars rather than from constants: a
    /// folder window's info bar ends where the vertical scrollbar begins, and
    /// the icon field ends where each scrollbar starts. No phantom constants,
    /// and it tracks a guest whose chrome metrics we never measured.
    ///
    /// Falls back to the whole content rect when a window has no scrollbars —
    /// every Finder folder window has both, so this is the honest default
    /// rather than a case we have seen.
    public static func iconArea(_ win: Scene.Window) -> Rect {
        let w = win.rect.r - win.rect.l
        let h = win.rect.b - (win.rect.t + SceneBuilder.titleBarHeight)
        var area = Rect(l: 0, t: 0, r: w, b: h)
        for ctl in win.controls where ctl.visible {
            guard let r = ctl.rect else { continue }
            let vertical = (r.b - r.t) > (r.r - r.l)
            if vertical {
                area.t = max(area.t, r.t)     // the info bar ends here
                area.r = min(area.r, r.l)
            } else {
                area.b = min(area.b, r.t)
            }
        }
        return area
    }

    /// The guest point to click to select `item` in `win`, or nil when the
    /// item is scrolled out from under the visible icon field.
    ///
    /// The point is the icon's own centre, not wherever a pointer happened to
    /// be — the same discipline `HitTester.desktopItem` already applies to the
    /// desktop. `nil` is a real answer: an item the Finder is not currently
    /// showing cannot be clicked, and inventing a point for it is how a click
    /// lands on the wrong file.
    public static func clickPoint(_ item: Scene.DesktopItem,
                                  in win: Scene.Window) -> (x: Int, y: Int)? {
        guard item.placed else { return nil }
        let area = iconArea(win)
        /* The centre of the box the FINDER drew. A constant 32/2 put the
           point 16 px below a 16-px list row — one row down at the Finder's
           19-px pitch, so the click landed on the next file. */
        let box = HitTester.targetSize(item)
        let cx = item.x + box.w / 2
        let cy = item.y + min(box.h, iconSize) / 2
        guard cx >= area.l, cx < area.r, cy >= area.t, cy < area.b else {
            return nil
        }
        let origin = contentOrigin(win)
        return (origin.x + cx, origin.y + cy)
    }

    /// Is this window one whose items we can resolve at all? The desktop
    /// backdrop is a Finder window too, and its icons are `desktopItems`.
    public static func isFolderWindow(_ win: Scene.Window) -> Bool {
        win.app == "Finder" && !HitTester.isDesktopBackdrop(win) && win.visible
    }

    /// A cache key that changes whenever the *layout* could have changed: the
    /// window's geometry, and its scroll positions. Scrolling moves every
    /// reported position, so a cache that ignored it would serve confidently
    /// wrong coordinates — the exact failure this lane exists to remove.
    public static func layoutKey(_ win: Scene.Window) -> String {
        let scrolls = win.controls
            .filter { $0.visible && $0.value != nil }
            .map { "\($0.value ?? 0)" }
            .joined(separator: ",")
        return "\(win.title)@\(win.rect.l),\(win.rect.t),\(win.rect.r),"
            + "\(win.rect.b)/\(scrolls)"
    }
}
