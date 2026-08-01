import Foundation

/// The scene's pure geometry: the arithmetic that reads a scene rather than
/// fetches one.
///
/// **Why this file exists.** These functions were static members of
/// `ScenePoller`, which was upstream's transport — a `WireClient` loop that
/// asked a TimBotTu toolkit worker for `axtree`, `list`, `video` and
/// `qdtrace`. NOW's guest does not serve that protocol and NOW's host already
/// owns the one wire a scene may arrive on
/// (`GuestListener.requestScene` → `NOWSceneCodec` → `MirrorSceneAdapter`),
/// so the loop was deleted rather than adapted. The measurements it carried
/// were not: a content inset calibrated against Mac OS 9.1, an occlusion rule
/// derived from what a screen-region capture actually returns, and a scroll
/// detector written from real `qdtrace` output are evidence, and re-deriving
/// them without a Macintosh would be waste rather than rigour
/// (`PORTING.md`, "the archaeology").
///
/// Everything here is a function of values already in hand. Nothing in this
/// file opens a socket, and that is the property `NoSecondWireTests` holds
/// the whole module to.
public enum SceneGeometry {

    /// The window's content area in GUEST coords — the same inset the
    /// renderer uses, so a captured island lands pixel-aligned rather than
    /// needing its own calibration. A dialog (`kind == 2`) has no title bar
    /// and a uniform 6 px frame; a document window's 22 px top is its title
    /// bar.
    public static func contentRect(_ win: Scene.Window) -> Rect {
        let isDialog = win.kind == 2
        return Rect(l: win.rect.l + (isDialog ? 6 : 1),
                    t: win.rect.t + (isDialog ? 6 : 22),
                    r: win.rect.r - (isDialog ? 6 : 1),
                    b: win.rect.b - (isDialog ? 6 : 1))
    }

    /// Is the window at `index` covered by any window in front of it?
    ///
    /// Scene order is front-first, so "in front of" means a lower index. Any
    /// intersection at all counts: a partially covered window would capture a
    /// seam of the window on top, and half-wrong pixels presented as a
    /// window's contents are worse than an honest blank.
    public static func isOccluded(_ windows: [Scene.Window],
                                  index: Int) -> Bool {
        let mine = contentRect(windows[index])
        guard mine.width > 0, mine.height > 0 else { return true }
        for j in 0..<index {
            let other = windows[j]
            guard other.visible,
                  !HitTester.isDesktopBackdrop(other) else { continue }
            let r = other.rect
            let overlaps = r.l < mine.r && r.r > mine.l
                        && r.t < mine.b && r.b > mine.t
            if overlaps { return true }
        }
        return false
    }

    /// The newest screen→screen move among ops we haven't accounted for: same
    /// size, actually displaced, and sourced from inside the content we hold.
    /// A scroll is a blit, and recognising it is what lets held pixels be
    /// shifted instead of re-fetched.
    public static func newestMove(_ ops: [DisplayOp], content: Rect,
                                  since: Int) -> (dx: Int, dy: Int, tick: Int)? {
        var best: (dx: Int, dy: Int, tick: Int)?
        let cw = content.r - content.l, ch = content.b - content.t
        for op in ops where op.op == "bits" && op.ticks > since {
            guard let s = op.src, let d = op.dst,
                  s.count == 4, d.count == 4 else { continue }
            let sw = s[2] - s[0], sh = s[3] - s[1]
            guard sw == d[2] - d[0], sh == d[3] - d[1] else { continue }
            let dx = d[0] - s[0], dy = d[1] - s[1]
            guard dx != 0 || dy != 0 else { continue }
            // src must be pixels we hold: inside the content, and a real slab
            // of it (a 16x16 scrollbar-arrow composite is not a scroll).
            guard s[0] >= 0, s[1] >= 0, s[2] <= cw + 4, s[3] <= ch + 4,
                  sw * sh > (cw * ch) / 4 else { continue }
            if best == nil || op.ticks > best!.tick {
                best = (dx, dy, op.ticks)
            }
        }
        return best
    }

    /// The Finder's default disk layout: top-right, stacked downward. Used
    /// only for volumes a producer reported as unplaced — a real position,
    /// when we can get one, always wins.
    public static func placeVolumes(
        _ vols: [Scene.DesktopItem],
        screen: Scene.ScreenSize) -> [Scene.DesktopItem] {
        let right = screen.w > 0 ? screen.w : 800
        var out: [Scene.DesktopItem] = []
        for (i, v) in vols.enumerated() where !v.invisible {
            var item = v
            if !item.placed {
                item.x = right - 76          // icon box inset from the right
                item.y = 12 + i * 64         // one row per disk, top down
                item.placed = true
            }
            out.append(item)
        }
        return out
    }

    /// Split a scene's `"hi.lo"` process serial into its two halves.
    ///
    /// Kept because a `ProcessSerialNumber` is two 32-bit halves everywhere
    /// it appears — NOW's own act plane takes `serialHi`/`serialLo` as a pair
    /// for the same reason (`AgentIntegrationProcessSerial`) — and a scene
    /// carries the pair joined into one string.
    public static func psnParts(_ psn: String) -> (Int, Int) {
        let parts = psn.split(separator: ".")
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }
}
