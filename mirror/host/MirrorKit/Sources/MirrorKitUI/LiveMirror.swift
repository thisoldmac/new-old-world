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
/// vocabulary marks emulator-only - a scrollbar part is `ctlact`, a
/// window move is `winact`, neither needs QMP. Re-implementing the
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
    /// Mirror's agent, which is what every conformer was until 2026-08-02.
    var planes: ActionPlanes { .agent }

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

/// The live half of the mirror: owns the poll loop and the dispatcher on a
/// wire-confined queue, publishes scenes to the view. All wire I/O stays off
/// the main thread; a failed poll keeps the last scene and reports in the
/// status line rather than tearing the window down.
public final class LiveMirrorController: MirrorSceneSource {
    @Published public private(set) var scene: MirrorKit.Scene?
    @Published public private(set) var status: String = "connecting…"

    public let target: MirrorTarget
    private let queue = DispatchQueue(label: "mirror.wire")
    private var poller: ScenePoller          // queue-confined after start()
    private let dispatcher: ActionDispatcher // queue-confined
    private var timer: DispatchSourceTimer?
    /// Last good windows per app (psn) — apps flicker into `ax_oracle_*`
    /// errors during interaction (menu tracking starves their sampling), and
    /// their windows must not vanish from the mirror for a frame. Stale
    /// windows are re-composited, never re-frontmost. Queue-confined.
    private var lastWindows: [String: [MirrorKit.Scene.Window]] = [:]

    /// The guest screen size, learned at init (drives the window aspect).
    public let screen: MirrorKit.Scene.ScreenSize

    /// `display` turns on the QDPeek content plane (text/primitives replayed in
    /// window interiors); `islands` additionally fetches the pixels for content
    /// the guest composites offscreen (a Finder window's icons). Both default
    /// off so a plain window is chrome-only — but the `--window` shell passes
    /// the flags through, which is what makes interiors show up live (they were
    /// silently dropped before: the flags only reached the snapshot path).
    public init(target: MirrorTarget,
                display: Bool = false, islands: Bool = false) {
        self.target = target
        // One shared wire: the toolkit worker serves a single connection, so
        // the poller and dispatcher must reuse it (both on `queue`, serial).
        let wire = WireClient(target: target)
        var poller = ScenePoller(target: target, wire: wire)
        poller.includeDesktopItems = true
        poller.includeDisplay = display
        poller.includeIslands = islands
        self.screen = poller.detectScreen()   // one video query at startup
        self.poller = poller
        self.dispatcher = ActionDispatcher(target: target, wire: wire)
    }

    public func start(interval: Double = 0.5) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        do {
            let scene = composite(try poller.poll())
            DispatchQueue.main.async {
                self.scene = scene
                self.status = String(
                    format: "seq %d · %d windows · %.0f ms · %@:%d%@",
                    scene.seq, scene.windows.count,
                    scene.meta.latencyMs ?? -1, self.target.host,
                    self.target.port,
                    scene.meta.errors.isEmpty
                        ? "" : " · stale: \(scene.meta.errors.count) app(s)")
            }
        } catch {
            DispatchQueue.main.async {
                self.status = "poll failed: \(error) (retrying)"
            }
        }
    }

    /// Substitute each erroring app's last good windows so nothing vanishes
    /// mid-interaction; refresh the cache from apps that read clean.
    private func composite(_ scene: MirrorKit.Scene) -> MirrorKit.Scene {
        var scene = scene
        var byApp: [String: [MirrorKit.Scene.Window]] = [:]
        for win in scene.windows {
            byApp[win.psn, default: []].append(win)
        }
        for app in scene.apps {
            if app.error == nil {
                lastWindows[app.psn] = byApp[app.psn] ?? []
            } else if var cached = lastWindows[app.psn], !cached.isEmpty {
                for i in cached.indices {
                    cached[i].front = false   // stale can't be frontmost
                }
                scene.windows.append(contentsOf: cached)
            }
        }
        for (z, i) in scene.windows.indices.enumerated() {
            scene.windows[i].z = z
        }
        return scene
    }

    /// Say something in the status line without dispatching anything. Used
    /// where the honest answer is "I can see what you asked for and cannot
    /// target it reliably" — silence there reads as a broken click.
    public func note(_ message: String) {
        guard !message.isEmpty else { return }
        status = message
    }

    /// Dispatch a gesture's actions, then re-poll immediately so the effect
    /// lands in the next frame instead of the next timer tick.
    public func perform(_ actions: [MirrorAction], label: String) {
        guard !actions.isEmpty else { return }
        for action in actions {
            let availability = ActionModel.availability(action, target: target)
            guard availability == .available else {
                status = "\(label): \(availability)"
                return
            }
        }
        status = label + "…"
        queue.async {
            do {
                try self.dispatcher.perform(actions)
                DispatchQueue.main.async { self.status = label }
            } catch {
                DispatchQueue.main.async {
                    self.status = "\(label) FAILED: \(error)"
                }
            }
            self.tick()
        }
    }
}

/// The live window: SceneView pixels + input routed through the core
/// (HitTester / ActionModel), Platinum-drawn menus, and a status footer.
/// The drawn pixels are exactly RenderShot's.
public struct LiveMirrorView<Source: MirrorSceneSource>: View {
    @ObservedObject var controller: Source
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
    /// The Application menu (app switcher) is open, and which row is hovered.
    @State private var appMenuOpen = false
    @State private var hoveredApp: String?
    @State private var lastClick: (at: Date, x: Int, y: Int)?
    @State private var dragOutline: Rect?
    @State private var dragMode: DragMode?
    @State private var dragStart: (x: Int, y: Int) = (0, 0)
    /// What the pointer is over, named for a person. A mirror is a
    /// picture of another machine and a person cannot tell a live control
    /// from a drawn one by looking; saying so is most of what makes it
    /// feel driveable rather than watched.
    @State private var hovered: String = ""

    /// A live drag in progress, carrying the dragged window's original rect.
    private enum DragMode { case move(Rect), resize(Rect), thumb }

    public init(controller: Source) {
        self.controller = controller
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
                        })
                    SceneView(scene: scene, openMenu: openMenu,
                              hoveredItem: hoveredItem,
                              selectedItem: selectedItem,
                              appMenuOpen: appMenuOpen,
                              hoveredApp: hoveredApp,
                              dragOutline: dragOutline)
                        .gesture(mouseGesture(scene: scene, size: geo.size))
                        .onContinuousHover { phase in
                            /* Name what is under the pointer, and shape
                               the cursor to it. A mirror is a picture of
                               another machine, and a person cannot tell a
                               live control from a drawn one by looking -
                               saying so is most of what makes it feel
                               driveable rather than watched. */
                            if case .active(let pt) = phase,
                               let object = ObjectResolver.object(
                                   at: point(pt, scene, geo.size),
                                   in: scene) {
                                hovered = object.describedForAPerson
                                Self.cursor(for: object).set()
                            } else {
                                hovered = ""
                                NSCursor.arrow.set()
                            }
                            if appMenuOpen {
                                if case .active(let pt) = phase {
                                    let g = guestPoint(pt, scene: scene,
                                                       size: geo.size)
                                    hoveredApp = HitTester.appMenuRow(
                                        scene, x: g.x, y: g.y)?.psn
                                } else {
                                    hoveredApp = nil
                                }
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
                                let g = guestPoint(pt, scene: scene,
                                                   size: geo.size)
                                hoveredItem = SceneRenderer.dropdownItem(
                                    menus[idx], x: g.x, y: g.y)?.index
                            case .ended:
                                hoveredItem = nil
                            }
                        }
                } else {
                    Text("waiting for the first scene…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                /* The hover names what a click WOULD do; the status says
                   what one DID. The second is the answer to a question a
                   person just asked, so it leads. */
                Text(controller.status.isEmpty ? hovered
                     : hovered.isEmpty ? controller.status
                     : "\(controller.status)   ·   over \(hovered)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.thinMaterial)
            }
        }
    }

    // MARK: - Input → core

    /// View point → guest point, via the same FitTransform the renderer
    /// draws with (so a click lands where the pixel is).
    private func guestPoint(_ p: CGPoint, scene: MirrorKit.Scene,
                            size: CGSize) -> (x: Int, y: Int) {
        let logical = SceneRenderer(scene: scene).logicalSize
        return FitTransform(logical: logical, view: size).toGuest(p)
    }

    private func mouseGesture(scene: MirrorKit.Scene,
                              size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = guestPoint(value.startLocation, scene: scene,
                                       size: size)
                let cur = guestPoint(value.location, scene: scene, size: size)
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
                case .none:
                    break
                }
            }
            .onEnded { value in
                let mode = dragMode
                dragMode = nil
                dragOutline = nil
                let start = guestPoint(value.startLocation, scene: scene,
                                       size: size)
                let end = guestPoint(value.location, scene: scene, size: size)
                let moved = abs(end.x - start.x) + abs(end.y - start.y)

                // An open mirror menu owns the next click.
                if let idx = openMenu,
                   let menus = scene.menubar?.menus,
                   menus.indices.contains(idx) {
                    handleMenuClick(menu: menus[idx], at: start)
                    return
                }

                if moved < 6 {
                    // The app switcher is mirror-local UI: opening it sends
                    // nothing to the guest, and only choosing a row does —
                    // as `activate`, which names a process rather than a place.
                    if appMenuOpen {
                        defer { appMenuOpen = false; hoveredApp = nil }
                        if let app = HitTester.appMenuRow(scene, x: start.x,
                                                          y: start.y) {
                            act(.app(.init(psn: app.psn, name: app.name,
                                           isFront: false)),
                                .click(count: 1, mods: 0,
                                       at: Point(x: start.x, y: start.y)))
                        }
                        return
                    }
                    let target = HitTester.hitTest(scene, x: start.x, y: start.y)
                    if case .appMenu = target {
                        appMenuOpen = true
                        openMenu = nil
                        return
                    }
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
                        ActionModel.thumbDrag(from: start, to: end),
                        label: "scroll thumb \(start) → \(end)")
                }
            }
    }

    private func point(_ p: CGPoint, _ scene: MirrorKit.Scene,
                       _ size: CGSize) -> Point {
        let g = guestPoint(p, scene: scene, size: size)
        return Point(x: g.x, y: g.y)
    }

    /// The pointer says what a press would DO, which is the cheapest
    /// honest feedback a mirror can give: a resize corner, a thing that
    /// can be opened, a thing that is only a picture.
    static func cursor(for object: MirrorObject) -> NSCursor {
        switch object {
        case .window(let w):
            switch w.part {
            case .growBox: return .resizeUpDown
            case .titleBar: return .openHand
            default: return .arrow
            }
        case .control, .menu, .menuItem, .app, .finderItem:
            return .pointingHand
        case .desktop:
            return .arrow
        }
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
            at: Point(x: start.x, y: start.y), in: scene) else { return }
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
        case .scrollbar(_, _, let part, _, _): return "scroll \(part.rawValue)"
        case .widget(_, let kind, _, _): return "\(kind) box"
        case .growBox: return "grow box"
        case .titlebar(_, let psn, _, _): return "raise \(psn)"
        case .content(_, _, _, let x, let y): return "\(prefix)click \(x),\(y)"
        case .appMenu: return "application menu"
        case .appMenuItem(_, let name): return "switch to \(name)"
        case .desktopItem(let name, _, _): return "\(prefix)select \(name)"
        case .windowItem(_, let name, _, _): return "\(prefix)select \(name)"
        case .desktop(let x, let y): return "\(prefix)click desktop \(x),\(y)"
        case .menuTitle(let i): return "menu \(i)"
        }
    }
}
