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
            // (~2 ms against ~150 ms of island capture) supplies the menubar and
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
        if includeWindowItems {
            attachWindowItems(&scene)
        }
        if includeDisplay,
           let frontIdx = scene.windows.firstIndex(where: { $0.front }) {
            fetchDisplay(frontPSN: scene.windows[frontIdx].psn)
            scene.windows[frontIdx].display = displayOps
        }
        // Islands are their own plane: the op stream is only a *hint* about
        // when to re-read the front window, so islands work (captured once,
        // then held) even with no qdtrace in reach.
        if includeIslands {
            attachIslands(&scene, poll: seq)
        }
        return scene
    }

    /// M3: fetch the front window's content as real pixels when it has changed,
    /// else reuse the cached island. A capture is ~1s for a full window, so it
    /// must not ride every poll — the guest tells us when to re-read: a window
    /// redraw lands a content-sized `bits` blit in the trace (the Finder
    /// composites offscreen and blits the result), so a big blit with a tick we
    /// haven't fetched at = new content. A moved/resized window re-fetches too,
    /// since its rect is part of the key.
    public var includeIslands = false

    /// The held pixels and their lifecycle bookkeeping. Internal (not private)
    /// so the keying and eviction rules can be tested without a guest.
    var islands = IslandStore()
    /// Pixels fetched for islands this session — the M3 bytes-per-frame meter.
    public private(set) var islandBytesFetched = 0

    /// How many polls a window may be absent from the scene before its pixels
    /// are dropped. Not zero on purpose: an app whose AXPeek sample errors
    /// mid-interaction vanishes from `axtree` for a frame or two (that's what
    /// LiveMirror's stale-window composite exists for), and a hidden app comes
    /// back with the same windows. Evicting on the first miss would throw the
    /// pixels away exactly when the mirror needs them most.
    public var islandGracePolls: Int {
        get { islands.gracePolls }
        set { islands.gracePolls = newValue }
    }

    /// Attach pixels to every window that has them, but re-capture only the
    /// FRONT one. A full-window capture is ~1 s on the wire, so capturing every
    /// window every poll is not an option — and it isn't needed: an interior
    /// only changes while its app is drawing, which (cooperatively) means while
    /// it is frontmost. So the lifecycle is: capture on launch/raise and while
    /// focused, then *hold* the last image. A window we have seen never goes
    /// back to blank.
    ///
    /// `poll` is the poll counter the eviction clock runs on — passed in rather
    /// than read from `seq` so the lifecycle is drivable in a test.
    mutating func attachIslands(_ scene: inout Scene, poll: Int) {
        let keys = IslandStore.keys(for: scene.windows)
        islands.touch(keys, seq: poll)
        for i in scene.windows.indices {
            // A window we have the SEMANTICS for does not need a photograph of
            // itself, and a capture costs ~1 s. This is the Finder folder
            // window, which is exactly the window islands were invented for —
            // the invention outlived its reason.
            if scene.windows[i].items != nil { continue }
            if scene.windows[i].front {
                scene.windows[i].island = island(for: scene.windows[i],
                                                 key: keys[i])
            } else if islands.pixels[keys[i]] == nil,
                      !Self.isOccluded(scene.windows, index: i) {
                // FIRST SIGHT. Retention can only hold what it has captured, so
                // a window that was already open when we attached has no last
                // state and would render as empty chrome until the human happens
                // to click it. Michelle's spec is "updated when launched, on
                // raise, and while focused" — an app launched under us IS front
                // and gets captured, but a window that predates us never was.
                // Capture it once, here, so it has something to hold.
                //
                // ONLY when nothing overlaps it. `capture` reads a SCREEN
                // region, so a covered window would return whatever is on top of
                // it — someone else's pixels, confidently mislabelled. That
                // hazard is almost certainly why the original design captured
                // the front window and nothing else. Occluded windows stay empty
                // until they are raised, which is correct-by-construction: being
                // raised is exactly what makes a capture truthful.
                scene.windows[i].island = island(for: scene.windows[i],
                                                 key: keys[i])
            } else if let held = islands.pixels[keys[i]] {
                // Stale-geometry decision: a window can be moved or resized
                // while unfocused, so a held island may not match the current
                // content rect. We attach it anyway, unscaled and anchored at
                // the content origin (the renderer clips it) — never dropped,
                // never stretched. Rationale: a resize doesn't change the
                // *content* pixels, only how much of them is visible, so
                // clipping is truthful for the shrink case and merely
                // incomplete for the grow case; scaling would invent pixels the
                // guest never drew (and Platinum's 1-bit art resamples into
                // mush); dropping would regress the window to blank, which is
                // the bug this is fixing. The mismatch is transient — the next
                // raise re-captures at the new size, since the content rect is
                // part of the capture key.
                scene.windows[i].island = held
            }
        }
        islands.evict(living: Set(keys), seq: poll)
    }

    private mutating func island(for win: Scene.Window,
                                 key cacheKey: String) -> PixelIsland? {
        let content = Self.contentRect(win)
        let cw = content.r - content.l, ch = content.b - content.t
        guard cw > 1, ch > 1 else { return nil }
        let area = cw * ch
        let seen = islands.tick[cacheKey] ?? 0

        // MoveBits fast-path: a scroll is a screen→screen blit — same size,
        // src inside the content we already hold. Move our own pixels and ask
        // the guest only for the band the move exposed, instead of re-reading
        // the whole window (refinement 1).
        if let cached = islands.pixels[cacheKey],
           let mv = Self.newestMove(displayOps, content: content, since: seen) {
            let (moved, exposed) = cached.shifted(dx: mv.dx, dy: mv.dy)
            var island = moved
            if let band = exposed, band.b > band.t {
                // Band in GUEST coords, then patch back at island-local y.
                if let fetched = try? capture(left: content.l + band.l,
                                              top: content.t + band.t,
                                              right: content.l + band.r,
                                              bottom: content.t + band.b) {
                    island = moved.patched(with: fetched, atX: band.l, y: band.t)
                }
            }
            islands.pixels[cacheKey] = island
            islands.tick[cacheKey] = mv.tick
            islands.contentKey[cacheKey] = "\(content.l),\(content.t),\(content.r),\(content.b)@\(mv.tick)"
            return island
        }

        // Otherwise: a content-sized blit is the guest repainting this window.
        let lastBlitTick = displayOps.compactMap { op -> Int? in
            guard op.op == "bits", let d = op.dst, d.count == 4,
                  (d[2] - d[0]) * (d[3] - d[1]) > area / 2 else { return nil }
            return op.ticks
        }.max() ?? 0
        let key = "\(content.l),\(content.t),\(content.r),\(content.b)@\(lastBlitTick)"
        if islands.contentKey[cacheKey] == key, let cached = islands.pixels[cacheKey] {
            return cached                                   // unchanged — reuse
        }
        guard let fetched = try? capture(left: content.l, top: content.t,
                                         right: content.r, bottom: content.b) else {
            return islands.pixels[cacheKey]             // keep the last good
        }
        islands.pixels[cacheKey] = fetched
        islands.contentKey[cacheKey] = key
        islands.tick[cacheKey] = lastBlitTick
        return fetched
    }

    private mutating func capture(left: Int, top: Int,
                                  right: Int, bottom: Int) throws -> PixelIsland {
        let island = try wire.captureRegion(left: left, top: top,
                                            right: right, bottom: bottom)
        islandBytesFetched += island.rgba.count
        return island
    }

    /// The newest screen→screen move among ops we haven't accounted for: same
    /// size, actually displaced, and sourced from inside the content we hold.
    static func newestMove(_ ops: [DisplayOp], content: Rect,
                           since: Int) -> (dx: Int, dy: Int, tick: Int)? {
        var best: (dx: Int, dy: Int, tick: Int)?
        let cw = content.r - content.l, ch = content.b - content.t
        for op in ops where op.op == "bits" && op.ticks > since {
            guard let s = op.src, let d = op.dst, s.count == 4, d.count == 4 else { continue }
            let sw = s[2] - s[0], sh = s[3] - s[1]
            guard sw == d[2] - d[0], sh == d[3] - d[1] else { continue }   // same size
            let dx = d[0] - s[0], dy = d[1] - s[1]
            guard dx != 0 || dy != 0 else { continue }                     // actually moved
            // src must be pixels we hold: inside the content, and a real slab
            // of it (a 16x16 scrollbar-arrow composite is not a scroll).
            guard s[0] >= 0, s[1] >= 0, s[2] <= cw + 4, s[3] <= ch + 4,
                  sw * sh > (cw * ch) / 4 else { continue }
            if best == nil || op.ticks > best!.tick { best = (dx, dy, op.ticks) }
        }
        return best
    }

    /// The window's content area in GUEST coords — the same inset the renderer
    /// uses for its content rect (the transform is 1:1), so a captured island
    /// lands pixel-aligned rather than needing its own calibration.

    /// Is the window at `index` covered by any window in front of it?
    ///
    /// Scene order is front-first, so "in front of" means a lower index. Any
    /// intersection at all counts: a partially covered window would capture a
    /// seam of the window on top, and half-wrong pixels presented as a window's
    /// contents are worse than an honest blank.
    static func isOccluded(_ windows: [Scene.Window], index: Int) -> Bool {
        let mine = contentRect(windows[index])
        guard mine.width > 0, mine.height > 0 else { return true }
        for j in 0..<index {
            let other = windows[j]
            guard other.visible, !HitTester.isDesktopBackdrop(other) else { continue }
            let r = other.rect
            let overlaps = r.l < mine.r && r.r > mine.l
                        && r.t < mine.b && r.b > mine.t
            if overlaps { return true }
        }
        return false
    }

    static func contentRect(_ win: Scene.Window) -> Rect {
        let isDialog = win.kind == 2
        return Rect(l: win.rect.l + (isDialog ? 6 : 1),
                    t: win.rect.t + (isDialog ? 6 : 22),
                    r: win.rect.r - (isDialog ? 6 : 1),
                    b: win.rect.b - (isDialog ? 6 : 1))
    }

    /// Mounted disks as `name|h,v;;` (Finder-placed on-screen positions).
    private static let disksScript = [
        "tell application \"Finder\"",
        "set r to \"\"",
        "repeat with dk in disks",
        "set p to position of dk",
        "set r to r & (name of dk) & \"|\" & (item 1 of p) & \",\" & (item 2 of p) & \";;\"",
        "end repeat",
        "return r",
        "end tell",
    ].joined(separator: "\n")

    /// Parse the disks script output into desktop items (kind "disk"). The
    /// Finder position is the icon's top-left, like `fdLocation`.
    private func diskItems(from output: String?) -> [Scene.DesktopItem]? {
        guard var raw = output else { return nil }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        var items: [Scene.DesktopItem] = []
        for record in raw.components(separatedBy: ";;") where !record.isEmpty {
            guard let bar = record.firstIndex(of: "|") else { continue }
            let name = String(record[..<bar])
            let coords = record[record.index(after: bar)...]
                .split(separator: ",")
            guard coords.count == 2, let h = Int(coords[0].trimmingCharacters(
                    in: .whitespaces)),
                  let v = Int(coords[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            items.append(.init(name: name, kind: "disk", type: nil,
                               creator: nil, x: h, y: v, placed: true,
                               alias: false, invisible: false))
        }
        return items.isEmpty ? nil : items
    }

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
    /// The layout signature the snapshot was taken at.
    private var itemsSignature = ""

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
        guard !folders.isEmpty else {
            windowItems = [:]
            finderPaths = [:]
            truncatedWindows = []
            itemsSignature = ""
            return
        }
        let signature = folders.map(FinderItems.layoutKey).joined(separator: "|")
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
        guard !reports.isEmpty else { return false }
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
