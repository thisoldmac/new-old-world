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
            /* THE OBJECT THAT MAKES EMPTY SPACE ADDRESSABLE. A click here
               used to become a coordinate and then a refusal; as an
               object it is the Finder's desktop, which the Finder will
               talk about by name. */
            return .desktop
        }
    }

    /// The row of an open menu, which no hit test produces because a
    /// drawn menu is the mirror's own overlay rather than anything in
    /// the scene. Resolved from the menu and the row a person is on.
    public static func menuItem(_ item: Scene.MenuItem,
                                in menu: Scene.Menu,
                                index: Int) -> MirrorObject {
        .menuItem(.init(menu: shape(menu), index: index,
                        title: item.title, cmd: item.cmd,
                        isEnabled: item.enabled,
                        isSeparator: item.separator))
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
