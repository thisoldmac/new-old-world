import Foundation
import MirrorKit
import NOWAgentIntegration

/// The seam between NOW's scene document and MirrorKit's scene.
///
/// Two Swift models describe one IR. `NOWSceneDocument` is what this host
/// decodes off the wire — every plane a partial producer may omit is
/// `Optional`, because that is how it remembers absence. `MirrorKit.Scene` is
/// what the renderer, the hit tester and the action model read — every plane
/// is an array beside a `…Present` flag, because those consumers cannot read
/// an optional array. This is the one place the first becomes the second.
///
/// ## The rule this file exists to keep
///
/// A plane has **three** states, and they must all survive the crossing:
///
/// | NOW document | MirrorKit scene | means |
/// |---|---|---|
/// | key absent (`nil`) | `([], present: false)` | this producer does not report it |
/// | `[]` | `([], present: true)` | walked, found none |
/// | populated | `(rows, present: true)` | here they are |
///
/// `?? []` is therefore **the bug**, not the shortcut: it launders *"nobody
/// looked"* into *"looked, found none"*, and a person reading a window with no
/// controls cannot tell a plain dialog from an unarmed walk. Every plane below
/// goes through `plane(_:)`, which returns both halves and makes forgetting
/// the flag a compile error rather than a quiet downgrade.
///
/// ## What this adapter invents, and what it refuses to
///
/// NOW's producer is poorer than the one MirrorKit was written against
/// (`now-guest-ppc/src/scene/scene_json.c`), so some fields MirrorKit requires
/// simply never arrive. Where a value is structurally required, this file
/// supplies a **neutral** one and says so at the site; where a value would be
/// a *claim about the machine*, it supplies the falsy one rather than a guess:
///
/// - `menus[].apple` — the guest deliberately never emits it (it has no
///   evidence which menu is the Apple menu). `false` here is "not asserted",
///   not "asserted to be an ordinary menu".
/// - `controls[].ref` — the actuation handle. NOW's walk reads a ControlRecord
///   and cannot name a ref, so it is `""`: MirrorKit's own vocabulary for a
///   control that cannot be acted on. Inventing one would produce a control
///   that looks actuatable and is not.
/// - `controls[].role` — inferred, not invented. NOW's walk reads a
///   ControlRecord, not its defProc, so it never learns "this is a
///   scrollbar" the way Mirror's own AX walk does; but the ControlRecord DOES
///   carry the one thing a scrollbar cannot hide — its shape and its edge —
///   and `inferredRole` reads exactly that (`Scrollbar.swift` is the same
///   test one layer later, for whether a bar built this way is *live*). A
///   control that does not look like a bar on an edge keeps the honest
///   default, `"control"`.
/// - `controls[].rect` — **crossed into content-local**, not passed through.
///   `ControlRecord.contrlRect` is in the window's own port coordinates,
///   which for an ordinary (non-scrolled) window are the SAME coordinates as
///   the screen — so NOW's wire carries control rects in global screen
///   space, while every consumer on this side (`HitTester`, `FinderItems`,
///   `Scrollbar`, `SceneRenderer`) was written against Mirror's convention:
///   content-local, origin at the window's own content top-left
///   (`win.rect.l`, `win.rect.t + titleBarHeight`). Left uncrossed, a
///   control's rect would be added to that origin a second time downstream
///   and land outside the window entirely — verified against this file's own
///   real capture, where the vertical and horizontal scrollbars' raw rects
///   only meet at the window's corner (the classic Mac grow-box seam) once
///   read as global; translated to content-local they instead land exactly
///   inside `FinderItems.iconArea`'s content box, margins and all.
/// - `screen` — absent means the renderer has no canvas size. Rather than
///   inventing 512×342, this passes `0×0` through, which
///   `MirrorSceneAdapter.hasScreen` names and the pane reads as "the scene did
///   not say", never as a rendering failure.
/// - `desktopItems[].{x,y}` for `kind == "disk"` — the ONE field this file
///   computes rather than crosses. NOW's guest never places a volume
///   (`scene_desktop.c` states why: where the Finder draws one lives in its
///   own desktop database, not any File Manager fact) and always sends
///   `placed:false` for one, so this adapter runs exactly that subset through
///   `SceneGeometry.placeVolumes` — upstream's own top-right/stacked-down
///   default, ported verbatim — using the scene's own screen size. Every
///   other kind, and a disk the guest ever DOES report placed, passes
///   through untouched: a real position always wins over this fallback.
enum MirrorSceneAdapter {

    /// Turn a decoded NOW scene document into the scene MirrorKit renders.
    static func scene(from doc: NOWSceneDocument) -> MirrorKit.Scene {
        let apps = plane(doc.apps) { app in
            MirrorKit.Scene.AppRef.make(psn: app.psn, name: app.name,
                                        front: app.front, error: app.error)
        }
        let windows = plane(doc.windows, window(from:))
        let screen = doc.screen.map {
            MirrorKit.Scene.ScreenSize(w: $0.w, h: $0.h)
        } ?? MirrorKit.Scene.ScreenSize(w: 0, h: 0)
        return MirrorKit.Scene.make(
            version: doc.version,
            // Neutral scalars for a producer that did not stamp them. `seq`
            // and `capturedAt` are ordering aids, not content: a consumer
            // that sees 0 has been told nothing, which is what happened.
            seq: doc.seq ?? 0,
            source: doc.source ?? "",
            capturedAt: doc.capturedAt ?? 0,
            screen: screen,
            apps: apps.value,
            appsPresent: apps.present,
            // `processes` is Optional on BOTH sides, so it crosses
            // unchanged — the three states are already spelled the same
            // way and nothing needs flattening. `desktopItems` is too, but
            // it is not a straight crossing (see desktopItems(from:screen:)).
            processes: doc.processes?.map {
                MirrorKit.Scene.ProcessRef.make(
                    psn: $0.psn, name: $0.name, front: $0.front,
                    signature: $0.signature ?? "")
            },
            menubar: doc.menubar.map(menubar(from:)),
            windows: windows.value,
            windowsPresent: windows.present,
            desktopItems: desktopItems(from: doc.desktopItems, screen: screen),
            meta: meta(from: doc.meta))
    }

    /// Crosses `desktopItems`, placing only the volumes.
    ///
    /// Absence and emptiness cross unflattened like `processes` — `nil` stays
    /// `nil`, `[]` stays `[]` — because both sides already spell the three
    /// states the same way (Optional array, nothing more). What is NOT a
    /// straight crossing is position: a `kind == "disk"` row the guest sent
    /// `placed:false` gets a computed one here, because NOW's guest never
    /// has a real one to send (see this file's header). Splitting by `kind`
    /// rather than running every row through `placeVolumes` matters — a
    /// Desktop Folder item legitimately unplaced (fdLocation {0,0}, the
    /// Finder has not laid it out) is not a disk, and stacking it top-right
    /// would be exactly the invented position this adapter otherwise
    /// refuses to produce.
    private static func desktopItems(
        from items: [NOWSceneDocument.DesktopItem]?,
        screen: MirrorKit.Scene.ScreenSize
    ) -> [MirrorKit.Scene.DesktopItem]? {
        guard let items else { return nil }
        let mapped = items.map(item(from:))
        let volumes = mapped.filter { $0.kind == "disk" }
        let rest = mapped.filter { $0.kind != "disk" }
        return rest + SceneGeometry.placeVolumes(volumes, screen: screen)
    }

    /// True when the document reported a screen size at all. The pane asks,
    /// because a 0×0 canvas is not a scene the renderer can draw and is also
    /// not a fault — it is a producer that did not say.
    static func hasScreen(_ scene: MirrorKit.Scene) -> Bool {
        scene.screen.w > 0 && scene.screen.h > 0
    }

    // MARK: - the three-state primitive

    /// The whole rule, in one function: an absent list is empty **and**
    /// not-present; a present list keeps its own count.
    ///
    /// It returns a tuple rather than an array on purpose. `plane(x).value`
    /// alone does not compile into a `Scene`'s flag, so a caller that drops
    /// the presence bit has to do it deliberately.
    private static func plane<In, Out>(
        _ rows: [In]?, _ transform: (In) -> Out
    ) -> (value: [Out], present: Bool) {
        guard let rows else { return ([], false) }
        return (rows.map(transform), true)
    }

    // MARK: - per-plane crossings

    private static func menubar(
        from bar: NOWSceneDocument.Menubar
    ) -> MirrorKit.Scene.Menubar {
        let menus = plane(bar.menus, menu(from:))
        return MirrorKit.Scene.Menubar.make(
            // A menubar with no `app` is a bar whose owner did not name
            // itself; "" is the renderer's own empty title.
            app: bar.app ?? "",
            menus: menus.value,
            menusPresent: menus.present)
    }

    private static func menu(
        from menu: NOWSceneDocument.Menu
    ) -> MirrorKit.Scene.Menu {
        let items = plane(menu.items, item(from:))
        return MirrorKit.Scene.Menu.make(
            title: menu.title ?? "",
            // Never asserted by this producer — see the header.
            apple: menu.apple ?? false,
            left: menu.left ?? 0,
            id: menu.id ?? 0,
            items: items.value,
            itemsPresent: items.present)
    }

    private static func item(
        from item: NOWSceneDocument.MenuItem
    ) -> MirrorKit.Scene.MenuItem {
        MirrorKit.Scene.MenuItem.make(
            title: item.title ?? "",
            index: item.index ?? 0,
            separator: item.separator ?? false,
            // An item that did not say whether it is enabled is drawn
            // enabled: that is what the Menu Manager's own default is, and
            // greying a live item is the more misleading of the two errors.
            enabled: item.enabled ?? true,
            mark: item.mark ?? false,
            // Absent `cmd` means "no command key" (the guest omits the key
            // rather than sending ""), which is the same thing "" means to
            // the renderer.
            cmd: item.cmd ?? "")
    }

    private static func window(
        from window: NOWSceneDocument.Window
    ) -> MirrorKit.Scene.Window {
        // The one place a control's rect meets the window it belongs to —
        // needed to cross it from NOW's global wire into MirrorKit's
        // content-local convention (see this file's header) and to read the
        // shape/edge test `inferredRole` needs. Both use the SAME origin and
        // content size `FinderItems.contentOrigin`/`iconArea` do, so a
        // control placed here lands exactly where those already look.
        let contentOrigin = (x: window.rect.l,
                             y: window.rect.t + SceneBuilder.titleBarHeight)
        let contentSize = (w: window.rect.r - window.rect.l,
                           h: window.rect.b - contentOrigin.y)
        let controls = plane(window.controls) {
            control(from: $0, contentOrigin: contentOrigin,
                   contentSize: contentSize)
        }
        return MirrorKit.Scene.Window.make(
            id: window.id,
            app: window.app,
            psn: window.psn,
            title: window.title,
            kind: window.kind,
            rect: rect(from: window.rect),
            front: window.front,
            z: window.z,
            visible: window.visible,
            controls: controls.value,
            controlsPresent: controls.present,
            text: window.text.map {
                MirrorKit.Scene.TextContent.make(
                    content: $0.content ?? "", active: $0.active ?? false)
            },
            items: window.items?.map(item(from:)),
            // The scene DOCUMENT carries no display plane, and that is all
            // `nil` claims here.
            //
            // It used to claim more: "NOW models no display plane at all",
            // which was false when it was written and is the reason window
            // interiors never drew. NOW does model one — `qdtrace`
            // (`now-guest-ppc/src/content/`) emits a QuickDraw op stream —
            // but it is a separate COMMAND on the control lane, not a key on
            // the scene, because a drain is a bounded control answer and a
            // scene is a transfer (`qdtrace.h`). So it cannot arrive through
            // this function: this one turns one document into one scene and
            // has no wire.
            //
            // `MirrorContentJoin` is where the two meet, after the scene
            // lands. `nil` here means "the document carried none", which the
            // renderer's empty content rect is for; the join replaces it when
            // a drain answers.
            display: nil)
    }

    private static func control(
        from control: NOWSceneDocument.Control,
        contentOrigin: (x: Int, y: Int),
        contentSize: (w: Int, h: Int)
    ) -> MirrorKit.Scene.Control {
        // Cross the rect FIRST: role inference and every downstream
        // consumer read the content-local rect, never the wire's global one.
        let local = control.rect.map(rect(from:)).map {
            Rect(l: $0.l - contentOrigin.x, t: $0.t - contentOrigin.y,
                r: $0.r - contentOrigin.x, b: $0.b - contentOrigin.y)
        }
        return MirrorKit.Scene.Control.make(
            ref: control.ref ?? "",
            role: control.role
                ?? inferredRole(rect: local, min: control.min,
                                max: control.max, contentSize: contentSize)
                ?? "control",
            title: control.title ?? "",
            rect: local,
            enabled: control.enabled ?? true,
            // A control that did not say is drawn: a window's control list
            // is what the walk saw on screen.
            visible: control.visible ?? true,
            value: control.value,
            min: control.min,
            max: control.max,
            // Never reported by NOW's walk (it cannot read a defProc), so
            // this is "not asserted" rather than "asserted unchecked".
            checked: control.checked ?? false)
    }

    /// NOW's walk cannot read a defProc, so it never learns "scrollbar" the
    /// way Mirror's AX walk does — but a scrollbar cannot hide its shape: long,
    /// thin (`SceneRenderer`'s own unranged-scrollbar fallback uses the same
    /// 3:1, ≤20px-narrow test) and run along the window's own far edge. A
    /// control that carries a range but is shaped like anything else (the
    /// 16×16 square control in this file's own real capture, min:0/max:1) is
    /// left at the honest default rather than guessed into a bar.
    ///
    /// `min <= max` only, not `min < max`: a scrollbar whose content happens
    /// to fit reports a degenerate range (`Scrollbar.swift`'s own "reports
    /// value/min/max = 0/0/0" case) and is still a scrollbar — just not a
    /// LIVE one, which `Scrollbar.isLive`'s stricter `max > min` is for.
    /// Calling it "control" here would hide that distinction from every
    /// consumer that asks `role == "scrollbar"` before asking `isLive`.
    private static func inferredRole(
        rect: Rect?, min: Int?, max: Int?, contentSize: (w: Int, h: Int)
    ) -> String? {
        guard let r = rect, let min, let max, max >= min else { return nil }
        let w = r.r - r.l, h = r.b - r.t
        guard w > 0, h > 0 else { return nil }
        let narrow = Swift.min(w, h), long = Swift.max(w, h)
        guard narrow <= 20, long >= narrow * 3 else { return nil }
        // Edge strip: the bar's far side sits within one thumb-width of the
        // window's own content edge — a vertical bar hugs the right side, a
        // horizontal bar hugs the bottom, exactly where the Control Manager
        // places one.
        let onEdge = h > w
            ? r.r >= contentSize.w - narrow - 4
            : r.b >= contentSize.h - narrow - 4
        return onEdge ? "scrollbar" : nil
    }

    private static func item(
        from item: NOWSceneDocument.DesktopItem
    ) -> MirrorKit.Scene.DesktopItem {
        MirrorKit.Scene.DesktopItem.make(
            name: item.name ?? "",
            kind: item.kind ?? "file",
            type: item.type,
            creator: item.creator,
            x: item.x ?? 0,
            y: item.y ?? 0,
            placed: item.placed ?? false,
            alias: item.alias ?? false,
            invisible: item.invisible ?? false)
    }

    /// `meta` absent and `meta.errors` absent are the same claim to a
    /// consumer — nobody reported what went wrong — and both land on
    /// `errorsPresent: false`. What must NOT happen is either becoming an
    /// empty `errors` that reads as "the walk finished and found nothing
    /// wrong", which is a clean bill of health nobody issued.
    private static func meta(
        from meta: NOWSceneDocument.Meta?
    ) -> MirrorKit.Scene.Meta {
        guard let meta else {
            return MirrorKit.Scene.Meta.make(errors: [], errorsPresent: false)
        }
        let errors = plane(meta.errors) { $0 }
        return MirrorKit.Scene.Meta.make(latencyMs: meta.latencyMs,
                                         bytes: meta.bytes,
                                         errors: errors.value,
                                         errorsPresent: errors.present,
                                         plane: meta.plane)
    }

    private static func rect(from rect: NOWSceneRect) -> Rect {
        Rect(l: rect.l, t: rect.t, r: rect.r, b: rect.b)
    }
}
