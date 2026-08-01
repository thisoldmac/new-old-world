import Foundation

/// When a window's interior is re-photographed, when it is held, and when it
/// is shifted rather than re-read — the island *policy*, with no wire under
/// it.
///
/// **What changed on the way into NOW.** This logic lived in `ScenePoller`
/// and called `WireClient.captureRegion` directly, which is upstream's
/// transport and the thing NOW must not grow a second of. The policy is not
/// the transport: every rule below was measured against a running Mac OS 9.1
/// (a full-window capture costs ~1 s; a covered window's capture returns the
/// pixels of whatever is on top of it; a scroll arrives as one large blit),
/// and those are facts about classic Mac OS rather than about a socket.
///
/// So the fetch is now a **closure the caller supplies**, and since
/// 2026-08-01 `MirrorModuleModel` supplies one — `requestCaptureRegion` +
/// `CaptureDelivery.makePixelIsland`. This header used to say nothing did,
/// and that the missing connection was a hole rather than a decision; the
/// hole is closed.
///
/// **Why the seam is `async` and not a blocking call.** The closure that
/// fills it is a network round trip whose reply can only be consumed on the
/// main actor: NOW's socket runs on `.main`, and every byte it receives is
/// handed over inside `Task { @MainActor in … }` (`Session.receiveLoop`),
/// as is the watchdog that gives up on it (`GuestListener.armWatchdog`, a
/// `DispatchQueue.main.asyncAfter`). The caller of this policy is
/// `@MainActor` too. So a synchronous bridge — a semaphore waited on while
/// the completion is outstanding — would block the one queue that can
/// deliver the answer OR time it out: not a deadlock risk, a certain
/// deadlock with no watchdog left alive to break it. Suspending is the only
/// shape that works, and it is the shape the model's other completion-based
/// joins already take.
public struct SceneIslands {

    public init() {}

    /// Fetch the real pixels of one GUEST-coordinate rect, or throw. The one
    /// seam through which this policy touches a machine.
    ///
    /// Deliberately NOT actor-isolated: this policy is pure and belongs to no
    /// actor, so the isolation lives on the closure the Host hands in. A
    /// synchronous fetch (every test that must prove no capture rode a pass)
    /// still satisfies it — Swift converts one implicitly.
    public typealias Capture = (Rect) async throws -> PixelIsland

    /// Internal on purpose: the store, its keying rule and its eviction
    /// clock are MirrorKit's own business, and a Host that could reach in
    /// would be a second place deciding when pixels are dropped.
    var islands = IslandStore()

    /// The draw ops accounted against, newest-first-agnostic. The MoveBits
    /// fast path reads these; a caller with no draw-op source leaves them
    /// empty and every changed window is a full re-read.
    public var displayOps: [DisplayOp] = []

    /// Bytes pulled through `Capture` since the last reset — the meter the
    /// lifecycle tests read to prove a poll rode no capture at all.
    public private(set) var bytesFetched = 0

    public var gracePolls: Int {
        get { islands.gracePolls }
        set { islands.gracePolls = newValue }
    }

    /// Attach pixels to every window that has them, but re-capture only the
    /// FRONT one. A full-window capture is ~1 s on the wire, so capturing
    /// every window every poll is not an option — and it isn't needed: an
    /// interior only changes while its app is drawing, which (cooperatively)
    /// means while it is frontmost. So the lifecycle is: capture on
    /// launch/raise and while focused, then *hold* the last image. A window
    /// we have seen never goes back to blank.
    ///
    /// `poll` is the counter the eviction clock runs on — passed in rather
    /// than read from a sequence number so the lifecycle is drivable in a
    /// test.
    public mutating func attach(_ scene: inout Scene, poll: Int,
                                capture: Capture) async {
        let keys = IslandStore.keys(for: scene.windows)
        islands.touch(keys, seq: poll)
        for i in scene.windows.indices {
            // A window we have the SEMANTICS for does not need a photograph
            // of itself, and a capture costs ~1 s. This is the Finder folder
            // window, which is exactly the window islands were invented for —
            // the invention outlived its reason.
            if scene.windows[i].items != nil { continue }
            let held = islands.pixels[keys[i]]
            // A capture reads a SCREEN region, so a covered window would
            // return whatever is on top of it — someone else's pixels,
            // confidently mislabelled. This guard covers the FRONT window
            // too, which it did not until 2026-08-01: `front` is a flag the
            // guest sets, not a promise that nothing is layered over it
            // (a floating palette, a screen-dimmer, a window the Window
            // Manager put above the active one), and the one case where a
            // wrong island is worse than no island is the window a person is
            // looking at.
            let occluded = SceneGeometry.isOccluded(scene.windows, index: i)
            // FIRST SIGHT (`held == nil`). Retention can only hold what it
            // has captured, so a window that was already open when we
            // attached has no last state and would render as empty chrome
            // until the human happens to click it. The spec is "updated when
            // launched, on raise, and while focused" — an app launched under
            // us IS front and gets captured, but a window that predates us
            // never was. Capture it once, here, so it has something to hold.
            // Occluded windows stay empty until they are raised, which is
            // correct-by-construction: being raised is exactly what makes a
            // capture truthful.
            if !occluded, scene.windows[i].front || held == nil {
                scene.windows[i].island = await island(for: scene.windows[i],
                                                       key: keys[i],
                                                       capture: capture)
            } else if let held {
                // Stale-geometry decision: a window can be moved or resized
                // while unfocused, so a held island may not match the current
                // content rect. We attach it anyway, unscaled and anchored at
                // the content origin (the renderer clips it) — never dropped,
                // never stretched. A resize doesn't change the *content*
                // pixels, only how much of them is visible, so clipping is
                // truthful for the shrink case and merely incomplete for the
                // grow case; scaling would invent pixels the guest never drew
                // (and Platinum's 1-bit art resamples into mush); dropping
                // would regress the window to blank. The mismatch is
                // transient — the next raise re-captures at the new size,
                // since the content rect is part of the capture key.
                scene.windows[i].island = held
            }
        }
        islands.evict(living: Set(keys), seq: poll)
    }

    /// Put back only the pixels already held — no fetch, no machine, no
    /// decision. The eviction clock still ticks, because a pass that took no
    /// capture is still a pass in which these windows were present.
    ///
    /// **Why this exists beside `attach`.** A scene decoded off the wire has
    /// `island == nil` on every window, and the capture pass that would fill
    /// them in suspends for as long as the round trip takes (~1 s). Without
    /// this, every window on the page — including the ones whose pixels are
    /// sitting in `islands.pixels` and cost nothing — would render blank for
    /// that second, on every fetch. It is `MirrorContentHold`'s rule for the
    /// display plane, applied to the pixel plane: what a fetch cannot re-join
    /// in time, it must not wipe.
    ///
    /// Not expressible as `attach` with a throwing capture: that path
    /// CONSUMES a pending MoveBits (it shifts held pixels and advances the
    /// tick cursor) whether or not the exposed band could be fetched, so a
    /// hold-only call written that way would silently spend the scroll fast
    /// path it was only supposed to look at.
    public mutating func reattachHeld(_ scene: inout Scene, poll: Int) {
        let keys = IslandStore.keys(for: scene.windows)
        islands.touch(keys, seq: poll)
        for i in scene.windows.indices where scene.windows[i].items == nil {
            guard let held = islands.pixels[keys[i]] else { continue }
            scene.windows[i].island = held
        }
    }

    private mutating func island(for win: Scene.Window,
                                 key cacheKey: String,
                                 capture: Capture) async -> PixelIsland? {
        let content = SceneGeometry.contentRect(win)
        let cw = content.r - content.l, ch = content.b - content.t
        guard cw > 1, ch > 1 else { return nil }
        let area = cw * ch
        let seen = islands.tick[cacheKey] ?? 0

        // MoveBits fast-path: a scroll is a screen→screen blit — same size,
        // src inside the content we already hold. Move our own pixels and ask
        // only for the band the move exposed, instead of re-reading the whole
        // window.
        if let cached = islands.pixels[cacheKey],
           let mv = SceneGeometry.newestMove(displayOps, content: content,
                                             since: seen) {
            let (moved, exposed) = cached.shifted(dx: mv.dx, dy: mv.dy)
            var island = moved
            if let band = exposed, band.b > band.t {
                // Band in GUEST coords, then patch back at island-local y.
                let rect = Rect(l: content.l + band.l, t: content.t + band.t,
                                r: content.l + band.r, b: content.t + band.b)
                if let fetched = await fetch(rect, capture) {
                    island = moved.patched(with: fetched,
                                           atX: band.l, y: band.t)
                }
            }
            islands.pixels[cacheKey] = island
            islands.tick[cacheKey] = mv.tick
            islands.contentKey[cacheKey] =
                "\(content.l),\(content.t),\(content.r),\(content.b)@\(mv.tick)"
            return island
        }

        // Otherwise: a content-sized blit is the guest repainting this window.
        let lastBlitTick = displayOps.compactMap { op -> Int? in
            guard op.op == "bits", let d = op.dst, d.count == 4,
                  (d[2] - d[0]) * (d[3] - d[1]) > area / 2 else { return nil }
            return op.ticks
        }.max() ?? 0
        let key = "\(content.l),\(content.t),\(content.r),\(content.b)"
            + "@\(lastBlitTick)"
        if islands.contentKey[cacheKey] == key,
           let cached = islands.pixels[cacheKey] {
            return cached                                   // unchanged — reuse
        }
        guard let fetched = await fetch(content, capture) else {
            return islands.pixels[cacheKey]             // keep the last good
        }
        islands.pixels[cacheKey] = fetched
        islands.contentKey[cacheKey] = key
        islands.tick[cacheKey] = lastBlitTick
        return fetched
    }

    /// One metered fetch. A throwing capture is not an error here — it is the
    /// ordinary case of a machine that is busy, and the caller above keeps
    /// whatever it already held rather than blanking a window.
    private mutating func fetch(_ rect: Rect,
                                _ capture: Capture) async -> PixelIsland? {
        guard let island = try? await capture(rect) else { return nil }
        bytesFetched += island.rgba.count
        return island
    }
}
