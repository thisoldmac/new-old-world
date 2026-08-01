import Foundation

/// Executes `MirrorAction`s against a target: wire verbs through the
/// WireClient, the drag plane through QMP (closed-loop positioned on the
/// `mouseloc` verb — port of `sources.py::_position`/`_drag`).
///
/// Fail-closed: availability is checked before anything is sent, so an
/// emu-only action against a QMP-less target is a typed refusal, never a
/// silent no-op.
public final class ActionDispatcher {
    public let target: MirrorTarget
    private let wire: WireClient

    public enum DispatchError: Error, CustomStringConvertible {
        case notAvailable(ActionAvailability)
        case positioningFailed(wanted: (x: Int, y: Int), got: (x: Int, y: Int))

        public var description: String {
            switch self {
            case .notAvailable(let a): return "action not available: \(a)"
            case .positioningFailed(let wanted, let got):
                return "closed-loop positioning failed: wanted \(wanted), "
                    + "cursor at \(got)"
            }
        }
    }

    public init(target: MirrorTarget, timeout: Double = 10.0) {
        self.target = target
        self.wire = WireClient(target: target, timeout: timeout)
    }

    /// Share the poller's wire — the toolkit worker serves ONE connection,
    /// so the dispatcher must reuse it, not open a second (which the worker
    /// resets, breaking mouseloc mid-drag).
    public init(target: MirrorTarget, wire: WireClient) {
        self.target = target
        self.wire = wire
    }

    /// Dispatch a gesture's action sequence in order. Returns the guest
    /// replies (one per action) for logging/inspection.
    @discardableResult
    public func perform(_ actions: [MirrorAction]) throws -> [[String: Any]] {
        try actions.map { try perform($0) }
    }

    @discardableResult
    public func perform(_ action: MirrorAction) throws -> [String: Any] {
        let availability = ActionModel.availability(action, target: target)
        guard availability == .available else {
            throw DispatchError.notAvailable(availability)
        }
        switch action {
        case .axdo(let ref, let count, let mods, let text):
            var args: [String: Any] = ["ref": ref]
            if count != 1 { args["count"] = count }
            if mods != 0 { args["mods"] = mods }
            if let text { args["text"] = text }
            return try wire.request("axdo", args).result
        case .key(let code, let char, let mods):
            return try wire.request(
                "key", ["code": code, "char": char, "mods": mods]).result
        case .type(let text):
            return try wire.request("type", ["text": text]).result
        case .activate(let psn):
            let parts = psn.split(separator: ".")
            let hi = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
            let lo = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            return try wire.request(
                "activate", ["serialHi": hi, "serialLo": lo]).result
        case .click(let x, let y, let count, let mods):
            var args: [String: Any] = ["x": x, "y": y]
            if count != 1 { args["count"] = count }
            if mods != 0 { args["mods"] = mods }
            return try wire.request("click", args).result
        case .drag(let x0, let y0, let x1, let y1):
            return try drag(x0: x0, y0: y0, x1: x1, y1: y1)
        case .qmpClick(let x, let y):
            let qmp = try QmpClient(socketPath: target.qmp!)
            try position(qmp: qmp, x: x, y: y)
            try qmp.button(down: true)
            usleep(120_000)   // hold long enough for TrackGoAway/SelectWindow
            try qmp.button(down: false)
            return ["qmpClicked": [x, y]]
        case .qmpDoubleClick(let x, let y):
            // Position once, then two rapid clicks — a genuine double-click
            // (well within the ~500ms guest double-click time).
            let qmp = try QmpClient(socketPath: target.qmp!)
            try position(qmp: qmp, x: x, y: y)
            for _ in 0..<2 {
                try qmp.button(down: true)
                usleep(45_000)
                try qmp.button(down: false)
                usleep(45_000)
            }
            return ["qmpDoubleClicked": [x, y]]
        case .thumbDrag(let x0, let y0, let x1, let y1):
            // Unity, not 1.6x: TrackControl tracks the thumb to wherever the
            // cursor lands, so the drop position IS the scroll value (the same
            // reason the menu drag needs it — 1.6x overshoots to the end).
            return try drag(x0: x0, y0: y0, x1: x1, y1: y1, compensation: 1.0)
        case .menuInvoke(let menuID, let itemIndex, let titleLeft):
            // The guest arms its patch, posts the mouseDown that makes the app
            // call MenuSelect, and answers it. `answered` means the app's
            // MenuSelect returned our item — NOT that its handler did what the
            // caller wanted, which stays the caller's to verify.
            //
            // `menuact` with `menu`, NOT upstream's `menuinvoke` with
            // `menuID`. Reconciled 2026-07-31: this call had crossed from
            // timbottu/mirror unchanged and named a verb no NOW guest
            // answers, with an argument no NOW verb takes — a request that
            // would have come back `unknown-command` from every machine
            // that exists. The probes under scripts/probes/ were reconciled
            // to the contract's spelling the same day and this was not; see
            // scripts/probes/README.md, "a spelling is not a capability".
            //
            // The three arguments are the contract's and their meanings are
            // unchanged, which is why only the names moved: `menu` is the
            // menu's id as the scene reports it, `item` its 1-based
            // position, `titleLeft` the x of the menu's title in the menu
            // bar — required and not derived, because it is this act's
            // identity check. A press anywhere else belongs to the person
            // at the machine and is passed through untouched.
            return try wire.request("menuact",
                                    ["menu": menuID, "item": itemIndex,
                                     "titleLeft": titleLeft]).result
        case .menuDrag(let menuLeft, let itemIndex):
            // Press on the title, drag down the guest-drawn menu, release
            // on the item row. Positioning before the press is closed-loop;
            // once MenuSelect tracks, mouseloc is starved, so the drop is
            // open-loop like any drag.
            let item = ActionModel.menuItemPoint(menuLeft: menuLeft,
                                                 itemIndex: itemIndex)
            // MenuSelect tracks the cursor ~1:1 (unlike DragWindow, whose
            // grab-point tracking wants the 1.6× accel compensation). At 1.6×
            // the drop overshoots by rows and selects the wrong item; measured
            // against the guest, unity lands the cursor dead-center on the row.
            return try drag(x0: menuLeft + 10, y0: 8, x1: item.x, y1: item.y,
                            compensation: 1.0)
        }
    }

    // MARK: - The QMP drag plane (emu-only)

    private func mouseloc() throws -> (x: Int, y: Int) {
        let r = try wire.request("mouseloc").result
        return (SceneBuilder.intValue(r["x"]) ?? 0,
                SceneBuilder.intValue(r["y"]) ?? 0)
    }

    /// Closed-loop the emulated cursor onto (tx,ty) using mouseloc feedback
    /// — the rel mouse is accel-distorted, so read and correct. Steps down to
    /// 1px near the target so small widgets/icons hit dead-center (±2px).
    private func position(qmp: QmpClient, x tx: Int, y ty: Int,
                          tolerance: Int = 2, iterations: Int = 40) throws {
        var last = (x: 0, y: 0)
        for _ in 0..<iterations {
            last = try mouseloc()
            let dx = tx - last.x
            let dy = ty - last.y
            if abs(dx) <= tolerance && abs(dy) <= tolerance { return }
            // Coarse steps far out (accel-linear region), fine steps close in.
            let step = max(abs(dx), abs(dy)) > 6 ? 3 : 1
            try qmp.rel(dx: dx, dy: dy, step: step)
        }
        throw DispatchError.positioningFailed(wanted: (tx, ty), got: last)
    }

    /// Press-move-release. Positioning is closed-loop and precise; the drag
    /// motion is open-loop. `compensation` scales the rel delta: window/grow
    /// drags want ~1.6× (DragWindow tracks the grab point through accel
    /// undershoot and only the endpoint matters); a menu drag wants 1.0 (the
    /// drop position picks the item, and MenuSelect tracks the cursor ~1:1).
    /// The QMP connection is per-drag (QEMU serves one QMP client at a
    /// time; holding it would lock out tools/qmp and tools/stop).
    private func drag(x0: Int, y0: Int, x1: Int, y1: Int,
                      compensation: Double = 1.6) throws -> [String: Any] {
        let qmp = try QmpClient(socketPath: target.qmp!)
        try position(qmp: qmp, x: x0, y: y0)
        try qmp.button(down: true)
        usleep(150_000)
        try qmp.rel(dx: Int(Double(x1 - x0) * compensation),
                    dy: Int(Double(y1 - y0) * compensation))
        usleep(150_000)
        try qmp.button(down: false)
        return ["dragged": [x0, y0, x1, y1]]
    }
}
