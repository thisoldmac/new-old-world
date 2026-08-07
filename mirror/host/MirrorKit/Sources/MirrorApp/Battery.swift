import Foundation
import MirrorKit
import MirrorOracleKit

/// The actuation battery: drive the guest through the full gesture set via the
/// REAL hit-test → action-model → dispatcher path (the same code the live app
/// runs), verifying each landed by re-polling the scene. Turns "we keep
/// finding actuation gaps by driving" into a repeatable green/red suite — the
/// maturity signal for reliable actuation.
///
/// Emu-only (uses the QMP plane). Mutates guest state (opens/closes/moves
/// windows) — run on a session clone. `MirrorApp --battery --host … --port …
/// --qmp …`.
struct ActBattery {
    let target: MirrorTarget
    let wire: WireClient
    var poller: ScenePoller
    let dispatcher: ActionDispatcher

    init(target: MirrorTarget, qmpSocket: String?) {
        self.target = target
        // One shared wire (single-connection worker).
        let wire = WireClient(target: target)
        self.wire = wire
        var poller = ScenePoller(target: target, wire: wire)
        poller.includeDesktopItems = true   // so the disk-icon test has a target
        poller.detectScreen()
        self.poller = poller
        self.dispatcher = ActionDispatcher(target: target, qmpSocket: qmpSocket,
                                           wire: wire)
    }

    struct Result { let name: String; let status: Status; let detail: String }
    enum Status: String { case pass = "PASS", fail = "FAIL", skip = "SKIP" }

    // MARK: - Scene helpers

    private mutating func scene() -> Scene? { try? poller.poll() }

    private static func realWindows(_ s: Scene, app: String? = nil) -> [Scene.Window] {
        s.windows.filter { !HitTester.isDesktopBackdrop($0)
            && (app == nil || $0.app == app) }
    }

    private static func front(_ s: Scene) -> Scene.Window? {
        s.windows.first { $0.front }
    }

    /// The front window's live scrollbar value — the scroll tests' witness.
    /// Static so `settle`'s check doesn't capture `self` (which is mutating).
    private static func barValue(_ s: Scene) -> Int? {
        front(s)?.controls.first(where: Scrollbar.isLive)?.value
    }

    /// Poll until `check` passes or the deadline; returns the last scene.
    private mutating func settle(_ tries: Int = 6,
                                 _ check: (Scene) -> Bool) -> Scene? {
        var last: Scene?
        for _ in 0..<tries {
            if let s = scene() { last = s; if check(s) { return s } }
            usleep(400_000)
        }
        return last
    }

    // MARK: - Run

    mutating func run() -> [Result] {
        var out: [Result] = []
        func record(_ name: String, _ status: Status, _ detail: String = "") {
            out.append(.init(name: name, status: status, detail: detail))
            let mark = status == .pass ? "✓" : status == .fail ? "✗" : "–"
            print("  \(mark) \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        // Setup: SimpleText as the front app (it launches with no document
        // window — File▸New below makes the first one). Wait for AXPeek to
        // sample its menu bar.
        _ = try? wire.request("launch",
            ["path": "Macintosh HD:Applications (Mac OS 9):SimpleText"])
        let s0opt = settle(12) { $0.menubar?.app == "SimpleText" }
        guard let s0 = s0opt, s0.menubar?.app == "SimpleText" else {
            record("setup: SimpleText front app", .fail, "SimpleText not front")
            return out
        }
        record("setup: SimpleText front app", .pass)

        // Clear a modal dialog a prior run may have left open (a Save / "save
        // changes?" prompt). While one is up, SimpleText is in ModalDialog and
        // every menu op below silently no-ops — so dismiss it first.
        for _ in 0..<3 {
            guard let s = scene(),
                  let dialog = s.windows.first(where: { $0.kind == 2 }),
                  let btn = dialog.controls.first(where: {
                      $0.title == "Cancel" || $0.title.hasPrefix("Don") })
            else { break }
            if let r = btn.rect {
                let p = (x: dialog.rect.l + (r.l + r.r) / 2,
                         y: dialog.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
                dispatch(ActionModel.click(on: HitTester.hitTest(s, x: p.x, y: p.y)))
                _ = settle { s in !s.windows.contains { $0.kind == 2 } }
            } else { break }
        }

        // 1. Menu ⌘ item — File ▸ New adds a document window.
        do {
            let before = Self.realWindows(s0, app: "SimpleText").count
            if let menu = s0.menubar?.menus.first(where: { $0.title == "File" }),
               let item = menu.items.first(where: { $0.title.hasPrefix("New") }) {
                dispatch(ActionModel.menuSelect(menu: menu, item: item))
                let s = settle { Self.realWindows($0, app: "SimpleText").count > before }
                let after = s.map { Self.realWindows($0, app: "SimpleText").count } ?? before
                record("menu ⌘ (File▸New)", after > before ? .pass : .fail,
                       "windows \(before)→\(after)")
            } else { record("menu ⌘ (File▸New)", .skip, "no File▸New") }
        }

        // 2. Scroll — the guest's own scrollbar value is the witness. First
        // make something TO scroll: a window whose content fits reports
        // min == max and has nothing to do (honest, not a gap), so type a few
        // lines and shrink the window until the doc overflows.
        if let w = scene().flatMap(Self.front) {
            // Keep the text SHORT: `type` posts one event per character, so a
            // few hundred chars is seconds of guest time (and a long enough
            // stall to trip the poll timeout). 12 lines is ~190 px of content.
            dispatch([.type(text: (1...12).map { "Line \($0)" }
                                          .joined(separator: "\r") + "\r")])
            _ = settle(3) { _ in false }
            // Shrink well below the text height so it must overflow. SimpleText
            // remembers a zoomed size, so a New window can be near-fullscreen.
            let r = scene().flatMap(Self.front)?.rect ?? w.rect
            dispatch(ActionModel.growDrag(from: (r.r - 7, r.b - 7),
                                          to: (r.r - 7, r.t + 130)))
            _ = settle(4) { _ in false }
        }
        if let s = scene(), let w = Self.front(s),
           let bar = w.controls.first(where: Scrollbar.isLive),
           let v0 = bar.value {
            let origin = (x: w.rect.l, y: w.rect.t + HitTester.titlebar)
            let range = "\(bar.min ?? 0)…\(bar.max ?? 0)"
            // Park at the top so a line-DOWN has room whatever the prior state.
            if let up = Scrollbar.center(bar, .lineUp) {
                dispatch([.deviceClick(x: up.x + origin.x, y: up.y + origin.y)])
            }
            let parked = settle(4) { _ in false }.flatMap(Self.barValue) ?? v0
            if let down = Scrollbar.center(bar, .lineDown) {
                dispatch([.deviceClick(x: down.x + origin.x, y: down.y + origin.y)])
                let now = settle { (Self.barValue($0) ?? parked) > parked }
                    .flatMap(Self.barValue) ?? parked
                record("scroll line (arrow)", now > parked ? .pass : .fail,
                       "value \(parked)→\(now) of \(range)")
            } else { record("scroll line (arrow)", .skip, "no arrow") }
            // Thumb drag: the drop position IS the value (unity compensation —
            // 1.6× would slam it to the end, the menu-drag lesson).
            if let bar2 = scene().flatMap(Self.front)?.controls
                .first(where: Scrollbar.isLive),
               let mx = bar2.max, let mn = bar2.min, let at = bar2.value,
               let from = Scrollbar.center(bar2, .thumb) {
                // Drag to the far end from wherever it sits — the line test
                // above may already have pinned it (a short document's whole
                // range can be less than one line), and a zero-length drag
                // would prove nothing.
                let want = at >= mx ? mn : mx
                if let to = Scrollbar.thumbTarget(bar2, value: want) {
                    dispatch(ActionModel.thumbTracking(
                        from: (from.x + origin.x, from.y + origin.y),
                        to: (to.x + origin.x, to.y + origin.y)))
                    let landed = settle { abs((Self.barValue($0) ?? 9999) - want) <= 1 }
                        .flatMap(Self.barValue) ?? -1
                    record("scroll thumb drag", abs(landed - want) <= 1 ? .pass : .fail,
                           "value \(at)→\(landed), wanted \(want)")
                } else { record("scroll thumb drag", .skip, "no thumb target") }
            } else { record("scroll thumb drag", .skip, "no live thumb") }
        } else {
            record("scroll line (arrow)", .skip, "nothing to scroll")
            record("scroll thumb drag", .skip, "nothing to scroll")
        }

        // 3. Grow box → resize. Done BEFORE the move, while the window is at
        // its default on-screen spot (a move can push the grow box off the
        // bottom edge, where QMP can't position). Shrink (always has room).
        // A SKIP, on every window, until `FindWindow`'s `inGrow` lands:
        // `WindowChrome.growBox` answers nil because nothing in IR v1 says
        // which windows have one, and the battery may only act on a box the
        // chrome will vouch for. Grading a drag at a corner we cannot
        // establish would score the fabricated affordance as a pass.
        if let w = scene().flatMap(Self.front) {
            if let box = WindowChrome.growBox(w) {
                let r = w.rect
                let g = WindowChrome.center(box)
                dispatch(ActionModel.growDrag(from: g,
                                              to: (g.x - 53, g.y - 53)))
                let s = settle { s in
                    let n = Self.front(s)?.rect ?? r
                    return abs(n.r - r.r) > 15 || abs(n.b - r.b) > 15
                }
                let n = s.flatMap(Self.front)?.rect ?? r
                let changed = abs(n.r - r.r) > 15 || abs(n.b - r.b) > 15
                record("grow box (resize)", changed ? .pass : .fail,
                       "Δr=\(n.r - r.r) Δb=\(n.b - r.b)")
            } else {
                record("grow box (resize)", .skip,
                       "no grow box this side can establish (KW-01)")
            }
        } else { record("grow box (resize)", .skip, "no front window") }

        // 4. Title-bar drag → window move.
        if let w = scene().flatMap(Self.front) {
            let r = w.rect
            let grab = (x: (r.l + r.r) / 2, y: r.t + 5)
            dispatch(ActionModel.titlebarDrag(from: grab,
                                              to: (grab.x + 60, grab.y + 45)))
            let s = settle { (Self.front($0)?.rect.l ?? r.l) > r.l + 20 }
            let moved = s.flatMap(Self.front).map { $0.rect.l - r.l } ?? 0
            record("title-bar drag (move)", moved > 20 ? .pass : .fail,
                   "Δl=\(moved) (wanted ~60)")
        } else { record("title-bar drag (move)", .skip, "no front window") }

        // 5. Zoom widget → geometry change.
        if let s = scene(), let w = Self.front(s),
           let box = WindowChrome.widgetBox(w, .zoom) {
            let r0 = w.rect
            let c = WindowChrome.center(box)
            dispatch(ActionModel.click(on: HitTester.hitTest(s, x: c.x, y: c.y)))
            let after = settle { (Self.front($0)?.rect ?? r0) != r0 }
            let changed = after.flatMap(Self.front).map { $0.rect != r0 } ?? false
            record("zoom widget", changed ? .pass : .fail,
                   changed ? "rect changed" : "no change")
        } else { record("zoom widget", .skip, "no zoom box") }

        // 6. Close widget removes the front window. The scroll test typed into
        // this document, so SimpleText asks to save first — which is the
        // realistic case, and the window COUNT briefly goes UP (the prompt is a
        // window). Answer "Don't Save", then assert the document is gone.
        if let s = scene(), let w = Self.front(s) {
            let before = Self.realWindows(s).count
            if let box = WindowChrome.widgetBox(w, .close) {
                let c = WindowChrome.center(box)
                dispatch(ActionModel.click(on: HitTester.hitTest(s, x: c.x, y: c.y)))
                if let s2 = settle(4, { s in s.windows.contains { $0.kind == 2 } }),
                   let prompt = s2.windows.first(where: { $0.kind == 2 }),
                   let dont = prompt.controls.first(where: { $0.title.hasPrefix("Don") }),
                   let r = dont.rect {
                    let p = (x: prompt.rect.l + (r.l + r.r) / 2,
                             y: prompt.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
                    dispatch(ActionModel.click(on: HitTester.hitTest(s2, x: p.x, y: p.y)))
                }
                let after = settle { Self.realWindows($0).count < before }
                let now = after.map { Self.realWindows($0).count } ?? before
                record("close widget", now < before ? .pass : .fail,
                       "windows \(before)→\(now)")
            } else { record("close widget", .skip, "no close box") }
        } else { record("close widget", .skip, "no front window") }

        // 7. Double-click a desktop document → its window becomes front
        // (opens it, or re-fronts it if already open). Checking "front window
        // is the doc" is robust to a doc left open by a prior run, unlike a
        // raw window count.
        if let s = scene() {
            let doc = s.desktopItems?.first {
                $0.placed && !$0.alias && $0.kind == "file" && $0.type == "TEXT"
            }
            if let doc {
                let c = (x: doc.x + 16, y: doc.y + 16)
                // Only meaningful if the icon is actually exposed: a window
                // left over the desktop makes the hit-test resolve to THAT
                // window, and double-clicking it proves nothing. Occlusion is
                // a skip, not a regression.
                let hit = HitTester.hitTest(s, x: c.x, y: c.y)
                if case .desktop = hit {
                    dispatch(ActionModel.click(on: hit, count: 2))
                    let after = settle(10) {
                        Self.front($0).map { $0.title == doc.name } ?? false
                    }
                    let ok = after.flatMap(Self.front)
                        .map { $0.title == doc.name } ?? false
                    record("double-click (open \(doc.name))", ok ? .pass : .fail,
                           ok ? "\(doc.name) front" : "not front")
                } else {
                    record("double-click (open \(doc.name))", .skip,
                           "icon occluded — a window covers it")
                }
            } else { record("double-click (open doc)", .skip, "no desktop doc") }
        }

        // 8. Menu-drag (shortcut-less) — File ▸ Save As opens a dialog. Run
        // LAST and its Cancel right after: the open-loop QMP menu-drag is the
        // weakest emu-only primitive, and a miss doesn't no-op — it selects
        // whatever row the cursor lands on (possibly Close/Quit). Isolating it
        // here keeps a misfire from corrupting the reliable checks above.
        if let s = scene(), Self.front(s)?.app == "SimpleText",
           let menu = s.menubar?.menus.first(where: { $0.title == "File" }),
           let item = menu.items.first(where: { $0.title.hasPrefix("Save As") }) {
            dispatch(ActionModel.menuSelect(menu: menu, item: item))
            let after = settle { s in s.windows.contains { $0.kind == 2 } }
            let hasDialog = after?.windows.contains { $0.kind == 2 } ?? false
            record("menu-drag (File▸Save As)", hasDialog ? .pass : .fail,
                   hasDialog ? "dialog opened" : "no dialog (emu-only, flaky)")
            // Dismiss the Save dialog by its Cancel button (also exercises axdo
            // on a dialog control). Skips cleanly when the drag didn't open one.
            if hasDialog, let s2 = scene(),
               let dialog = s2.windows.first(where: { $0.kind == 2 }),
               let cancel = dialog.controls.first(where: { $0.title == "Cancel" }) {
                let r = cancel.rect!
                let p = (x: dialog.rect.l + (r.l + r.r) / 2,
                         y: dialog.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
                dispatch(ActionModel.click(on: HitTester.hitTest(s2, x: p.x, y: p.y)))
                let gone = settle { s in !s.windows.contains { $0.kind == 2 } }
                    .map { !$0.windows.contains { $0.kind == 2 } } ?? false
                record("axdo (dialog Cancel)", gone ? .pass : .fail,
                       gone ? "dialog closed" : "still open")
            } else { record("axdo (dialog Cancel)", .skip, "no dialog to cancel") }
        } else { record("menu-drag (File▸Save As)", .skip, "no Save As") }

        // Teardown: leave NO modal behind. This is not tidiness — a modal the
        // battery leaves up starves the guest's event loop, and the next run
        // finds every port dead (observed 2026-07-17: a Save As whose Cancel
        // missed left a nested "Replace existing?" prompt and wedged the VM
        // until a reboot). Escape doesn't dismiss a classic modal, and with the
        // worker starved there's no `mouseloc` to close-loop a QMP click onto
        // the button — so the battery must not create the situation.
        for _ in 0..<4 {
            guard let s = scene(),
                  let dialog = s.windows.first(where: { $0.kind == 2 })
            else { break }
            guard let btn = dialog.controls.first(where: {
                      $0.title == "Cancel" || $0.title.hasPrefix("Don") }),
                  let r = btn.rect else { break }
            let p = (x: dialog.rect.l + (r.l + r.r) / 2,
                     y: dialog.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
            dispatch(ActionModel.click(on: HitTester.hitTest(s, x: p.x, y: p.y)))
            _ = settle(3) { s in !s.windows.contains { $0.kind == 2 } }
        }
        if let s = scene(), s.windows.contains(where: { $0.kind == 2 }) {
            record("teardown: no modal left", .fail,
                   "a dialog is still up — the next run will find a wedged guest")
        }

        return out
    }

    private func dispatch(_ actions: [MirrorAction]) {
        for a in actions {
            guard dispatcher.availability(a) == .available
            else { continue }
            _ = try? dispatcher.perform(a)
        }
    }
}
