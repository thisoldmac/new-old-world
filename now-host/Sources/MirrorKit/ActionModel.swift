import Foundation

/// The semantic action vocabulary: what a gesture on a rendered scene MEANS,
/// element-first.
///
/// **This is intent, not dispatch.** There used to be an `ActionDispatcher`
/// under it that turned each case into a `WireClient` request or a QMP mouse
/// event. Both are gone: the first spoke the TimBotTu toolkit worker's
/// protocol, which no NOW guest answers, and the second injected mouse events
/// into an emulator from outside the guest CPU, which is host-side cheating by
/// this project's rule. Nothing in this module now reaches a machine, and
/// `NoSecondWireTests` is what keeps it that way.
///
/// The vocabulary itself survived the deletion, and deliberately. It is the
/// output of the hit tester — the measured half of the port — and every case
/// records a real thing a person can do to a Macintosh. What each case can be
/// *carried by* is answered separately, by `ActionModel.availability`, against
/// NOW's contract rather than against a target's flags. An act NOW cannot
/// carry is therefore a typed refusal with a reason, which is what "degrades
/// honestly" has always meant here — not an act quietly missing from the
/// vocabulary, which would leave a person clicking a title bar and getting
/// silence.
public enum MirrorAction: Equatable {
    /// Semantic, fail-closed click on a resolved control.
    case axdo(ref: String, count: Int = 1, mods: Int = 0, text: String? = nil)
    /// Keystroke. Menu shortcuts MUST carry the virtual keycode — Finder's
    /// MenuEvent matches the code, not the char (CONTROL-SURFACE.md).
    case key(code: Int, char: Int, mods: Int)
    /// Type ASCII text into the current focus.
    case type(text: String)
    /// Bring a process forward (PSN as the scene's "hi.lo" string).
    case activate(psn: String)
    /// Positional click at a guest point (front app receives it).
    case click(x: Int, y: Int, count: Int = 1, mods: Int = 0)
    /// Press-move-release, positioned closed-loop over QMP. Drives
    /// DragWindow/GrowWindow tracking loops the wire can't. EMU-ONLY.
    case drag(x0: Int, y0: Int, x1: Int, y1: Int)
    /// A real hardware press-release at a point via QMP — for the title-bar
    /// widget tracking loops (TrackGoAway/TrackBox). EMU-ONLY.
    case qmpClick(x: Int, y: Int)
    /// A real hardware double-click at a point via QMP — two rapid
    /// press-releases without repositioning between, so the guest sees a
    /// genuine double-click (opens icons). EMU-ONLY.
    case qmpDoubleClick(x: Int, y: Int)
    /// Select a shortcut-less menu item: press on the menubar title, drag
    /// down the guest-drawn menu to the item row, release. EMU-ONLY.
    case menuDrag(menuLeft: Int, itemIndex: Int)

    /// Perform a menu command through the Portal: the guest's in-process agent
    /// answers the application's own MenuSelect with this item, so the app runs
    /// its real command handler. No menu is drawn, no tracking loop runs, and
    /// no QMP is involved — which is what makes it metal-shaped where the drag
    /// below is emulator-only. This is the path for a shortcut-less item; a ⌘
    /// item should still go as a keystroke, which needs no patch at all.
    case menuInvoke(menuID: Int, itemIndex: Int, titleLeft: Int)
    /// **Select ONE Finder item, by name, inside a named container.**
    ///
    /// The identity-addressed replacement for upstream's positional click on
    /// an icon, and it is a ruling rather than a preference: NOW deliberately
    /// ships `mouseloc` with no companion mover and no positional click, and
    /// the thing that asked for one — folder items — "wants an identity rather
    /// than a coordinate" (`contract/asyncapi.yaml`, `mouseloc`; the argument
    /// in full is `docs/input-plane-decisions.md` §2). The route named there
    /// is the Finder's own `select item "X" of window "Y"`, through `script`.
    ///
    /// The hit tester still resolves the icon from a POINT — that is what a
    /// person gives it — but what leaves this vocabulary is a name and a
    /// container, and nothing downstream can fall back to the coordinate
    /// because it is not carried.
    case finderSelect(item: String, container: FinderContainer)
    /// Open ONE Finder item by name — the double-click. Upstream sent a real
    /// QMP double-click; there is no emulator on the other end of a NOW
    /// connection by assumption, so this is the Finder's own `open item …` on
    /// the same identity route as `finderSelect`.
    case finderOpen(item: String, container: FinderContainer)

    /// **Move, resize, zoom or close ONE window.** The window is named by the
    /// identity the SCENE has — process, title, occurrence — and the host
    /// resolves that to the opaque `now-window-…` reference `winact` takes by
    /// taking an observation at act time. See `WindowTarget` for why an
    /// identity and not a reference travels in the vocabulary.
    case windowAct(window: WindowTarget, op: WindowOp)

    /// A scrollbar thumb drag. Distinct from `drag` because the DROP POSITION
    /// is the value: TrackControl live-tracks the thumb, so this needs the
    /// precise (unity-compensated) motion a menu drag needs — the 1.6x a
    /// window drag wants would overshoot and slam the thumb to the end.
    case thumbDrag(x0: Int, y0: Int, x1: Int, y1: Int)
}

/// Where a Finder item lives, as the Finder's own scripting terminology names
/// it. There are exactly two containers a rendered scene can produce, because
/// there are exactly two places it draws icons.
public enum FinderContainer: Equatable, Sendable {
    /// The desktop. `item "X" of desktop` in the Finder's terminology.
    case desktop
    /// An open folder window, named by its title — which for a Finder window
    /// IS the folder's name, and is what `window "Y"` matches.
    case window(title: String)
}

/// One window, named the way a SCENE can name it.
///
/// **Why an identity and not a reference.** `winact` takes an opaque
/// `now-window-…` that only an observation mints, and a scene carries no such
/// thing — NOW's scene producer and the `elements` walk are two different
/// readers of the same machine. The vocabulary therefore carries what the
/// scene HAS, and the host resolves it against a live `elements` observation
/// before the act is sent (`MirrorWindowResolver`). That resolution is a
/// place to be wrong, so it refuses rather than guesses: an identity that
/// matches no window, or several, sends nothing.
///
/// `occurrence` is 0-based and counted the way the GUEST counts it — over
/// windows of the same process wearing the same title, in window-chain order,
/// front first (`now-guest-ppc/src/observe/obsmint.c`, `locate_window`). A
/// host that counted differently would resolve to a neighbouring window,
/// which is the failure this field exists to prevent.
public struct WindowTarget: Equatable, Sendable {
    /// The scene's own window id, carried for reporting rather than for
    /// addressing — nothing on the wire has ever heard of it.
    public var id: String
    /// The owning process, as the scene spells it: "hi.lo".
    public var psn: String
    public var title: String
    public var occurrence: Int

    public init(id: String, psn: String, title: String, occurrence: Int) {
        self.id = id
        self.psn = psn
        self.title = title
        self.occurrence = occurrence
    }
}

/// The four things `winact` does, with exactly the geometry each takes.
///
/// A mirror of the contract's own enum (`contract/asyncapi.yaml`, `winact`)
/// rather than an import of it: this package depends on nothing that can
/// reach a machine, and the host maps these four onto
/// `AgentIntegrationWindowActRequest` at the seam.
///
/// `zoom` and `close` carry no geometry, and that is the contract's rule, not
/// an omission — the standard state is the application's to compute, and a
/// caller that supplied one "would be deciding what the window is for".
public enum WindowOp: Equatable, Sendable {
    /// The window's new CONTENT origin, in guest screen coordinates.
    case move(left: Int, top: Int)
    /// The window's new CONTENT size, at least 1×1.
    case resize(width: Int, height: Int)
    case zoom
    case close
}

/// What NOW's contract can do with one act — the typed discipline the port
/// arrived with, retargeted from upstream's question to this one.
///
/// **The question changed.** Upstream asked "does this target have a QMP
/// socket", because its two answers were the wire and the emulator's mouse.
/// NOW has one wire and no mouse, so the question is now "does NOW's contract
/// declare a command that carries this, and does a rendered scene carry what
/// that command needs to address it" — and those are two questions, which is
/// why there are three answers rather than two.
///
/// Nothing here asks which machine is connected. Whether a *particular* guest
/// answers a command it declares is settled against that guest's own `help`
/// table by the projection layer (`MirrorActProjections`), which is the only
/// side that has one. A host-side guess would be a stale observation wearing
/// the clothes of a live one.
public enum ActionAvailability: Equatable {
    /// NOW declares a command for this act, and a rendered scene carries
    /// everything needed to address it.
    case available(command: String)
    /// NOW declares a command for this act, but it is addressed by an opaque
    /// element reference that only an observation mints — and a scene from
    /// NOW's producer carries none (`Scene.Control.ref` arrives empty; see
    /// `Host/MirrorSceneAdapter`). Expressible, not yet addressable.
    case needsObservation(command: String, reason: String)
    /// Nothing in NOW's contract carries this act.
    case unavailable(reason: String)

    /// Whether this act can be sent as it stands. The GUI grays what is not,
    /// and a caller reports the reason rather than no-opping.
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum ActionModel {

    /// Command-key modifier bit in the Mac event modifiers word (the wire's
    /// `mods` is `evtQModifiers`: cmd=256 shift=512 opt=2048 ctrl=4096).
    public static let cmdKey = 256

    /// Mac US virtual keycodes. Menu shortcut matching keys off the CODE,
    /// not just the char — sending char alone silently no-ops in Finder.
    public static let keycodes: [Character: Int] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
    ]

    /// What NOW can do with this act. A function of the act alone — see
    /// `ActionAvailability` for why there is no target parameter.
    ///
    /// The command names are the contract's own spellings (`contract/
    /// asyncapi.yaml`, `x-commands`), and `NoSecondWireTests` checks every one
    /// of them against that registry. A name that drifts fails here rather
    /// than on a Macintosh, which is the failure `menuinvoke` shipped as.
    public static func availability(
        _ action: MirrorAction) -> ActionAvailability {
        switch action {
        case .menuInvoke:
            /* The one act that crosses whole. `menu`, `item` and `titleLeft`
               all come off the scene the person is looking at, and titleLeft
               is the identity check that distinguishes this press from the
               one made by the person sitting at the machine. */
            return .available(command: "menuact")
        case .key, .type:
            /* A keystroke is how a ⌘-item is meant to travel, and there is
               nothing in the contract that carries one. Named rather than
               folded into the case below, because this is a hole in NOW's
               surface and not a rule against it: nothing about a keystroke
               is host-side cheating. */
            return .unavailable(reason:
                "NOW's contract declares no keystroke command. A ⌘ menu item "
                + "is the ordinary use, and it cannot be sent from here.")
        case .activate:
            /* A process serial, which the scene carries for every window. */
            return .available(command: "activate")
        case .axdo(let ref, _, _, let text):
            /* **The one case that reads its own target, and it has to.**
               The other cases are functions of the act alone because what
               they need is a fact about the CONTRACT. This one needs both
               halves of the question this enum asks — does NOW declare a
               command, and can a rendered scene address it — and only the
               second half is a fact about this particular control.

               It used to answer `needsObservation` unconditionally, on the
               true observation that NOW's scene producer emits controls with
               ref "". That baked a fact about TODAY'S PRODUCER into a
               function, so the day a scene carries references somebody would
               have had to remember to come here and delete it. Read off the
               ref instead and the answer derives: a control that carries one
               is addressable, one that does not is not, and the same control
               in two scenes gets two honest answers.

               The prefix is the act plane's own (`now-element-…`,
               `AgentIntegrationActPolicy`), spelled here rather than
               imported because this package deliberately depends on nothing
               that can reach a machine. A shape check and not a resolution:
               whether the element is still alive is the guest's to say, and
               a host-side match would be a stale observation wearing the
               clothes of a live one. */
            let command = text == nil ? "ctlact" : "textset"
            guard isElementReference(ref) else {
                return .needsObservation(command: command, reason:
                    "\(command) addresses a control by an opaque reference "
                    + "from a current observation, and this control carries "
                    + "none. Rendering a control and acting on it are two "
                    + "different questions to the machine.")
            }
            return .available(command: command)
        case .finderSelect, .finderOpen:
            /* **Available, and the command is `script`.**
               NOW declares `script` and the PowerPC guest serves it; the act
               carries a name and a container and no coordinate, which is
               exactly what the Finder's own `select item "X" of window "Y"`
               takes. So the vocabulary's two questions both answer yes:
               the contract declares a command, and a rendered scene carries
               what that command needs to address the item.

               What is missing is on THIS side — the host has no `script`
               lane — and that is deliberately not this function's answer to
               give. `availability` is a fact about NOW's contract; whether a
               particular host has built the local operation that carries a
               command is a fact about the host, and `MirrorActionDriver`
               says so in its own sentence (the same split `.activate` has
               had since the driver was written). Answering `unavailable`
               here would name the wrong missing half, and would go on doing
               so after the lane lands. */
            return .available(command: "script")
        case .windowAct:
            /* **Available, and the second half of the question is answered
               by an observation this host takes.**
               `winact` is addressed by an opaque `now-window-…`, which no
               scene carries — so on the reading that made `.axdo` answer
               `needsObservation`, this would too. It does not, and the
               difference is real rather than convenient: an element
               reference on a rendered control has NO minter (NOW's producer
               emits ""), while a window reference has one that this host can
               call on the spot — `elements`, aimed by the process serial the
               scene reports for that very window. The scene carries the
               identity; the resolution is a call, not a gap.

               The call can still fail to name one window, and that is the
               resolver's refusal to write, not this function's: see
               `MirrorWindowResolver`. What must never happen is the third
               thing — sending the act at "whatever is frontmost" — and no
               value in this vocabulary can express that. */
            return .available(command: "winact")
        case .click:
            /* Upstream's positional click was a toolkit-worker verb. Its NOW
               shape is ctlact against a referenced control, which is the case
               above; a click at a coordinate names nothing. */
            return .unavailable(reason:
                "NOW's contract declares no positional click. A control is "
                + "acted on through ctlact by reference, not by where it is "
                + "drawn.")
        case .drag, .thumbDrag:
            /* A window move/resize IS expressible — winact takes move and
               resize — but not as a pixel drag, and not without a window
               reference. Saying so is more useful than "no". */
            return .unavailable(reason:
                "a drag is injected mouse motion, which this project solves "
                + "through the guest instead. A window move or resize is "
                + "winact's move/resize against a window reference; a "
                + "scroll-bar drag is ctlact against the indicator part.")
        case .qmpClick, .qmpDoubleClick, .menuDrag:
            /* The three that came across as QMP calls. Their executor is
               deleted and is not coming back. */
            return .unavailable(reason:
                "this crossed as emulator mouse injection over QMP — events "
                + "advanced from outside the guest CPU. NOW solves it through "
                + "the guest or not at all, and there is no emulator on the "
                + "other end of a NOW connection by assumption.")
        }
    }

    /// The shape of a reference an observation minted, checked and not
    /// resolved.
    ///
    /// A second spelling of `AgentIntegrationActPolicy
    /// .isValidElementReference`, and the duplication is the lesser cost:
    /// this package reaches no machine by construction
    /// (`NoSecondWireTests`), and importing the integration module to share
    /// one predicate would hand it the whole local surface. What is
    /// duplicated is a prefix and a UUID shape, which is small enough that
    /// the two cannot drift far, and a drift makes this side report
    /// `needsObservation` for a reference that works — the safe direction.
    static func isElementReference(_ value: String) -> Bool {
        let prefix = "now-element-"
        guard value == value.lowercased(), value.hasPrefix(prefix),
              value.count == prefix.count + 36 else {
            return false
        }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
            != nil
    }

    // MARK: - Guest menu geometry (menu-drag targeting)

    /// OS 9 standard menu rows are 16 px tall, drawn directly below the
    /// 20 px menubar. Item i (1-based) centers at menubarBottom + (i-1)*16
    /// + 8. Calibrated live (see the slice-7 commit) — a wrong row height
    /// selects the wrong item, so treat changes as behavior changes.
    public static let menuRowHeight = 16
    public static let menubarHeight = HitTester.menubarHeight

    static func menuItemPoint(menuLeft: Int, itemIndex: Int) -> (x: Int, y: Int) {
        (menuLeft + 20,
         menubarHeight + 1 + (itemIndex - 1) * menuRowHeight + menuRowHeight / 2)
    }

    // MARK: - Gesture → actions

    /// A primary click on a hit target. Returns the action sequence to
    /// dispatch in order (a background-window click activates first), or
    /// [] when the element is inert (disabled control, desktop backdrop…).
    public static func click(on target: HitTester.Target,
                             count: Int = 1, mods: Int = 0) -> [MirrorAction] {
        switch target {
        case .control(_, let ctl):
            guard ctl.enabled, !ctl.ref.isEmpty else { return [] }
            return [.axdo(ref: ctl.ref, count: count, mods: mods, text: nil)]
        case .scrollbar(_, _, let part, let x, let y):
            // A real press-release at the region: the Control Manager's
            // TrackControl is a tracking loop the wire can't drive (the same
            // story as the title-bar widgets), and it auto-repeats a line/page
            // while the button is held. `axdo` would click the control's
            // CENTRE — a page gap — whatever the user actually pressed.
            // The thumb is a drag, not a click.
            guard part != .thumb else { return [] }
            return [.qmpClick(x: x, y: y)]
        case .appMenu:
            // Opening the switcher is mirror-local UI: nothing is sent to the
            // guest until a row is chosen.
            return []
        case .appMenuItem(let psn, _):
            // Switching apps names a PROCESS, not a place on screen.
            // SetFrontProcess is metal-safe and already proven.
            return [.activate(psn: psn)]
        case .windowItem(_, let name, let windowTitle, _, _):
            // Identical treatment to a desktop icon, and for the same reason
            // — see below. The container is the folder window's own title,
            // which is what the Finder's `window "Y"` matches.
            return item(name, in: .window(title: windowTitle), count: count)
        case .desktopItem(let name, _, _):
            // A plain click SELECTS the icon; a double-click OPENS it.
            //
            // **CHANGED from the port, and it is a route change rather than a
            // preference.** Upstream sent a wire click at the icon's centre
            // and a real QMP double-click to open. NOW has neither: the
            // contract declares no positional click (`mouseloc`'s own
            // description says so, and `docs/input-plane-decisions.md` §2 is
            // the ruling), and there is no emulator on the other end of a NOW
            // connection by assumption. The route the ruling names is the
            // Finder's own identity-addressed `select` / `open`, which is
            // metal-safe and cannot land on a neighbouring icon.
            //
            // The hit tester's centre-of-the-icon arithmetic is NOT wasted by
            // this: it is what decides WHICH icon the person meant, and the
            // point is then dropped rather than sent.
            return item(name, in: .desktop, count: count)
        case .titlebar(_, _, let x, let y):
            // A real click in the title bar raises the window (the guest's
            // SelectWindow) — activate/SetFrontProcess only fronts the app,
            // not a specific window, and never reorders same-app windows.
            return [.qmpClick(x: x, y: y)]
        case .content(_, _, let front, let x, let y):
            // Double-click (open an icon/item) → a real QMP double-click.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            // Front window: a semantic click (metal-safe). Background window:
            // a real click to raise it (+ hit the content), like the guest.
            return front ? [.click(x: x, y: y, count: 1, mods: mods)]
                         : [.qmpClick(x: x, y: y)]
        case .desktop(let x, let y):
            // Double-click a desktop icon → a real QMP double-click (the
            // Finder opens it); single click selects via a wire click.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
        case .widget(_, _, let x, let y):
            // Real press-release inside the box; the widget's tracking loop
            // needs the hardware button.
            return [.qmpClick(x: x, y: y)]
        case .growBox:
            return []   // the grow box acts on drag, not click
        case .menuTitle:
            return []   // opening a menu is UI state, not a guest action
        }
    }

    /// One icon, selected or opened by identity. One place, so the two
    /// containers cannot drift into two spellings of the same rule.
    private static func item(_ name: String, in container: FinderContainer,
                             count: Int) -> [MirrorAction] {
        count >= 2
            ? [.finderOpen(item: name, container: container)]
            : [.finderSelect(item: name, container: container)]
    }

    /// **A primary click, with the scene it happened in.**
    ///
    /// The overload exists because three of the hit tester's targets name a
    /// window by an id and the ACT needs the window's identity — process,
    /// title, occurrence — which only the scene has. The alternatives were
    /// worse in the two ways this file cares about: widening the hit tester's
    /// cases would put act-plane addressing into a geometry type, and looking
    /// the window up inside the driver would put scene knowledge on the far
    /// side of the seam that keeps MirrorKit unable to reach a machine.
    ///
    /// Everything else is delegated unchanged, so there is exactly one
    /// mapping from a target to an act and this is a router, not a second
    /// vocabulary.
    public static func click(on target: HitTester.Target,
                             in scene: Scene,
                             count: Int = 1,
                             mods: Int = 0) -> [MirrorAction] {
        switch target {
        case .widget(let windowID, let kind, _, _):
            guard let win = scene.windows.first(where: { $0.id == windowID }),
                  let target = self.target(for: win, in: scene) else {
                return []
            }
            switch kind {
            case .close:
                /* Destructive, and knowingly so: the contract says an
                   application "may lose unsaved work, or may put up a save
                   dialog nothing on this wire can answer". The dialog is not
                   a reason to suppress the close — it is the application's
                   own question to its own user, and the pane's job is to let
                   the next scene SHOW it. */
                return [.windowAct(window: target, op: .close)]
            case .zoom:
                return [.windowAct(window: target, op: .zoom)]
            case .collapse:
                /* The windowshade box. `winact` has four actions and this is
                   not one of them, so nothing is sent — an act that named
                   `zoom` for a collapse would be this side deciding the two
                   are alike, and they are not: one toggles the standard
                   state, the other rolls the window up. */
                return []
            }
        default:
            return click(on: target, count: count, mods: mods)
        }
    }

    /// A title-bar drag → **move**, expressed as the window's new content
    /// origin rather than as mouse motion.
    ///
    /// The delta is the person's gesture; the origin is derived from the
    /// window's own rect, which is the content port grown UP by the title bar
    /// (`SceneBuilder.titleBarHeight`). So the content top is `rect.t +
    /// titleBarHeight` before the drag, and the move is that point plus the
    /// delta — the same arithmetic the guest would have done had a person
    /// dragged the bar, with no pixel path in between.
    public static func windowMove(_ win: Scene.Window, in scene: Scene,
                                  by delta: (dx: Int, dy: Int))
        -> [MirrorAction] {
        guard let target = target(for: win, in: scene) else { return [] }
        return [.windowAct(window: target,
                           op: .move(left: win.rect.l + delta.dx,
                                     top: win.rect.t + WindowChrome
                                         .titlebarHeight + delta.dy))]
    }

    /// A grow-box drag → **resize**, expressed as the window's new content
    /// size. Floored at 1×1 because the contract's own minimum is "at least 1
    /// point"; a real application will apply its own larger minimum, which is
    /// the point of asking IT to resize rather than moving a rectangle here.
    public static func windowResize(_ win: Scene.Window, in scene: Scene,
                                    by delta: (dx: Int, dy: Int))
        -> [MirrorAction] {
        guard let target = target(for: win, in: scene) else { return [] }
        let width = win.rect.r - win.rect.l + delta.dx
        let height = win.rect.b - (win.rect.t + WindowChrome.titlebarHeight)
            + delta.dy
        return [.windowAct(window: target,
                           op: .resize(width: Swift.max(1, width),
                                       height: Swift.max(1, height)))]
    }

    /// The window's identity as the guest counts it, or nil when the scene
    /// cannot give it one.
    ///
    /// **Occurrence is counted the guest's way or not at all.** The guest
    /// numbers a window among the same-titled windows of the same process, in
    /// window-chain order, front first (`obsmint.c`, `locate_window`); the
    /// scene's `z` is that chain position. Counting any other way would mint
    /// a number that resolves to a neighbouring window — a silent wrong
    /// target, which is the one failure mode this plane is built to refuse.
    public static func target(for win: Scene.Window,
                              in scene: Scene) -> WindowTarget? {
        guard !win.psn.isEmpty else { return nil }
        let earlier = scene.windows.filter {
            $0.psn == win.psn && $0.title == win.title && $0.z < win.z
        }
        return WindowTarget(id: win.id, psn: win.psn, title: win.title,
                            occurrence: earlier.count)
    }

    /// A grow-box drag → resize (GrowWindow tracks from the grab point).
    ///
    /// **Not the route any more.** `windowResize` above is, because a NOW
    /// guest is not an emulator and a pixel drag reaches nothing. Kept for
    /// the reason `menuItem` is kept: it is a correct statement of what the
    /// gesture IS, and `availability(.drag)` is where the reason a drag
    /// cannot travel is written down.
    public static func growDrag(from: (x: Int, y: Int),
                                to: (x: Int, y: Int)) -> [MirrorAction] {
        [.drag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// A scrollbar thumb drag → scroll (TrackControl live-tracks the thumb).
    /// Both points are GLOBAL; the caller maps the control's space through the
    /// window's content origin.
    public static func thumbDrag(from: (x: Int, y: Int),
                                 to: (x: Int, y: Int)) -> [MirrorAction] {
        [.thumbDrag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// A wheel notch over a window → line scrolls on its scrollbar. OS 9 has
    /// no wheel driver, so injecting wheel events would be a no-op dressed up
    /// as support; the honest mapping is the arrow the user would have clicked.
    /// `notches` > 0 scrolls DOWN. Global points, via the content origin.
    public static func wheel(_ notches: Int, on ctl: Scene.Control,
                             contentOrigin: (x: Int, y: Int)) -> [MirrorAction] {
        guard Scrollbar.isLive(ctl), notches != 0,
              let c = Scrollbar.center(ctl, notches > 0 ? .lineDown : .lineUp)
        else { return [] }
        let p = (x: c.x + contentOrigin.x, y: c.y + contentOrigin.y)
        return Array(repeating: MirrorAction.qmpClick(x: p.x, y: p.y),
                     count: Swift.min(abs(notches), 8))
    }

    /// Select a menu item — **both kinds, through the Portal**.
    ///
    /// **CHANGED 2026-08-01, and it is a retraction rather than a
    /// preference.** This used to route a ⌘ item to a keystroke, on the
    /// argument that a shortcut is how such an item is meant to travel and
    /// needs no patch. That was upstream's advice on upstream's guest and it
    /// does not hold here: a menu shortcut is a Command keystroke, `key` on
    /// this Mac cannot carry a modifier at all — CarbonLib has no
    /// `PPostEvent`, so the queue element's modifiers are unreachable — and
    /// the Menu Manager matches on the virtual key code rather than the
    /// character even when it can. The contract says so in `menuact`'s own
    /// description; this is that sentence applied.
    ///
    /// The concrete consequence of the old routing, which is why it is worth
    /// a paragraph: a person clicking File▸Page Setup… in a rendered scene
    /// reached the machine, and the same person clicking File▸Open — the
    /// more ordinary act — produced a `key` that `availability` reports
    /// `unavailable`. Half a menu working is worse than a menu that does
    /// not, because nothing tells the person which half they are in.
    ///
    /// `menuItem(_:)` below still spells the keystroke and is still correct
    /// about what a keystroke IS; it is simply not the route, and is kept
    /// because the vocabulary is the measured half of this port and does not
    /// get edited to match what NOW can currently send.
    ///
    /// We deliberately do NOT gate on `item.enabled`. A classic app disables
    /// its menus at rest and only AdjustMenus()es them at menu-down time, so
    /// the passively-read enable flag reads false even for perfectly
    /// selectable items (SimpleText's whole File menu reads disabled until
    /// you actually pull it down). The guest's own MenuSelect / keystroke
    /// dispatch is the real authority on enablement — a truly disabled item
    /// just no-ops — and the caller verifies the effect by re-poll.
    public static func menuSelect(menu: Scene.Menu,
                                  item: Scene.MenuItem) -> [MirrorAction] {
        guard !item.separator else { return [] }
        // One route for both kinds. The Portal answers the application's own
        // MenuSelect by IDENTITY — titleLeft is the identity check, which is
        // what distinguishes this press from the one made by the person
        // sitting at the machine. Nothing is drawn and no tracking loop runs,
        // so neither the 16px row assumption the guest disproved nor the
        // emulator the drag needed is in the path.
        return [.menuInvoke(menuID: menu.id, itemIndex: item.index,
                            titleLeft: menu.left)]
    }

    /// A title-bar drag gesture → window move (emu-only availability).
    public static func titlebarDrag(from: (x: Int, y: Int),
                                    to: (x: Int, y: Int)) -> [MirrorAction] {
        [.drag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// The keystroke SPELLING of a ⌘-shortcut menu item.
    ///
    /// **No longer a route.** `menuSelect` sends every item through
    /// `menuInvoke` (see the retraction there); this stays because it is a
    /// correct statement of what the keystroke for an item is, and because
    /// `availability(.key)` is the place NOW's missing keystroke command is
    /// named. Deleting it would delete the only expression of a gap that is
    /// declared and owed.
    public static func menuItem(_ item: Scene.MenuItem) -> [MirrorAction] {
        // No `item.enabled` gate — see menuSelect: the resting enable flag is
        // not authoritative for app menus. A ⌘ keystroke to a truly disabled
        // item is a guest-side no-op.
        guard !item.separator, !item.cmd.isEmpty,
              let ch = item.cmd.lowercased().first,
              let ascii = ch.asciiValue else { return [] }
        return [.key(code: keycodes[ch] ?? 0, char: Int(ascii),
                     mods: cmdKey)]
    }

    /// Type into a resolved control: click-to-focus then keystrokes, in one
    /// fail-closed verb.
    public static func typeInto(_ ctl: Scene.Control,
                                text: String) -> [MirrorAction] {
        guard ctl.enabled, !ctl.ref.isEmpty else { return [] }
        return [.axdo(ref: ctl.ref, count: 1, mods: 0, text: text)]
    }
}
