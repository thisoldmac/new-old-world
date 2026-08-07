import Foundation

/// **What serving an interaction requires — a plan, not a wire call.**
///
/// The decision of what a gesture on an object MEANS is pure, so it is
/// tested without a machine and read without a debugger. Executing the
/// plan is the driver's job and is a switch with no judgement in it.
///
/// Every case names a capability rather than a verb, because two guests
/// may serve the same meaning differently — `finderSelect` is an Apple
/// event on one machine and could be something else on another.
public enum InteractionPlan: Equatable, Sendable {

    /// Press a Control Manager part on a resolved control.
    case controlPart(ref: String, part: Int, mods: Int)

    /// Ask the addressed dialog's own event path to select one 1-based
    /// DITL item. Kept separate from Control Manager tracking on purpose.
    case dialogItem(ref: String, item: Int)

    /// A Window Manager operation on a resolved window.
    case windowAct(ref: String, act: MirrorAction.WindowAct)

    /// Perform a menu command by identity, not by where its row was drawn.
    case menuCommand(menuID: Int, itemIndex: Int, titleLeft: Int)

    /// One keystroke. Menu shortcuts must carry the VIRTUAL KEYCODE —
    /// a Mac's `MenuEvent` matches on the code, not the character.
    case keystroke(code: Int, char: Int, mods: Int)

    /// Type text wherever the guest's focus is.
    case typeText(String)

    /// Set a resolved text element's contents outright.
    case setText(ref: String, text: String)

    /// Bring an application forward, by PSN.
    case activateApp(psn: String)

    /// Bring the owning application forward, then select this exact window
    /// within it. Both identities come from the same guest scene.
    case activateWindow(psn: String, ref: String)

    /// Apply one system-owned visibility command from the Application
    /// menu. Kept typed so it cannot fall back to commanding menu -16489,
    /// the route that reported success without changing the machine.
    case applicationVisibility(ApplicationVisibility)

    /// Open one system-owned Apple Menu Items entry through the guest
    /// Finder. CarbonLib does not expose OpenDeskAcc to the guest app.
    case openAppleMenuItem(name: String)

    /// Ask the Finder to select or open an item BY NAME. This is the
    /// case the whole object-first shape exists for: an icon has no
    /// control reference and no window of its own, so a gesture-first
    /// model could only reach it by clicking a pixel — and a guest with
    /// no positional click verb could not do that at all. The Finder has
    /// always known it by name.
    case finderSelect(item: String, container: FinderContainer)
    case finderOpen(item: String, container: FinderContainer)
    /// Clear the Finder's selection — what clicking empty desktop does.
    case finderDeselect

    /// Legitimately nothing to send. Opening a menu is mirror-local;
    /// clicking the front window's own empty content is a no-op on a
    /// Mac too. Distinct from a refusal, and a status line should say
    /// so differently or say nothing at all.
    case nothing(why: String)

    /// This driver cannot serve it, and the reason names which half is
    /// missing. Never a silent drop: a person who clicks and gets
    /// silence concludes the mirror is broken.
    case unsupported(why: String)

    public enum FinderContainer: Equatable, Sendable {
        case desktop
        /// A Finder window, by its title — which is how the Finder's own
        /// scripting addresses it.
        case window(title: String)
    }

    public enum ApplicationVisibility: Equatable, Sendable {
        case hide(psn: String, incarnation: String?, name: String,
                  menuID: Int, itemIndex: Int, titleLeft: Int)
        case hideOthers(exceptPSN: String, incarnation: String?, name: String,
                        menuID: Int, itemIndex: Int, titleLeft: Int)
        case showAll
    }
}

/// The rules. One function, one switch, no I/O.
public enum InteractionPolicy {

    public static func plan(for interaction: Interaction,
                            planes: ActionPlanes = .residentActPlane)
        -> InteractionPlan {
        switch interaction.object {
        case .control(let c):   return control(c, interaction.gesture, planes)
        case .dialogItem(let i): return dialogItem(i, interaction.gesture,
                                                  planes)
        case .window(let w):    return window(w, interaction.gesture, planes)
        case .menuItem(let i):  return menuItem(i, interaction.gesture,
                                                planes)
        case .applicationMenuAction(let a):
            return applicationMenuAction(a, interaction.gesture)
        case .menu:             return .nothing(why: "opening a menu is the "
                                                + "mirror's own drawing; "
                                                + "nothing is sent until a "
                                                + "row is chosen")
        case .app(let a):       return app(a, interaction.gesture)
        case .finderItem(let f): return finderItem(f, interaction.gesture)
        case .desktop(let owner): return desktop(owner,
                                                 interaction.gesture)
        }
    }

    // MARK: - Dialog Manager items

    private static func dialogItem(_ item: MirrorObject.DialogItem,
                                   _ gesture: MirrorGesture,
                                   _ planes: ActionPlanes)
        -> InteractionPlan {
        guard case .click = gesture else {
            return .nothing(why: "that dialog item answers to a click")
        }
        guard planes.semanticActs else {
            return .unsupported(why: "this driver has no resident dialog "
                                + "item act plane")
        }
        guard item.isEnabled else {
            return .nothing(why: "that dialog item is disabled")
        }
        guard item.isSemanticallyActionable,
              item.semanticAction == "press" else {
            return .unsupported(why: "the guest did not provide complete, "
                                + "authoritative press semantics for that "
                                + "dialog item")
        }
        guard let ref = item.ref, !ref.isEmpty else {
            return .unsupported(why: "that dialog item reached the mirror "
                                + "with no reference, so nothing can address "
                                + "it")
        }
        return .dialogItem(ref: ref, item: item.number)
    }

    // MARK: - Controls

    private static func control(_ c: MirrorObject.Control,
                                _ gesture: MirrorGesture,
                                _ planes: ActionPlanes) -> InteractionPlan {
        guard planes.semanticActs else {
            return .unsupported(why: "this driver has no act plane, so a "
                                + "control cannot be addressed by reference")
        }
        guard c.isEnabled else {
            return .nothing(why: "that control is disabled")
        }
        guard c.isSemanticallyActionable else {
            /* **Name the missing fact, and the route that survives.**
               This said "the guest did not provide complete, authoritative
               semantics for that control" — a verdict, with nothing in it
               a person could do anything about. Michelle read exactly that
               sentence off the status line of a modal she could not
               dismiss, and it told her neither what was unknown nor that
               anything else was still possible.
               `ctlact` with an explicit point does still reach these: the
               guest checks the point against the rect the resolver proved
               and never consults the kind. */
            return .unsupported(why: "\(c.missingSemanticFact), so this "
                                + "driver will not decide for it. Pressing "
                                + "it by position is still possible and "
                                + "nothing here has done so")
        }
        guard !c.ref.isEmpty else {
            return .unsupported(why: "that control reached the mirror with "
                                + "no reference, so nothing can address it")
        }

        switch gesture {
        case .click(_, let mods, _):
            guard c.semanticAction == "press" || c.semanticAction == "scroll"
            else {
                return .unsupported(why: "the guest advertises "
                                    + "\(c.semanticAction ?? "no") semantics, "
                                    + "but this driver has no matching act")
            }
            /* THE POINT IS METADATA and this is where it earns its keep:
               the part was resolved with the object, so the press knows
               whether it was an arrow, a page gap or the thumb without
               anyone re-deriving it from coordinates. */
            if let part = c.part {
                guard part != .thumb else {
                    return .nothing(why: "a press on the thumb positions it; "
                                    + "drag it instead")
                }
                return .controlPart(ref: c.ref,
                                    part: ActionModel.partCode(part),
                                    mods: mods)
            }
            /* Not a scroll bar: a plain control, and the button part is
               what a click on one is. */
            return .controlPart(ref: c.ref, part: 10, mods: mods)

        case .scroll(let notches, _):
            /* A wheel is pages, not lines: OS 8/9 has no wheel, so there
               is no "right" mapping to inherit - pages are what the
               scroll bar itself offers and they move a readable amount. */
            let part = notches > 0 ? Scrollbar.Part.pageDown : .pageUp
            return .controlPart(ref: c.ref,
                                part: ActionModel.partCode(part), mods: 0)

        case .drag:
            /* The honest gap, named. Positioning a thumb means SETTING a
               value, and `ctlact` presses a part at the control's own
               centre - it has no way to say where along the track the
               press landed. Paging there in a loop would overshoot and
               look like a stutter. */
            return .unsupported(why: "dragging a scroll thumb needs a verb "
                                + "that sets a control's value; the act "
                                + "plane presses a part at the control's "
                                + "own centre and cannot position one")

        case .type(let text):
            return .setText(ref: c.ref, text: text)

        case .key(let code, let char, let mods):
            return .keystroke(code: code, char: char, mods: mods)
        }
    }

    // MARK: - Windows

    private static func window(_ w: MirrorObject.Window,
                               _ gesture: MirrorGesture,
                               _ planes: ActionPlanes) -> InteractionPlan {
        // Typing and keys are about focus, not about the window's chrome.
        switch gesture {
        case .type(let text):  return .typeText(text)
        case .key(let code, let char, let mods):
            return .keystroke(code: code, char: char, mods: mods)
        default: break
        }

        guard planes.semanticActs else {
            return .unsupported(why: "this driver has no act plane")
        }
        guard let ref = w.ref else {
            return .unsupported(why: "that window reached the mirror with no "
                                + "reference - its guest could not read it "
                                + "at the classic offsets, so no act can "
                                + "name it")
        }

        switch (w.part, gesture) {

        case (.closeBox, .click):
            return .windowAct(ref: ref, act: .close)
        case (.zoomBox, .click):
            return .windowAct(ref: ref, act: .zoom(out: true))
        case (.collapseBox, .click):
            /* The Window Manager exposes no collapse operation, so there
               is nothing to send. Inventing a name for it would promise
               a capability that does not exist. */
            return .unsupported(why: "there is no window-collapse operation "
                                + "to send; the box is drawn but the act "
                                + "does not exist on the wire")

        case (.titleBar, .drag(let from, let to, _)):
            let top = w.rect.t + SceneBuilder.titleBarHeight
            return .windowAct(ref: ref,
                              act: .move(left: w.rect.l + (to.x - from.x),
                                         top: top + (to.y - from.y)))
        case (.growBox, .drag(_, let to, _)):
            let top = w.rect.t + SceneBuilder.titleBarHeight
            return .windowAct(ref: ref,
                              act: .resize(width: max(1, to.x - w.rect.l),
                                           height: max(1, to.y - top)))

        case (.titleBar, .click), (.content, .click):
            /* A window click has two ordered effects: activate its process,
               then select that exact window within the process. Collapsing
               these to process activation made a second Finder window
               impossible to bring forward. */
            return w.isFront
                ? .nothing(why: "that window is already front")
                : .activateWindow(psn: w.psn, ref: ref)

        case (_, .scroll):
            return .nothing(why: "there is no scroll bar under the pointer")

        default:
            return .nothing(why: "nothing to do there")
        }
    }

    // MARK: - Menus, apps, the Finder

    private static func menuItem(_ i: MirrorObject.MenuItem,
                                 _ gesture: MirrorGesture,
                                 _ planes: ActionPlanes) -> InteractionPlan {
        guard case .click = gesture else {
            return .nothing(why: "a menu row answers to a click")
        }
        if i.isSeparator { return .nothing(why: "that is a separator") }
        guard i.isEnabled else {
            return .nothing(why: "\"\(i.title)\" is disabled")
        }
        /* **An Apple Menu Items row is a FILE, and no application's menu
           dispatch opens one.** This used to name Key Caps alone, so every
           other row took the command route below and was answered by a
           front application that has no Apple-menu case — silently, and
           looking exactly like an act that never left. Michelle,
           2026-08-06: "apple menu items dont work (apple menu -> control
           panels, sherlock, system profiler etc)". The act did leave, and
           `ObjectResolver.isAppleMenuItemsEntry` carries the reason it had
           nowhere to land. */
        if i.isAppleMenuItemsEntry {
            return .openAppleMenuItem(name: i.title)
        }
        /* A ⌘ item goes as a keystroke ONLY where a keystroke can carry
           the ⌘. NOW's Carbon guest cannot post one - PPostEvent is not
           in CarbonLib, and it refuses rather than typing a bare
           character and reporting success - so on that guest a shortcut
           item takes the same route as a shortcut-less one: the act
           plane, answering the application's own MenuSelect, which needs
           no modifier at all.

           Neither route depends on where the row was DRAWN, which is
           what used to make selection miss below a separator. */
        /* The table is keyed lowercase, and the CODE is the part that
           matters: a Mac's MenuEvent matches the virtual keycode, not the
           character - the finding that cost this project a day. The char
           travels as the glyph the menu displays. */
        if planes.modifiedKeystrokes,
           let shown = i.cmd.unicodeScalars.first, !i.cmd.isEmpty,
           let code = ActionModel.keycodes[
               Character(String(shown).lowercased())] {
            return .keystroke(code: code, char: Int(shown.value),
                              mods: ActionModel.cmdKey)
        }
        guard let titleLeft = i.menu.left else {
            /* THE SCENE HALF IS MISSING, and it is the half this act is
               guarded by. `titleLeft` is where the press arms, and the
               resident answers a MenuSelect at that point and no other -
               so a substituted number does not miss, it answers
               SOMEBODY ELSE'S press. Refused with the reason rather than
               served with a guess. */
            return .unsupported(why: "the scene does not say where "
                                + "\"\(i.menu.title)\" sits in the menu "
                                + "bar, and that position is what tells "
                                + "this act's press from the person's at "
                                + "the machine")
        }
        return .menuCommand(menuID: i.menu.id, itemIndex: i.index,
                            titleLeft: titleLeft)
    }

    private static func app(_ a: MirrorObject.App,
                            _ gesture: MirrorGesture) -> InteractionPlan {
        switch gesture {
        case .click:
            return a.isFront
                ? .nothing(why: "\(a.name) is already front")
                : .activateApp(psn: a.psn)
        case .key(let code, let char, let mods):
            return .keystroke(code: code, char: char, mods: mods)
        case .type(let text):
            return .typeText(text)
        default:
            return .nothing(why: "nothing to do there")
        }
    }

    /// One sentence for the one absence, so the two places that refuse
    /// it cannot drift into saying different things about it.
    static func unplacedMenu(_ title: String) -> String {
        "the scene does not say where that menu sits in the menu bar, and "
            + "that position is what tells this act's press from the "
            + "person's at the machine"
    }

    private static func applicationMenuAction(
        _ action: MirrorObject.ApplicationMenuAction,
        _ gesture: MirrorGesture
    ) -> InteractionPlan {
        guard case .click = gesture else {
            return .nothing(why: "an Application-menu row answers to a click")
        }
        guard action.isEnabled else {
            return .nothing(why: "\"\(action.title)\" is disabled")
        }
        /* The Application menu's own `left` is 0 on a real Mac and that
           is a READING, not an absence: the Menu Manager right-aligns it
           and reports no useful left edge (SceneRenderer says the same
           thing where it declines to draw it from that number). nil is
           the different case - the producer said nothing - and it is
           refused here for the same reason an ordinary menu is. */
        var reported: Int? { action.menu.left }
        switch action.kind {
        case .hide(let app):
            guard let titleLeft = reported else {
                return .unsupported(why: unplacedMenu(action.menu.title))
            }
            return .applicationVisibility(.hide(
                psn: app.psn, incarnation: app.incarnation, name: app.name,
                menuID: action.menu.id, itemIndex: action.index,
                titleLeft: titleLeft))
        case .hideOthers(let app):
            guard let titleLeft = reported else {
                return .unsupported(why: unplacedMenu(action.menu.title))
            }
            return .applicationVisibility(.hideOthers(
                exceptPSN: app.psn, incarnation: app.incarnation,
                name: app.name, menuID: action.menu.id,
                itemIndex: action.index, titleLeft: titleLeft))
        case .showAll:
            return .applicationVisibility(.showAll)
        }
    }

    private static func finderItem(_ f: MirrorObject.FinderItem,
                                   _ gesture: MirrorGesture)
        -> InteractionPlan {
        let container: InteractionPlan.FinderContainer =
            f.container.map { .window(title: $0.title) } ?? .desktop
        switch gesture {
        case .click(let count, _, _):
            /* By NAME, both of them. This is the payoff: an icon has no
               control reference and no window, so a gesture-first model
               could only click its pixel - and a guest with no positional
               click verb could not do even that. */
            return count >= 2
                ? .finderOpen(item: f.name, container: container)
                : .finderSelect(item: f.name, container: container)
        case .key(let code, let char, let mods):
            return .keystroke(code: code, char: char, mods: mods)
        default:
            return .nothing(why: "nothing to do there")
        }
    }

    private static func desktop(_ owner: MirrorObject.App?,
                                _ gesture: MirrorGesture) -> InteractionPlan {
        switch gesture {
        case .click(let count, _, _):
            /* CLICKING THE DESKTOP BRINGS THE FINDER FORWARD, which is
               what it does on a Macintosh and what this did not do. With
               the app switcher listing only applications that have
               windows - and the Finder's only window being the backdrop -
               that left the mirror unable to reach the Finder AT ALL. */
            if let owner, !owner.isFront {
                return .activateApp(psn: owner.psn)
            }
            return count >= 2
                ? .nothing(why: "double-clicking empty desktop does nothing")
                : .finderDeselect
        case .key(let code, let char, let mods):
            return .keystroke(code: code, char: char, mods: mods)
        case .type(let text):
            return .typeText(text)
        default:
            return .nothing(why: "nothing to do there")
        }
    }
}
