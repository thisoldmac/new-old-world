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
/// ### The standing hazard
///
/// A whole-disk Finder search wedged a real machine for ~12 minutes (lab
/// finding, 2026-07-05). Every script here is scoped to a window the Finder is
/// already showing — `window i`, `items of window i` — and never searches for
/// a name.
public enum FinderItems {

    /// The Finder's icon box: `bounds of` an item is `position … position+32`.
    /// Measured, not assumed (see the table above).
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
            "set q to position of t",
            "set r to r & \"I|\" & (name of t) & \"|\" & (item 1 of q) & \",\""
                + " & (item 2 of q) & \";;\"",
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

    /// A name and the Finder's live window-content-local position for it.
    public struct Placed: Equatable {
        public var name: String
        public var x: Int
        public var y: Int
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
                let coords = fields[2].split(separator: ",")
                guard coords.count == 2,
                      let x = Int(coords[0].trimmingCharacters(in: .whitespaces)),
                      let y = Int(coords[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                out[out.count - 1].items.append(
                    .init(name: fields[1], x: x, y: y))
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
        let cx = item.x + iconSize / 2
        let cy = item.y + iconSize / 2
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
