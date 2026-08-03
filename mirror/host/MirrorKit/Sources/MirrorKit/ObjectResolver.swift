import Foundation

/// **A point on the screen becomes a thing with a name.**
///
/// Built on `HitTester` rather than beside it. That geometry — z-order
/// across windows, the title-bar strip a dialog does not have, controls
/// in content-relative space, icons under a scroll bar that is still a
/// scroll bar — is measured, tested and hard-won, and a second
/// implementation of it would drift the day after it was written.
///
/// What this adds is **identity**. `HitTester` answers with a rendering
/// key (`windowID`) because that is all a renderer needs; an act needs
/// the reference the guest minted, the PSN behind it, and the name the
/// Finder knows an icon by. This looks those up in the scene the hit
/// came from and hands back an object a driver can actually address.
public enum ObjectResolver {

    /// The object under a point, or nil when the scene says there is
    /// nothing there at all — which is different from "the desktop",
    /// and only happens when the scene has no desktop backdrop to
    /// speak of.
    public static func object(at point: Point,
                              in scene: Scene) -> MirrorObject? {
        resolve(HitTester.hitTest(scene, x: point.x, y: point.y),
                in: scene)
    }

    /// The same, from a hit already taken. Kept separate so a caller
    /// that hit-tests for its own reasons (hover feedback, a drag's
    /// start point) does not pay for it twice.
    public static func resolve(_ target: HitTester.Target,
                               in scene: Scene) -> MirrorObject? {
        switch target {

        case .titlebar(let id, _, _, _):
            return window(id, part: .titleBar, in: scene)

        case .widget(let id, let kind, _, _):
            switch kind {
            case .close:    return window(id, part: .closeBox, in: scene)
            case .zoom:     return window(id, part: .zoomBox, in: scene)
            case .collapse: return window(id, part: .collapseBox, in: scene)
            }

        case .growBox(let id, _, _):
            return window(id, part: .growBox, in: scene)

        case .content(let id, _, _, _, _):
            return window(id, part: .content, in: scene)

        case .control(let id, let ctl):
            return control(ctl, in: id, part: nil, scene: scene)

        case .scrollbar(let id, let ctl, let part, _, _):
            return control(ctl, in: id, part: part, scene: scene)

        case .menuTitle(let index):
            return menu(index, in: scene).map(MirrorObject.menu)

        case .appMenu:
            /* Opening the switcher is mirror-local UI: nothing is sent
               to the guest until a row is chosen, and there is no
               object on the guest that IS the switcher. */
            return nil

        case .appMenuItem(let psn, let name):
            return .app(.init(psn: psn, name: name,
                              isFront: scene.apps.first { $0.psn == psn }?
                                  .front ?? false))

        case .desktopItem(let name, let x, let y):
            return .finderItem(.init(name: name, container: nil,
                                     point: Point(x: x, y: y)))

        case .windowItem(let id, let name, let x, let y):
            return .finderItem(.init(name: name,
                                     container: windowShape(id, part: .content,
                                                            in: scene),
                                     point: Point(x: x, y: y)))

        case .desktop:
            /* THE OBJECT THAT MAKES EMPTY SPACE ADDRESSABLE, and it
               carries WHOSE desktop it is. The owner is the process
               drawing the backdrop - the Finder - and naming it is what
               lets a click there do what a click on a Mac's desktop
               does: bring the Finder forward. */
            return .desktop(desktopOwner(in: scene))
        }
    }

    /// **What a keystroke happens to.**
    ///
    /// Typing is an interaction like any other and therefore needs a
    /// subject. On a Macintosh that subject is whatever the front
    /// application will route a key event to, and from out here the
    /// closest honest name for it is the front window - or, when the
    /// front application has none, the application itself.
    ///
    /// It resolves to `.desktop` only when nothing is running that could
    /// take a key, which on a live machine does not happen; the case
    /// exists so this function has no failure mode a caller must handle.
    public static func focus(in scene: Scene) -> MirrorObject {
        if let front = scene.windows.first(where: {
            $0.front && $0.visible && !HitTester.isDesktopBackdrop($0)
        }) {
            return .window(.init(id: front.id,
                                 ref: front.ref.flatMap { $0.isEmpty ? nil : $0 },
                                 psn: front.psn, title: front.title,
                                 rect: front.rect, kind: front.kind,
                                 isFront: true, part: .content))
        }
        if let app = scene.apps.first(where: { $0.front }) {
            return .app(.init(psn: app.psn, name: app.name, isFront: true))
        }
        return .desktop(desktopOwner(in: scene))
    }

    /// The row of an open menu, which no hit test produces because a
    /// drawn menu is the mirror's own overlay rather than anything in
    /// the scene. Resolved from the menu and the row a person is on.
    public static func menuItem(_ item: Scene.MenuItem,
                                in menu: Scene.Menu,
                                index: Int,
                                apps: [Scene.AppRef] = []) -> MirrorObject {
        /* The Application menu's lower half is not a list of commands.
           Each row IS a running process, and choosing one means "bring
           this application forward" - which the wire can say directly,
           by process serial number.
         *
           Sent as a menu command it did nothing: watched twice on
           2026-08-03, once as Hide Finder and once as choosing Finder
           from the list, both reporting a tick the machine never
           honoured. Whatever is wrong with commanding menu -16489, the
           application does not need that route, and taking it was the
           gesture-first mistake in miniature - addressing the ROW
           instead of the thing the row names.

           Matched by title, because that is what the menu shows and what
           the person read. A row that names nothing running stays a menu
           command; so do Hide / Hide Others / Show All, which name no
           process and for which there is no verb yet. */
        if menu.id == applicationMenuID, !item.separator,
           let app = apps.first(where: { $0.name == item.title }) {
            return .app(.init(psn: app.psn, name: app.name,
                              isFront: app.front))
        }
        return .menuItem(.init(menu: shape(menu), index: index,
                               title: item.title, cmd: item.cmd,
                               isEnabled: item.enabled,
                               isSeparator: item.separator))
    }

    /// The system's Application menu. Named once, here and in
    /// `HitTester`, because two spellings of a magic number is how the
    /// menu bar and the hit test drift apart.
    public static let applicationMenuID = -16489

    /// The process that owns the desktop backdrop, which is the Finder
    /// on every machine this has ever run on - found by asking which
    /// process draws the backdrop rather than by matching its name.
    static func desktopOwner(in scene: Scene) -> MirrorObject.App? {
        let psn = scene.windows.first(where: HitTester.isDesktopBackdrop)?.psn
        guard let psn,
              let app = scene.apps.first(where: { $0.psn == psn })
                  ?? scene.processes?.first(where: { $0.psn == psn })
                      .map({ Scene.AppRef(psn: $0.psn, name: $0.name,
                                          front: $0.front, error: nil) })
        else { return nil }
        return .init(psn: app.psn, name: app.name, isFront: app.front)
    }

    // MARK: - Lookups

    private static func window(_ id: String, part: MirrorObject.WindowPart,
                               in scene: Scene) -> MirrorObject? {
        windowShape(id, part: part, in: scene).map(MirrorObject.window)
    }

    private static func windowShape(_ id: String,
                                    part: MirrorObject.WindowPart,
                                    in scene: Scene) -> MirrorObject.Window? {
        guard let w = scene.windows.first(where: { $0.id == id }) else {
            return nil
        }
        return .init(id: w.id, ref: w.ref.flatMap { $0.isEmpty ? nil : $0 },
                     psn: w.psn, title: w.title, rect: w.rect,
                     kind: w.kind, isFront: w.front, part: part)
    }

    private static func control(_ ctl: Scene.Control, in windowID: String,
                                part: Scrollbar.Part?,
                                scene: Scene) -> MirrorObject? {
        guard let win = windowShape(windowID, part: .content, in: scene) else {
            return nil
        }
        return .control(.init(ref: ctl.ref, role: ctl.role, title: ctl.title,
                              rect: ctl.rect, value: ctl.value,
                              min: ctl.min, max: ctl.max,
                              isEnabled: ctl.enabled, window: win,
                              part: part))
    }

    private static func menu(_ index: Int,
                             in scene: Scene) -> MirrorObject.Menu? {
        guard let menus = scene.menubar?.menus,
              index >= 0, index < menus.count else { return nil }
        return shape(menus[index])
    }

    private static func shape(_ m: Scene.Menu) -> MirrorObject.Menu {
        .init(id: m.id, title: m.title, left: m.left, isApple: m.apple)
    }
}
