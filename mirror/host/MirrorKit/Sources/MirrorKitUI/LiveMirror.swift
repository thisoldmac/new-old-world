import SwiftUI
import MirrorKit

/// **What the live view actually needs from whatever is driving it.**
///
/// DIVERGENCE FROM MIRROR ORIGIN, 2026-08-02, and the smallest one that
/// does the job. `LiveMirrorView` is the only interactive mirror surface
/// that exists - gesture routing, menu tracking, drag modes, double-click
/// timing - and all of it was reachable only through
/// `LiveMirrorController`, which polls Mirror's own line-JSON wire on
/// port 1420 and dispatches through `ActionDispatcher`.
///
/// NOW carries the same scene over a different wire (binary-framed, the
/// guest dials the host) and serves acts its own way, with verbs Mirror's
/// vocabulary marks device-backed fallbacks - a scrollbar part is `ctlact`, a
/// window move is `winact`, neither needs positioned input. Re-implementing the
/// gesture layer to reach them would fork the one piece of this codebase
/// where a subtle behavioural difference is invisible in review and
/// obvious to a person's hand.
///
/// So the view is generic over this instead. Four members, which is
/// exactly what it referenced before: everything else the controller owns
/// - the wire, the poller, the dispatcher, the compositing of stale
/// windows - stays private to whoever conforms.
public protocol MirrorSceneSource: ObservableObject {
    /// The most recent scene, or nil before the first arrives. A failed
    /// poll keeps the last one; the view never tears down on a gap.
    var scene: MirrorKit.Scene? { get }
    /// One line a person reads to know what just happened, including
    /// refusals - silence after a click reads as a broken mirror.
    var status: String { get }
    /// Dispatch a gesture's actions in order, `label` naming the gesture
    /// for the status line.
    func perform(_ actions: [MirrorAction], label: String)
    /// Say something happened that was not an action - "that cannot be
    /// actioned" is a real answer and belongs on screen.
    func note(_ message: String)
    /// What this driver can serve. The gesture layer asks BEFORE it builds
    /// an action, because the same click is a hardware press on one target
    /// and a Control Manager part on another - see `ActionPlanes`.
    var planes: ActionPlanes { get }

    /// Acts a mutation lane is still serving — the one in flight plus the
    /// ones queued behind it. Zero for a driver with no lane, which is
    /// also the default.
    var waitingActs: Int { get }

    /// **Who can hold the mouse button down**, or nil for a driver that
    /// cannot. nil is the default and the honest one: dragging an ITEM needs
    /// a sustained press the semantic act plane has no way to express, and a
    /// driver without one refuses in words rather than dropping the gesture.
    var itemDragDriver: ItemDragDriver? { get }
    /// Abandon the in-flight act and everything queued behind it,
    /// answering how many acts were ended. The default does nothing, for
    /// a driver with no lane to free.
    @discardableResult
    func cancelPendingActs() -> Int

    /// **The object-first entry point, and the one the view uses.**
    ///
    /// A person acted on a THING; what to send is the driver's business.
    /// The default below plans it and expresses the plan in the older
    /// action vocabulary, so a driver written before this still works. A
    /// driver that can talk to the Finder by name overrides it and serves
    /// the two cases no action case can name.
    func perform(_ interaction: Interaction)
}

public extension MirrorSceneSource {
    /// Positioned device input, which every conformer used until 2026-08-02.
    var planes: ActionPlanes { .deviceDriven }

    var waitingActs: Int { 0 }
    var itemDragDriver: ItemDragDriver? { nil }
    @discardableResult
    func cancelPendingActs() -> Int { 0 }

    func perform(_ interaction: Interaction) {
        switch InteractionPolicy.plan(for: interaction, planes: planes) {
        case .nothing(let why):
            /* Not a failure and not silence. A person who clicked
               something inert needs to know the mirror SAW the click. */
            note(why)
        case .unsupported(let why):
            note(why)
        case let plan:
            let actions = InteractionBridge.actions(for: plan,
                                                    interaction: interaction)
            guard !actions.isEmpty else {
                return note("nothing to send for that")
            }
            perform(actions, label: InteractionBridge.label(for: interaction))
        }
    }
}

/// The live window: SceneView pixels + input routed through the core
/// (HitTester / ActionModel), Platinum-drawn menus, and a status footer.
/// The drawn pixels are exactly RenderShot's.
public struct LiveMirrorView<Source: MirrorSceneSource>: View {

    /// **Whose window this mirror is in.**
    ///
    /// A mirror in its own window may take the keyboard and keep it; a
    /// mirror drawn as one pane of a larger application may not, because
    /// `KeyCaptureView` forwards nearly every ⌘ combination to the other
    /// Macintosh and would silently disable the host's own menu bar.
    /// `sharesWindow` names the characters the host keeps and makes focus
    /// click-to-enter.
    public enum Keyboard: Equatable, Sendable {
        case ownsWindow
        case sharesWindow(hostReserved: Set<String>)
    }

    @ObservedObject var controller: Source
    let keyboard: Keyboard
    /// Whether a person has clicked into the mirror, in `sharesWindow`.
    /// Meaningless in `ownsWindow`, where the keyboard is always the
    /// mirror's.
    @State private var keyboardEngaged = false
    @State private var openMenu: Int?
    /// The row under the pointer in the open menu, 1-based. Menus are a
    /// selectable surface: this is what inverts, and what acts.
    @State private var hoveredItem: Int?
    /// The desktop icon we last clicked.
    ///
    /// This is the mirror's own model of selection, not the guest's: the Finder
    /// expresses selection only by inverting the icon on screen, and desktop
    /// icons are not windows or controls, so nothing in `axtree` or `list`
    /// reports it. We know what WE selected; a selection the human makes on the
    /// guest directly is invisible to us and will not show here.
    @State private var selectedItem: String?
    @State private var lastClick: (at: Date, x: Int, y: Int)?
    @State private var dragOutline: Rect?
    @State private var dragMode: DragMode?
    @State private var dragStart: (x: Int, y: Int) = (0, 0)
    /// What the pointer is over, named for a person. A mirror is a
    /// picture of another machine and a person cannot tell a live control
    /// from a drawn one by looking; saying so is most of what makes it
    /// feel driveable rather than watched.
    @State private var hovered: String = ""

    /// An item travelling under the pointer. The transitions belong to
    /// `ItemDragSession` in the core; this view feeds it a pointer and draws
    /// what it says.
    @State private var itemDrag: ItemDragSession?

    /// A live drag in progress, carrying the dragged window's original rect.
    ///
    /// `item` and `refusedItem` are the two ends of the same decision: the
    /// gesture began on a Finder item, and either the mirror could vouch for
    /// where that item lives or it could not. `refusedItem` is a MODE rather
    /// than an early return so the refusal is decided once, on the first move,
    /// instead of being re-derived and re-announced sixty times a second.
    private enum DragMode { case move(Rect), resize(Rect), thumb
                            case item, refusedItem }

    /// `keyboard` defaults to `.ownsWindow`, which is what every caller
    /// meant before there was a second container — so the dedicated
    /// window and `MirrorApp` are unchanged by this parameter existing.
    public init(controller: Source, keyboard: Keyboard = .ownsWindow) {
        self.controller = controller
        self.keyboard = keyboard
    }

    public var body: some View {
        // The guest surface fills the window (FitTransform letterboxes to
        // preserve the guest's aspect, so coords stay exact at any size); the
        // status line floats over the bottom edge as a thin overlay.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let scene = controller.scene {
                    /* The keyboard, underneath everything and filling the
                       whole surface. It draws nothing; it exists to be
                       first responder, because a ⌘ combination has to be
                       caught before the host's menu bar claims it. */
                    KeyCaptureView(
                        onKey: { code, char, mods in
                            act(ObjectResolver.focus(in: scene),
                                .key(code: code, char: char, mods: mods))
                        },
                        onText: { text in
                            act(ObjectResolver.focus(in: scene), .type(text))
                        },
                        onReserved: { combo in
                            controller.note("\(combo) is the host's; the "
                                            + "guest did not get it")
                        },
                        focus: keyCaptureFocus,
                        hostReserved: keyCaptureReserved,
                        onFocusLost: { keyboardEngaged = false })
                    SceneView(scene: scene, openMenu: openMenu,
                              hoveredItem: hoveredItem,
                              selectedItem: selectedItem,
                              dragOutline: dragOutline,
                              itemDrag: itemDrag.map {
                                  SceneRenderer.ProvisionalDrag(
                                      item: $0.subject.item, frame: $0.frame,
                                      confirmed: $0.confirmed)
                              })
                        .gesture(mouseGesture(scene: scene, size: geo.size))
                        .onContinuousHover { phase in
                            /* Name what is under the pointer, and shape
                               the cursor to it. A mirror is a picture of
                               another machine, and a person cannot tell a
                               live control from a drawn one by looking -
                               saying so is most of what makes it feel
                               driveable rather than watched. */
                            if case .active(let pt) = phase,
                               let where_ = point(pt, scene, geo.size),
                               let object = ObjectResolver.object(
                                   at: where_, in: scene) {
                                hovered = object.describedForAPerson
                                Self.cursor(for: object).set()
                            } else {
                                hovered = ""
                                NSCursor.arrow.set()
                            }
                            guard let idx = openMenu,
                                  let menus = scene.menubar?.menus,
                                  menus.indices.contains(idx) else {
                                hoveredItem = nil
                                return
                            }
                            switch phase {
                            case .active(let pt):
                                // Same transform the renderer draws with, so
                                // the row that lights up is the row under the
                                // pointer at any window size.
                                guard let g = guestPoint(pt, scene: scene,
                                                         size: geo.size)
                                else { hoveredItem = nil; return }
                                hoveredItem = SceneRenderer.dropdownItem(
                                    menus[idx], x: g.x, y: g.y)?.index
                            case .ended:
                                hoveredItem = nil
                            }
                        }
                } else {
                    /* Decoration, and it must not take the pointer. A
                       SwiftUI Text installs a TEXT CURSOR RECT through
                       its hosting view, and this one is full-frame - so
                       the I-beam a person sees over the mirror is the
                       host OS answering a question we never asked. Every
                       purely-informational overlay in this stack is
                       marked the same way, so that `cursor(for:)` above
                       is the only thing deciding. */
                    Text("waiting for the first scene…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                /* The Platinum asset pack is a dependency, not repository
                   content (docs/asset-pack.md), and without it the icons,
                   cursors and text on screen are procedural stand-ins.
                   That is a legitimate way to run — but a picture of
                   another machine drawn from art that machine does not
                   own is a CLAIM, and an unmarked one is the failure this
                   project keeps paying for. So the mirror says so, for as
                   long as it is true, where the person looking at it is
                   already looking. It is not in SceneView, deliberately:
                   the render screenshots must stay pixel-comparable. */
                if let banner = AssetPack.bannerText {
                    Text(banner)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.25))
                        .allowsHitTesting(false)
                }
                /* The SAME rule, one level finer. An absent pack is a
                   loud state; a present pack that is missing one FACE is
                   a quiet one, and the quiet one has already cost this
                   project a day of diagnosis aimed at the wrong half of
                   the system - group boxes that appeared to cross their
                   own labels were Chicago standing in for Charcoal and
                   overrunning a band sized for a narrower face.
                   Substituting is now an accepted decision; substituting
                   in silence is not, so the render says which glyphs are
                   ours. Derived, so it retires itself on a desk whose
                   pack rasterises Charcoal. */
                if let banner = FontSubstitution.bannerText {
                    Text(banner)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.25))
                        .allowsHitTesting(false)
                }
                /* The hover names what a click WOULD do; the status says
                   what one DID. The second is the answer to a question a
                   person just asked, so it leads. */
                HStack(spacing: 8) {
                    Text(controller.status.isEmpty ? hovered
                         : hovered.isEmpty ? controller.status
                         : "\(controller.status)   ·   over \(hovered)")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                    /* The way out of a wait. A stuck act used to be
                       unabandonnable — the 87-second queue of 2026-08-05
                       had a person watching with nothing to do — so
                       whenever the lane holds anything, the line that
                       reports the wait also offers to end it. */
                    if controller.waitingActs > 0 {
                        Button("cancel") { controller.cancelPendingActs() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    /* Sharing a window makes the keyboard's owner a thing
                       a person cannot see, and an invisible mode is the
                       failure this project keeps paying for. So it is
                       said, and only while it is true. */
                    if case .sharesWindow = keyboard {
                        Text(keyboardEngaged ? "keyboard ↦" : "click to type")
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.thinMaterial)
            }
        }
    }

    // MARK: - Input → core

    /// View point → guest point, via the same FitTransform the renderer
    /// draws with (so a click lands where the pixel is).
    ///
    /// **nil when the guest has not said how big its screen is**, and
    /// every caller drops the input rather than aiming with a guessed
    /// scale. This is the sharp end of the one-screen rule: a click
    /// mapped through the wrong logical size lands somewhere else on the
    /// real machine, and nothing about the miss says why.
    private func guestPoint(_ p: CGPoint, scene: MirrorKit.Scene,
                            size: CGSize) -> (x: Int, y: Int)? {
        guard let logical = SceneRenderer(scene: scene).logicalSize else {
            return nil
        }
        return FitTransform(logical: logical, view: size).toGuest(p)
    }

    /// What the capture view is told about focus. In `ownsWindow` this is
    /// a constant, so the dedicated window behaves exactly as it did.
    private var keyCaptureFocus: KeyCaptureView.Focus {
        switch keyboard {
        case .ownsWindow: return .ownsWindow
        case .sharesWindow: return .sharesWindow(engaged: keyboardEngaged)
        }
    }

    private var keyCaptureReserved: Set<String> {
        switch keyboard {
        case .ownsWindow: return KeyCaptureView.hostReserved
        case .sharesWindow(let reserved): return reserved
        }
    }

    private func mouseGesture(scene: MirrorKit.Scene,
                              size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                /* Click-to-enter, and this is the only place that can say
                   so: the capture view sits UNDER the scene, so the press
                   a person makes to aim at the other Macintosh is caught
                   here and never reaches the NSView.

                   BEFORE the guard below, deliberately. Engaging the
                   keyboard is about where the person aimed, not about
                   whether this side can name a guest coordinate for it —
                   an unknown screen would otherwise make the window
                   silently refuse to take focus. */
                if case .sharesWindow = keyboard { keyboardEngaged = true }
                guard let start = guestPoint(value.startLocation, scene: scene,
                                            size: size),
                      let cur = guestPoint(value.location, scene: scene,
                                           size: size)
                else { return }
                // First move of this drag: decide if it's a window move or
                // resize, and capture the window's starting rect.
                if dragMode == nil {
                    dragStart = start
                    switch HitTester.hitTest(scene, x: start.x, y: start.y) {
                    case .titlebar(let id, _, _, _):
                        if let w = scene.windows.first(where: { $0.id == id }) {
                            dragMode = .move(w.rect)
                        }
                    case .growBox(let id, _, _):
                        if let w = scene.windows.first(where: { $0.id == id }) {
                            dragMode = .resize(w.rect)
                        }
                    case .scrollbar(_, _, let part, _, _) where part == .thumb:
                        // The guest's TrackControl live-tracks the real mouse;
                        // we just hold the button and move (no outline — the
                        // content itself follows).
                        dragMode = .thumb
                    case .desktopItem, .windowItem:
                        /* Not on the first pixel: a CLICK also arrives here,
                           and taking hold of an item on one would send the
                           guest a press it then has to have released for it.
                           The same 6-px threshold `onEnded` uses to tell a
                           click from a drag decides it, in one place. */
                        if abs(cur.x - start.x) + abs(cur.y - start.y) >= 6 {
                            dragMode = beginItemDrag(scene, at: start,
                                                     now: cur)
                        }
                    default:
                        break
                    }
                }
                // Track the outline (classic Mac dotted rectangle).
                let dx = cur.x - dragStart.x, dy = cur.y - dragStart.y
                switch dragMode {
                case .move(let r):
                    dragOutline = Rect(l: r.l + dx, t: r.t + dy,
                                       r: r.r + dx, b: r.b + dy)
                case .resize(let r):
                    dragOutline = Rect(l: r.l, t: r.t,
                                       r: max(r.l + 80, r.r + dx),
                                       b: max(r.t + 60, r.b + dy))
                case .thumb:
                    // No outline: a scrollbar has no drag ghost — the guest
                    // live-scrolls the content under the thumb instead.
                    break
                case .item:
                    /* RULE 1: no waiting. The ghost is under the pointer on
                       this frame, whatever the guest has or has not said. */
                    moveItemDrag(to: cur)
                case .refusedItem, .none:
                    break
                }
            }
            .onEnded { value in
                let mode = dragMode
                dragMode = nil
                dragOutline = nil
                guard let start = guestPoint(value.startLocation, scene: scene,
                                            size: size),
                      let end = guestPoint(value.location, scene: scene,
                                           size: size)
                else { return }
                let moved = abs(end.x - start.x) + abs(end.y - start.y)

                // An open mirror menu owns the next click.
                if let idx = openMenu,
                   let menus = scene.menubar?.menus,
                   menus.indices.contains(idx) {
                    handleMenuClick(menu: menus[idx], at: start)
                    return
                }

                if moved < 6 {
                    let target = HitTester.hitTest(scene, x: start.x, y: start.y)
                    if case .menuTitle(let index) = target {
                        openMenu = index
                        return
                    }
                    let count = clickCount(at: start)
                    // Selection feedback is ours to draw: the guest expresses it
                    // by inverting the icon and reports it nowhere, so without
                    // this a click on an icon looks like nothing happened even
                    // though the Finder did select it.
                    if case .desktopItem(let name, _, _) = target {
                        selectedItem = name
                    } else if case .desktop = target {
                        selectedItem = nil      // clicking empty desktop clears
                    }
                    guard let object = ObjectResolver.resolve(target,
                                                              in: scene) else {
                        controller.note("nothing under the pointer")
                        return
                    }
                    act(object, .click(count: count, mods: 0,
                                       at: Point(x: start.x, y: start.y)))
                } else if case .move = mode {
                    dragged(scene, from: start, to: end)
                } else if case .resize = mode {
                    dragged(scene, from: start, to: end)
                } else if case .thumb = mode {
                    controller.perform(
                        ActionModel.thumbTracking(from: start, to: end),
                        label: "scroll thumb \(start) → \(end)")
                } else if case .item = mode {
                    endItemDrag(scene, from: start, to: end)
                }
            }
    }

    // MARK: - Dragging an item

    /// Take hold of the item under `start`, or say why not.
    ///
    /// **The refusal is the interesting half.** `DragTargeting.subject`
    /// declines an item whose position this side cannot vouch for, and until
    /// 2026-08-07 that was every item on the desktop: the icons came from the
    /// saved `fdLocation` grid and the disks from a layout rule the host
    /// invented, both flying `placed = true`. Picking one of those up would
    /// have meant promising to put it back somewhere nobody had measured.
    private func beginItemDrag(_ scene: MirrorKit.Scene,
                               at start: (x: Int, y: Int),
                               now: (x: Int, y: Int)) -> DragMode {
        switch DragTargeting.subject(scene, x: start.x, y: start.y) {
        case .failure(let refusal):
            controller.note(refusal.message)
            return .refusedItem
        case .success(let subject):
            guard let home = DragTargeting.home(of: subject, in: scene) else {
                controller.note("the mirror lost track of where "
                                + "\(subject.name) is — nothing was dragged")
                return .refusedItem
            }
            guard let driver = controller.itemDragDriver else {
                /* Honest, and specific. "Nothing happened" is what this used
                   to look like, and a person cannot tell it from a mirror
                   that is broken. */
                controller.note("this mirror cannot hold the mouse button "
                                + "down — \(subject.name) was not dragged")
                return .refusedItem
            }
            var session = ItemDragSession(
                subject: subject, home: home,
                grabbedAt: Point(x: start.x, y: start.y))
            session.move(to: Point(x: now.x, y: now.y))
            itemDrag = session
            driver.dragPress(subject, at: Point(x: start.x, y: start.y)) {
                answer in
                /* THE ONLY DOOR TO CONFIRMED. A `.confirmed` this side made
                   up would be exactly the plausible wrong answer the arc is
                   about — and the session type has no other way in. */
                guard var live = itemDrag, live.subject == subject else {
                    return
                }
                switch answer {
                case .confirmed:
                    live.confirm()
                    itemDrag = live
                case .refused(let why):          // RULE 4
                    finish(live.refused(why))
                }
            }
            return .item
        }
    }

    private func moveItemDrag(to p: (x: Int, y: Int)) {
        guard var live = itemDrag else { return }
        live.move(to: Point(x: p.x, y: p.y))
        itemDrag = live
        controller.itemDragDriver?.dragMove(to: Point(x: p.x, y: p.y))
    }

    /// Carry out an ending the session decided.
    ///
    /// One function for both unhappy endings because they are one behaviour —
    /// the mirror showed something it could not vouch for and takes it back —
    /// and two implementations would be two chances to leave a ghost on screen
    /// after a failure, which reads as the drag having worked.
    private func finish(_ ending: ItemDragSession.Ending) {
        switch ending {
        case .snapBack(let why):
            itemDrag = nil
            controller.note(why)
        case .drop(let plan):
            controller.note(describe(plan))
            controller.itemDragDriver?.dragRelease(plan) { answer in
                switch answer {
                case .confirmed:
                    /* The guest has it. Drop the ghost and let the next scene
                       draw the item where it now lives — a ghost kept past
                       this point would be the mirror asserting a position
                       nobody has reported yet. */
                    itemDrag = nil
                case .refused(let why):
                    guard let live = itemDrag else { return }
                    finish(live.refused(why))
                }
            }
        }
    }

    /// The release. The DECISION is `ItemDragSession.release` — see the four
    /// rules there; this is the part that talks to the driver.
    private func endItemDrag(_ scene: MirrorKit.Scene,
                             from start: (x: Int, y: Int),
                             to end: (x: Int, y: Int)) {
        guard let live = itemDrag else { return }
        let ending = live.release(
            DragTargeting.plan(scene, from: start, to: end))
        if case .snapBack = ending {
            /* The button still goes up. A mouse left down is the one failure
               the resident's dead-man exists for, and this side must not be
               the reason it has to fire. */
            controller.itemDragDriver?.dragRelease(nil) { _ in }
        }
        finish(ending)
    }

    /// What a drop is about to do, for the status line. Named per intent
    /// because "moved" and "rearranged" are different promises.
    private func describe(_ plan: DragTargeting.Plan) -> String {
        let name = plan.subject.name
        switch (plan.intent, plan.destination) {
        case (.rearrange, _):
            return "moving \(name) within its own window"
        case (_, .applicationIcon(let app, _, _)):
            return "opening \(name) with \(app)"
        case (_, .desktop):
            return "moving \(name) to the desktop"
        case (_, .finderWindow(_, let path, _, _)):
            return "moving \(name) into \(path)"
        case (_, .container(let into, _, _, _)):
            return "moving \(name) into \(into)"
        case (_, .applicationWindow(_, _, let app, _, _)):
            return "giving \(name) to \(app)"
        }
    }

    private func point(_ p: CGPoint, _ scene: MirrorKit.Scene,
                       _ size: CGSize) -> Point? {
        guestPoint(p, scene: scene, size: size).map {
            Point(x: $0.x, y: $0.y)
        }
    }

    /// THE POINTER IS A CLAIM, so it is made deliberately and only where
    /// the guest's own scene supports it.
    ///
    /// This used to shape the cursor to whatever the resolver named — a
    /// pointing hand over every control, an open hand over a title bar —
    /// on the reasoning that saying what a press would do is what makes a
    /// mirror feel driveable. The trouble is that a mirror is a picture
    /// of another machine, and a cursor that promises "this is a button"
    /// over an element whose kind we have not proven is the same
    /// confident wrong answer plan 018 is about everywhere else. 62% of
    /// elements carry no determined kind (docs/mirror-element-coverage.md).
    ///
    /// So: the ARROW is the default and the honest one, and there is
    /// exactly one exception — an I-beam over a dialog item the GUEST
    /// says is editable text. That claim comes from `semanticKind`, the
    /// same v2 evidence the renderer and the hit tester read, rather than
    /// from a second traversal of the same truth.
    ///
    /// Michelle, 2026-08-07: "use the normal pointer everywhere and just
    /// focus on getting the text cursor over editable text areas."
    ///
    /// NOT YET DONE, and it is the direction rather than a gap here: the
    /// guest has its own cursor and does not report it. Mirroring that
    /// (Lane C's asset pack already carries 43 extracted `CURS`
    /// resources) needs a capture-side verb and a contract field, and
    /// belongs to its own slice.
    static func cursor(for object: MirrorObject) -> NSCursor {
        if case .dialogItem(let item) = object,
           item.semanticKind == "editText" {
            return .iBeam
        }
        return .arrow
    }

    /// Hand one interaction to the driver. Every gesture in this view
    /// funnels through here, which is what makes "the driver decides"
    /// true rather than aspirational.
    private func act(_ object: MirrorObject, _ gesture: MirrorGesture) {
        controller.perform(Interaction(object: object, gesture: gesture))
    }

    /// A drag that grabbed window chrome. The object is resolved from
    /// where the gesture BEGAN - by the time it ends the pointer has left
    /// the title bar, and an act names the window, not the pointer.
    private func dragged(_ scene: MirrorKit.Scene,
                         from start: (x: Int, y: Int),
                         to end: (x: Int, y: Int)) {
        guard let object = ObjectResolver.object(
            at: Point(x: start.x, y: start.y), in: scene) else {
            /* A SILENT RETURN HERE IS THE WORST KIND OF FAILURE, and it
               was one until 2026-08-03: a drag whose start point resolved
               to no object simply vanished - nothing sent, nothing said,
               nothing logged. From a chair it is identical to a drag that
               was sent and ignored, and a whole afternoon was spent
               scoring window moves as broken on exactly that ambiguity.
               One title-bar drag failed and an identical one 60px away
               worked, which is what this line explains. */
            controller.note("nothing at \(start.x),\(start.y) to drag - "
                            + "the drag was not sent")
            return
        }
        act(object, .drag(from: Point(x: start.x, y: start.y),
                          to: Point(x: end.x, y: end.y), mods: 0))
    }

    /// The window a drag GRABBED, found from where the gesture began.
    /// A window act names the window, and the pointer has moved by the
    /// time the drag ends - so the lookup uses the start point, which is
    /// the only one guaranteed to be inside it.
    private func draggedWindow(at start: (x: Int, y: Int))
        -> MirrorKit.Scene.Window? {
        guard let scene = controller.scene else { return nil }
        switch HitTester.hitTest(scene, x: start.x, y: start.y) {
        case .titlebar(let id, _, _, _), .growBox(let id, _, _):
            return scene.windows.first { $0.id == id }
        default:
            return nil
        }
    }

    private func handleMenuClick(menu: MirrorKit.Scene.Menu,
                                 at p: (x: Int, y: Int)) {
        defer { openMenu = nil; hoveredItem = nil }
        let screenWidth = controller.scene?.screen.w ?? 0
        if let item = SceneRenderer.dropdownItem(
            menu, x: p.x, y: p.y, screenWidth: screenWidth) {
            // Dispatch by IDENTITY, and refuse rather than guess.
            //
            // A ⌘ item goes as a keystroke: deterministic, metal-safe, and it
            // names the item rather than a location. A shortcut-less item has
            // only the coordinate drag, and that drag is provably wrong — it
            // assumes uniform 16 px rows (ActionModel.menuItemPoint) while the
            // guest draws separators shorter, so every item below a separator
            // targets a DIFFERENT row. Firing it selects the wrong command,
            // which is worse than doing nothing and saying so.
            //
            // The service already treats this drag as experimental and hides it
            // behind an explicit allowDrag; the window path was firing it
            // unconditionally. It no longer does.
            // Both paths act by IDENTITY now: a ⌘ item as a keystroke, a
            // shortcut-less one through the Portal, which answers the app's own
            // MenuSelect. Neither depends on where a row happens to be drawn,
            // which is what used to make selection miss.
            /* Object-first here too: the row is a THING with a menu id
               and an index, and the driver decides whether that becomes a
               keystroke or a MenuSelect the application answers. Either
               way it does not depend on where the row was drawn, which is
               what used to make selection miss below a separator. */
            act(ObjectResolver.menuItem(item, in: menu, index: item.index,
                                        apps: controller.scene?.apps ?? []),
                .click(count: 1, mods: 0, at: Point(x: p.x, y: p.y)))
        }
        // Clicking a different title while open switches menus.
        if p.y < HitTester.menubarHeight,
           let scene = controller.scene,
           case .menuTitle(let index) = HitTester.hitTest(scene, x: p.x,
                                                          y: p.y) {
            openMenu = index
        }
    }

    /// Double-click detection: two clicks within 400 ms and 6 px.
    private func clickCount(at p: (x: Int, y: Int)) -> Int {
        defer { lastClick = (Date(), p.x, p.y) }
        if let last = lastClick,
           Date().timeIntervalSince(last.at) < 0.4,
           abs(last.x - p.x) + abs(last.y - p.y) < 6 {
            lastClick = nil
            return 2
        }
        return 1
    }

    private func label(for target: HitTester.Target, count: Int) -> String {
        let prefix = count == 2 ? "double-" : ""
        switch target {
        case .control(_, let c):
            return "\(prefix)axdo \(c.title.isEmpty ? c.ref : c.title)"
        case .dialogItem(_, let item):
            return "\(prefix)dialog item \(item.number)"
        case .scrollbar(_, _, let part, _, _): return "scroll \(part.rawValue)"
        case .widget(_, let kind, _, _): return "\(kind) box"
        case .growBox: return "grow box"
        case .titlebar(_, let psn, _, _): return "raise \(psn)"
        case .content(_, _, _, let x, let y): return "\(prefix)click \(x),\(y)"
        case .menubarBackground: return "unreported menu bar"
        case .desktopItem(let name, _, _): return "\(prefix)select \(name)"
        case .windowItem(_, let name, _, _): return "\(prefix)select \(name)"
        case .desktop(let x, let y): return "\(prefix)click desktop \(x),\(y)"
        case .menuTitle(let i): return "menu \(i)"
        }
    }
}
