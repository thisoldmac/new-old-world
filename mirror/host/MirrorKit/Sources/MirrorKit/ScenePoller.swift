import Foundation

/// One live scene fetch: wire → raw result → SceneBuilder, with latency and
/// byte accounting in `meta`. The poll *loop* (timers, cadence, callbacks)
/// belongs to the head that owns the run loop; this is the single step both
/// heads share.
public struct ScenePoller {
    public let target: MirrorTarget
    public let wire: WireClient
    /// Guest screen size — passed through into every scene. Starts
    /// `unknown`, because at construction no guest has said: `detectScreen`
    /// asks the machine. A poller that never detected publishes scenes
    /// carrying `unknown`, which every consumer must handle, rather than a
    /// plausible number nobody can tell from an answer.
    public var screen: Scene.ScreenSize

    private var seq = 0

    public init(target: MirrorTarget,
                screen: Scene.ScreenSize = .unknown,
                timeout: Double = 10.0) {
        self.target = target
        self.wire = WireClient(target: target, timeout: timeout)
        self.screen = screen
    }

    /// Share an existing wire (the toolkit worker serves ONE connection;
    /// the poller and the dispatcher must not each hold their own to the
    /// same worker, or the second is reset).
    public init(target: MirrorTarget, wire: WireClient,
                screen: Scene.ScreenSize = .unknown) {
        self.target = target
        self.wire = wire
        self.screen = screen
    }

    /// Learn the guest's real screen size from the `video` verb (main
    /// device's `gdRect`), so the render surface matches the guest at any
    /// resolution. Best-effort: leaves `screen` at `.unknown` if `video`
    /// isn't in scope or fails, and the returned value says so — a failed
    /// detection must not read as a screen. Call once before polling.
    @discardableResult
    public mutating func detectScreen() -> Scene.ScreenSize {
        if let (result, _) = try? wire.request("video"),
           let devices = result["devices"] as? [Any] {
            // Prefer the main device; fall back to the first.
            let dicts = devices.compactMap { $0 as? [String: Any] }
            let dev = dicts.first { ($0["main"] as? NSNumber)?.boolValue == true }
                ?? dicts.first
            if let bounds = dev?["bounds"] as? [Any], bounds.count == 4 {
                // bounds = [top, left, bottom, right].
                let t = SceneBuilder.intValue(bounds[0]) ?? 0
                let l = SceneBuilder.intValue(bounds[1]) ?? 0
                let b = SceneBuilder.intValue(bounds[2]) ?? 0
                let r = SceneBuilder.intValue(bounds[3]) ?? 0
                if r > l, b > t {
                    screen = .init(w: r - l, h: b - t)
                }
            }
        }
        return screen
    }

    /// Fetch one scene. Uses `axtree` (the AXPeek window/menu plane); a
    /// worker without AXPeek in reach still answers `observe` — the caller
    /// picks the plane via `plane`.
    public enum Plane: String {
        case axtree
        case observe
    }

    /// Fetch desktop icons too (an extra `list` call per poll). Off by
    /// default so a caller can opt in; the live app turns it on.
    public var includeDesktopItems = false

    /// Fetch Finder-window icon-view items — ON since lane H2 (2026-07-31).
    ///
    /// It was off because the only source we had was `fdLocation`, the SAVED
    /// icon grid, which the Finder does not draw from once a window is laid
    /// out or scrolled. The Finder does expose live positions after all —
    /// `position of` an item of a window, which is window-content-local and
    /// scroll-compensated (`FinderItems`). Measured by clicking a computed
    /// point and asking the Finder which file got selected, which is the only
    /// oracle that means anything here.
    public var includeWindowItems = true

    /// Fetch the QuickDraw content plane (QDPeek `qdtrace`) for the front app
    /// and attach it to the front window's `display`. Off by default — it
    /// installs draw-time hooks on the guest (optional toolkit + QDPeek
    /// required). A failed qdtrace just leaves `display` nil.
    public var includeDisplay = false

    private var tracedPSN: String?
    private var displayCursor = 0
    private var displayOps: [DisplayOp] = []
    /// Bounded accumulation: keep the most recent ops (a full window redraw
    /// re-emits the visible content, so this converges to the current frame).
    private let displayCap = 600

    public mutating func poll(_ plane: Plane = .axtree,
                              now: Date = Date()) throws -> Scene {
        seq += 1
        let started = DispatchTime.now()
        let capturedAt = now.timeIntervalSince1970
        var scene: Scene
        switch plane {
        case .axtree:
            let (result, bytes) = try wire.request(
                "axtree", ["scope": target.scope])
            scene = SceneBuilder.sceneFromAxtree(
                result, seq: seq, screen: screen, capturedAt: capturedAt,
                latencyMs: elapsedMs(since: started), bytes: bytes)
            // scope=all can land with NO app marked front, and then there is no
            // menubar and no front window at all — measured 2026-07-30, where
            // the actual front app (Apple System Profiler) was absent from the
            // all-walk entirely while scope=front sampled it fine and returned
            // its 7 menus. The two scopes disagree about which processes they
            // enumerate, so `all` buys background windows and loses the menus.
            //
            // Rather than choose, ask for both: one extra scope=front call
            // (~2 ms) supplies the menubar and
            // the front attribution that `all` could not. Only when `all` came
            // back without a front app, so the common case pays nothing.
            if target.scope == "all" && scene.menubar == nil {
                if let (front, _) = try? wire.request(
                        "axtree", ["scope": "front"]) {
                    let f = SceneBuilder.sceneFromAxtree(
                        front, seq: seq, screen: screen,
                        capturedAt: capturedAt, latencyMs: nil, bytes: nil)
                    scene.menubar = f.menubar
                    scene.apps = mergeFrontApp(scene.apps, from: f.apps)
                }
            }
        case .observe:
            let (result, bytes) = try wire.request("observe")
            scene = SceneBuilder.sceneFromObserve(
                result, seq: seq, screen: screen, capturedAt: capturedAt,
                latencyMs: elapsedMs(since: started), bytes: bytes)
        }
        if includeDesktopItems {
            // A failed list must not blank the desktop or kill the poll —
            // keep the scene, leave items nil.
            if let (result, _) = try? wire.request(
                "list", ["path": "Macintosh HD:Desktop Folder"]) {
                scene.desktopItems = SceneBuilder.desktopItems(from: result)
            }
            // Mounted volumes aren't Desktop Folder entries, so `list` never
            // sees them and the mirror's desktop was missing its disks. Ask the
            // guest's File Manager directly.
            //
            // This used to go through AppleScript (`position of every disk`),
            // which reported the Finder's real coordinates — but it needs a
            // `script` verb this agent does not have, so the request failed
            // silently into `try?` and the disks simply never appeared. The
            // File Manager can enumerate volumes cheaply; what it cannot know is
            // where the Finder chose to draw them, since that lives in the
            // Finder's own desktop database. So the guest reports `placed:false`
            // and we lay them out by the Finder's default rule rather than
            // inventing coordinates and drawing them confidently in the wrong
            // place.
            if let (result, _) = try? wire.request("volumes"),
               let vols = SceneBuilder.volumeItems(from: result) {
                scene.desktopItems = (scene.desktopItems ?? [])
                    + Self.placeVolumes(vols, screen: screen)
            }
        }
        /* One script serves both, so either flag pays for it. A caller that
           wants desktop items and not window items still gets the desktop's
           DRAWN boxes rather than the saved grid — which is the difference
           between an addressable desktop and a decorative one. */
        if includeWindowItems || includeDesktopItems {
            attachWindowItems(&scene)
        }
        if includeDisplay,
           let frontIdx = scene.windows.firstIndex(where: { $0.front }) {
            fetchDisplay(frontPSN: scene.windows[frontIdx].psn)
            scene.windows[frontIdx].display = displayOps
        }
        return scene
    }

    /* THE PIXEL ISLANDS USED TO BE FETCHED HERE, and they are gone
       (2026-08-07). `attachIslands` / `island(for:)` / `capture` asked the
       guest for `capture` and put the returned framebuffer bytes on
       `Scene.Window.island`, which the renderer then drew in place of the
       content.

       The rule they broke, stated by Michelle the same day:

         "the only time we should be using pixels from the guest is when we
          have imported those assets as part of our assets pack, so the
          pixels are provided by the host and not the wire."

       Everything else in this file already obeys it: the display drain
       carries GEOMETRY and identity, and the art comes from `IconAtlas` on
       this side. `wire.captureRegion` was the one path that carried pixels,
       and it was also the reason every render comparison against those
       windows was comparing the guest's pixels with themselves.

       `isOccluded` / `contentRect` went with them — both existed only to
       make a capture truthful, and neither had another caller.

       Prior art for a later deliberate re-implementation:
       `archive/pixel-islands-2026-08-07/`. */

    /* A `disksScript` / `diskItems` pair used to sit here: an unreferenced
       AppleScript asking `position of` every disk, and a parser for its
       output. Nothing called either. Deleted with the desktop clause of
       `FinderItems.windowsScript`, which asks the same machine the same
       question in the one place every other surface's geometry now comes
       from — and asks for `bounds` rather than `position`, which is the
       correction the list-view lane paid for. Two seams for one decision is
       the defect this arc has merged away twice. */

    /// (Re)trace the front app and drain its new draw ops into the bounded
    /// accumulator. Switching front apps restarts the trace and clears the
    /// buffer. All wire calls are best-effort — a missing QDPeek/qdtrace just
    /// leaves the ops empty.
    /// Fold the front-scope walk's front app into the all-scope app list, so
    /// the scene agrees with itself about who is frontmost. Matching is by PSN:
    /// names repeat and are not identity.
    private func mergeFrontApp(_ apps: [Scene.AppRef],
                               from frontApps: [Scene.AppRef]) -> [Scene.AppRef] {
        guard let front = frontApps.first(where: { $0.front }) else { return apps }
        var out = apps.map { app -> Scene.AppRef in
            var a = app
            a.front = (a.psn == front.psn)
            return a
        }
        if !out.contains(where: { $0.psn == front.psn }) {
            out.insert(front, at: 0)   // absent from the all-walk entirely
        }
        return out
    }

    /// The Finder's default disk layout: top-right, stacked downward. Used only
    /// for volumes the guest reported as unplaced — a real position, when we can
    /// get one, always wins.
    ///
    /// **This function invents coordinates, and now says so.** It used to set
    /// `placed = true` alongside them, which made the mirror's one "do we know
    /// where this is?" flag read `true` for the single case where the answer
    /// was ours rather than the guest's. Drawing an invented disk is a
    /// defensible trade — a disk that is absent from the picture is worse than
    /// one a few inches from where the Finder put it — but aiming at one is
    /// not, and `origin: .unknown` is what separates the two.
    ///
    /// The desktop clause of `FinderItems.windowsScript` normally gets there
    /// first with the drawn box, so this is the fallback for a guest whose
    /// Finder would not answer.
    ///
    /// **An unknown screen has no right edge**, so nothing is placed: the
    /// volumes come back exactly as the guest gave them, still unplaced.
    /// Inventing a width here put icons at 800-minus-an-inset on a machine
    /// nobody had measured, which reads as a position rather than a guess.
    static func placeVolumes(_ vols: [Scene.DesktopItem],
                             screen: Scene.ScreenSize) -> [Scene.DesktopItem] {
        guard let screen = screen.known else { return vols }
        let right = screen.w
        var out: [Scene.DesktopItem] = []
        for (i, v) in vols.enumerated() where !v.invisible {
            var item = v
            if !item.placed {
                item.x = right - 76          // icon box inset from the right edge
                item.y = 12 + i * 64         // one row per disk, top down
                item.placed = true
                item.origin = .unknown
            }
            out.append(item)
        }
        return out
    }

    private mutating func fetchDisplay(frontPSN: String) {
        if tracedPSN != frontPSN {
            let (hi, lo) = Self.psnParts(frontPSN)
            _ = try? wire.request("qdtrace",
                ["cmd": "start", "serialHi": hi, "serialLo": lo,
                 "mode": "record"])
            tracedPSN = frontPSN
            displayCursor = 0
            displayOps = []
        }
        for _ in 0..<8 {
            guard let (result, _) = try? wire.request("qdtrace",
                ["cmd": "fetch", "cursor": displayCursor,
                 "maxBytes": 4096]) else { break }
            let ops = (result["ops"] as? [Any] ?? [])
                .compactMap { ($0 as? [String: Any]).flatMap(DisplayOp.init) }
            displayOps.append(contentsOf: ops)
            let next = SceneBuilder.intValue(result["nextCursor"]) ?? displayCursor
            if next == displayCursor { break }
            displayCursor = next
        }
        if displayOps.count > displayCap {
            displayOps.removeFirst(displayOps.count - displayCap)
        }
    }

    /// Stop tracing (uninstall the guest hooks). The live head calls this when
    /// content mode turns off or the window closes.
    public mutating func stopDisplay() {
        _ = try? wire.request("qdtrace", ["cmd": "stop"])
        tracedPSN = nil
        displayCursor = 0
        displayOps = []
    }

    static func psnParts(_ psn: String) -> (Int, Int) {
        let parts = psn.split(separator: ".")
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    // MARK: - Finder folder windows as named items

    /// Last snapshot of what the Finder said, keyed by window title.
    private var windowItems: [String: [Scene.DesktopItem]] = [:]
    /// Window title → the folder's HFS path (`item of window`), which is what
    /// a semantic open acts on.
    public private(set) var finderPaths: [String: String] = [:]
    /// Titles whose item list the Finder truncated at our cap.
    public private(set) var truncatedWindows: Set<String> = []
    /// The desktop's own drawn boxes, keyed by item name, from the same
    /// script. Empty until the Finder has answered once.
    private var desktopDrawn: [FinderItems.Placed] = []
    /// The Finder had more desktop items than the cap.
    public private(set) var desktopTruncated = false
    /// The layout signature the snapshot was taken at.
    private var itemsSignature = ""

    /// What could have changed the DESKTOP's layout, as far as anything we can
    /// see cheaply goes: which items are on it, and how big the screen is.
    ///
    /// It cannot see a drag the human performed at the machine — nothing on
    /// this side can, short of paying the Finder round trip every poll. That
    /// is the same bargain the folder-window snapshot already strikes, and it
    /// carries the same rule: a cached position is fine to **draw** and not
    /// fine to **aim with**. Every act path calls `refreshWindowItems()`
    /// first, which is what makes a stale box a cosmetic error rather than a
    /// file dropped in the wrong place.
    private static func desktopSignature(_ scene: Scene) -> String {
        let names = (scene.desktopItems ?? []).map(\.name).sorted()
        return "DESK:\(scene.screen.w)x\(scene.screen.h)/"
            + names.joined(separator: ",")
    }

    /// Attach the Finder's own item positions to every folder window.
    ///
    /// **Cached, deliberately.** One `script` round trip through the Finder
    /// costs 1–2 s (measured 2026-07-31) — an order of magnitude more than a
    /// whole poll, so paying it every poll would make the mirror unusable.
    /// The refresh trigger is a layout signature over every folder window's
    /// geometry AND its scroll values, so a scroll (which moves every reported
    /// position by exactly the scroll delta) invalidates the snapshot. What is
    /// cached is never *silently* stale: any change we can observe re-fetches.
    mutating func attachWindowItems(_ scene: inout Scene) {
        let folders = scene.windows.filter(FinderItems.isFolderWindow)
        /* NOT gated on there being a folder window. The desktop rides in the
           same script, and the case where a person drags a desktop icon with
           no folder open is the ORDINARY one — an early return here is how
           the desktop kept its saved-grid positions while every window had
           the Finder's drawn ones. */
        let signature = (folders.map(FinderItems.layoutKey)
                         + [Self.desktopSignature(scene)])
            .joined(separator: "|")
        if signature != itemsSignature {
            // Only remember the signature when the Finder actually answered.
            // A failed script call that still marked the layout "done" would
            // CACHE THE FAILURE until the window next moved — measured
            // 2026-07-31, where one busy-Finder timeout left a live folder
            // window with no items for the life of the process.
            if refreshWindowItems(folders: folders) {
                itemsSignature = signature
            }
        }
        // Two windows showing same-named folders are indistinguishable by the
        // only key the Finder gives us, so neither gets items rather than one
        // getting the other's. A wrong-but-plausible position is the failure
        // this whole lane exists to remove.
        var seen: [String: Int] = [:]
        for win in folders { seen[win.title, default: 0] += 1 }
        for i in scene.windows.indices {
            let win = scene.windows[i]
            guard FinderItems.isFolderWindow(win), seen[win.title] == 1,
                  let items = windowItems[win.title] else { continue }
            scene.windows[i].items = items
        }
        if seen.values.contains(where: { $0 > 1 }) {
            scene.meta.errors.append("window_items_ambiguous_title")
        }
        /* The desktop climbs the ladder: whatever the catalog and the volume
           list built keeps its identity, and the Finder's drawn box replaces
           the saved grid and the invented stack. When the Finder said nothing,
           nothing is replaced and the items keep saying what they already
           said — which is the point of carrying the provenance at all. */
        if !desktopDrawn.isEmpty {
            scene.desktopItems = FinderItems.mergeDesktop(
                drawn: desktopDrawn, existing: scene.desktopItems ?? [])
        }
        if desktopTruncated {
            scene.meta.errors.append("desktop_items_truncated")
        }
    }

    /// Re-ask the Finder. Public so the act path can force freshness before it
    /// computes a click — a cached position is fine to *draw* and not fine to
    /// *aim with* if anything might have moved since.
    public mutating func refreshWindowItems() {
        itemsSignature = ""
    }

    /// Returns false when the Finder did not answer at all — the caller must
    /// not then treat this layout as resolved.
    @discardableResult
    private mutating func refreshWindowItems(folders: [Scene.Window]) -> Bool {
        guard let (result, _) = try? wire.request(
                "script", ["source": FinderItems.windowsScript(),
                           "timeoutMs": 20000]),
              let raw = result["output"] as? String else { return false }
        let reports = FinderItems.parse(raw)
        /* An answer with no window records is a real answer when no folder
           window is open — the desktop clause is the whole payload then. It is
           a FAILURE when folders were expected, which is the busy-Finder
           timeout this guard was written for. */
        guard !reports.isEmpty || folders.isEmpty else { return false }
        let desk = FinderItems.parseDesktop(raw)
        desktopDrawn = desk.items
        desktopTruncated = desk.truncated
        var items: [String: [Scene.DesktopItem]] = [:]
        var paths: [String: String] = [:]
        var truncated: Set<String> = []
        for report in reports {
            if !report.path.isEmpty { paths[report.title] = report.path }
            if report.truncated { truncated.insert(report.title) }
            // The catalog supplies kind/type/creator/alias — the icon art and
            // the "is it a folder" question. A failed `list` is not fatal:
            // position is what makes an item addressable, and that came from
            // the Finder.
            var catalog: [Scene.DesktopItem] = []
            if !report.path.isEmpty,
               let (listed, _) = try? wire.request("list",
                                                   ["path": report.path]) {
                catalog = SceneBuilder.desktopItems(from: listed)
            }
            items[report.title] = FinderItems.merge(placed: report.items,
                                                    catalog: catalog)
        }
        windowItems = items
        finderPaths = paths
        truncatedWindows = truncated
        return true
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds
               - start.uptimeNanoseconds) / 1e6
    }
}
