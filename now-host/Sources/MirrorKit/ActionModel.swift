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
    /// `name` is the guest's own named-key vocabulary (return, tab, the
    /// arrows, …) for the keys `code`/`char` cannot express meaningfully on
    /// their own — nil for an ordinary character key, which sends `code`
    /// and `char` as it always did.
    case key(name: String?, code: Int, char: Int, mods: Int)
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
    /// A scrollbar thumb drag. Distinct from `drag` because the DROP POSITION
    /// is the value: TrackControl live-tracks the thumb, so this needs the
    /// precise (unity-compensated) motion a menu drag needs — the 1.6x a
    /// window drag wants would overshoot and slam the thumb to the end.
    case thumbDrag(x0: Int, y0: Int, x1: Int, y1: Int)
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
        case .key(_, _, _, let mods):
            /* CHANGED 2026-08-01, with the host lane that makes the
               distinction matter. `key` is no longer a blanket hole: the
               guest's `key` verb posts an UNMODIFIED keystroke fine — the
               `mods` argument is accepted only as 0 — and `mcp-coverage.md`
               row W3 was "planned" for exactly that reason, not for the
               modified half. So this is a function of `mods`, the same way
               `.axdo` is a function of its own reference:

                 - `mods == 0` — the ordinary case, a pane keystroke with
                   no modifier held — the guest can post it and does.
                 - `mods != 0` — a ⌘/⌥/⌃-held keystroke — remains the true
                   hole. An event's modifiers live on the Event Manager's
                   queue element; the only call that hands that element
                   back is `PPostEvent`, and CarbonLib does not have it
                   (`CALL_NOT_IN_CARBON`). Posting the keystroke and
                   dropping the modifier would type a bare character and
                   answer `ok` — the defect upstream's act plane exists to
                   refuse — so the guest refuses `mods != 0` outright
                   (`contract/asyncapi.yaml:key`,
                   `now-guest-ppc/src/input/input_args.c`) and this side
                   says so before a call is even built rather than sending
                   one the guest will reject.

               `menuSelect` still routes every menu item through `menuact`
               regardless (see its own comment) — this case is about a
               PLAIN keystroke typed at the pane, which a menu press never
               was. */
            guard mods == 0 else {
                return .unavailable(reason:
                    "A modified keystroke cannot be sent: an event's "
                    + "modifiers live on the Event Manager's queue element, "
                    + "and the only call that hands that element back is "
                    + "PPostEvent, which CarbonLib does not have. The guest "
                    + "refuses any key whose mods is not 0 rather than "
                    + "posting it bare and reporting success.")
            }
            return .available(command: "key")
        case .type:
            /* `type` writes text through a control's own setter (`textset`)
               and needs an addressed, referenced control — see `.axdo`. A
               bare `.type` names none, so it stays unavailable; `typeInto`
               below is the reachable route. */
            return .unavailable(reason:
                "NOW's contract writes text through textset against a "
                + "referenced control (see typeInto), not through a typed "
                + "action with no target.")
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
        case .windowItem(_, _, let x, let y):
            // Identical treatment to a desktop icon, and for the same reason:
            // the coordinates are the icon's own centre as the FINDER reports
            // it, so the click is as good as the guest's own layout. Select
            // with a wire click (metal-safe); open with a real double-click,
            // which is the QMP path today.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
        case .desktopItem(_, let x, let y):
            // A plain click SELECTS the icon; a double-click OPENS it. The
            // coordinates are the icon's own centre, not where the pointer
            // landed, so the click is as good as the position the guest itself
            // reported. Selection is metal-safe (a posted click); opening still
            // wants a real double-click, which is the QMP path today.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
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

    /// A grow-box drag → resize (GrowWindow tracks from the grab point).
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
    /// it is `mods: cmdKey` — non-zero — so `availability(.key)` refuses it
    /// exactly the way the guest itself would, which is what the retraction
    /// argues from. Deleting it would delete the only expression of a gap
    /// that is declared and owed.
    public static func menuItem(_ item: Scene.MenuItem) -> [MirrorAction] {
        // No `item.enabled` gate — see menuSelect: the resting enable flag is
        // not authoritative for app menus. A ⌘ keystroke to a truly disabled
        // item is a guest-side no-op.
        guard !item.separator, !item.cmd.isEmpty,
              let ch = item.cmd.lowercased().first,
              let ascii = ch.asciiValue else { return [] }
        return [.key(name: nil, code: keycodes[ch] ?? 0, char: Int(ascii),
                     mods: cmdKey)]
    }

    /// Type into a resolved control: click-to-focus then keystrokes, in one
    /// fail-closed verb.
    public static func typeInto(_ ctl: Scene.Control,
                                text: String) -> [MirrorAction] {
        guard ctl.enabled, !ctl.ref.isEmpty else { return [] }
        return [.axdo(ref: ctl.ref, count: 1, mods: 0, text: text)]
    }

    // MARK: - Pane keystrokes → the guest's front app

    /// One pane keystroke, translated from an ordinary key press (a virtual
    /// key code, the character(s) it produced, and which of Command /
    /// Option / Control were held) into the act this host can send — or the
    /// reason it refuses to send anything.
    ///
    /// **Shift is never folded into `mods`.** The guest's own key table is
    /// case-sensitive on the CHARACTER, not on a modifier bit — `key
    /// {char:'N'}` types an upper-case N by carrying the character, not by
    /// setting a shift bit the guest has nowhere to put
    /// (`now-guest-ppc/src/input/input_args.c`'s own comment on
    /// `g_key_chars`). So a Shift-held press reaches here as an ordinary
    /// character (`characters` already reflects it) and is sent as one;
    /// only Command, Option and Control become `mods` bits, and any of them
    /// being held is what `ActionModel.availability(.key)` goes on to
    /// refuse — this function does not refuse it itself, so the one place
    /// that decides what NOW's contract can carry stays the one place that
    /// decides it.
    ///
    /// Returns nil for a key this vocabulary cannot express at all — a
    /// function key, a character outside the guest's US table — which is
    /// an honest "nothing to send" rather than a guess at a code the guest
    /// was never measured to answer.
    public static func paneKeystroke(
        virtualKeyCode: Int, characters: String?,
        command: Bool, option: Bool, control: Bool
    ) -> MirrorAction? {
        let mods = (command ? cmdKey : 0) | (option ? 2048 : 0)
                 | (control ? 4096 : 0)
        if let name = namedKeyCodes[virtualKeyCode] {
            return .key(name: name, code: virtualKeyCode, char: 0,
                       mods: mods)
        }
        guard let ch = characters?.first, let ascii = ch.asciiValue,
              ascii >= 32, ascii < 127 else {
            /* Not a Mac Roman printable ASCII character this host can
               name a code for — a function key, a dead key still
               composing, a non-Latin input source. Nothing sent, rather
               than a code guessed from a table that does not cover it. */
            return nil
        }
        let code = keycodes[Character(ch.lowercased())] ?? 0
        return .key(name: nil, code: code, char: Int(ascii), mods: mods)
    }

    /// Virtual key codes for `namedKeys`, in the classic Mac numbering the
    /// guest's own table uses and modern Mac keyboards still send
    /// (`now-guest-ppc/src/input/input_args.c:g_key_named`; also Carbon's
    /// published `HIToolbox/Events.h` `kVK_*` constants, P-DOC, which is
    /// where a host-side reader can cross-check them without a Macintosh).
    /// Kept separate from `g_key_named` on purpose: that table also carries
    /// the CHARACTER half, which is the guest's derivation to make, not
    /// this host's to duplicate — `paneKeystroke` sends the name and lets
    /// the guest resolve both halves itself.
    static let namedKeyCodes: [Int: String] = [
        36: "return", 76: "enter", 48: "tab", 49: "space", 51: "delete",
        53: "escape", 114: "help", 115: "home", 117: "fwddelete",
        119: "end", 116: "pageup", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]
}
