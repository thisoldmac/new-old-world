import Foundation

/// **Added by the NOW port, not carried from upstream. One public door per
/// scene type, and nothing else.**
///
/// Upstream built every `Scene` *inside* this module — `SceneBuilder`,
/// `ScenePoller`, the fixture decoder — so Swift's synthesized memberwise
/// initializers, which are **internal**, were enough and none of these types
/// ever declared a public one. NOW's seam is outside the module:
/// `MirrorSceneAdapter` lives in the `Host` target and turns a
/// `NOWSceneDocument` into one of these. Without a public entry point it
/// cannot construct a single one of them, and the fold-in stops at the
/// package boundary.
///
/// **Why `make` and not `public init`.** Declaring a public initializer with
/// the memberwise signature is an *invalid redeclaration* of the synthesized
/// one; declaring it in the type body instead would suppress the synthesized
/// initializer for the whole module and rewrite the port's construction sites
/// as a side effect of exporting it. A static factory has neither problem:
/// in-module code keeps using the memberwise initializer it always did, this
/// file is additive, and `Scene.swift`'s diff stays a port's diff.
///
/// Every function here does exactly one thing — call the memberwise
/// initializer. The `…Present` flags default to `true` for the same reason
/// they do at their declarations: a scene built in memory reports what it
/// holds, and only a decoder that saw no key, or an adapter told a plane was
/// absent, says otherwise.
extension Scene {
    public static func make(version: Int,
                            seq: Int,
                            source: String,
                            capturedAt: Double,
                            screen: ScreenSize,
                            apps: [AppRef],
                            appsPresent: Bool = true,
                            processes: [ProcessRef]? = nil,
                            menubar: Menubar? = nil,
                            windows: [Window],
                            windowsPresent: Bool = true,
                            desktopItems: [DesktopItem]? = nil,
                            meta: Meta) -> Scene {
        Scene(version: version, seq: seq, source: source,
              capturedAt: capturedAt, screen: screen, apps: apps,
              appsPresent: appsPresent, processes: processes,
              menubar: menubar, windows: windows,
              windowsPresent: windowsPresent, desktopItems: desktopItems,
              meta: meta)
    }
}

extension Scene.AppRef {
    public static func make(psn: String, name: String, front: Bool,
                            error: String? = nil) -> Scene.AppRef {
        Scene.AppRef(psn: psn, name: name, front: front, error: error)
    }
}

extension Scene.ProcessRef {
    public static func make(psn: String, name: String, front: Bool,
                            signature: String) -> Scene.ProcessRef {
        Scene.ProcessRef(psn: psn, name: name, front: front,
                         signature: signature)
    }
}

extension Scene.Menubar {
    public static func make(app: String, menus: [Scene.Menu],
                            menusPresent: Bool = true) -> Scene.Menubar {
        Scene.Menubar(app: app, menus: menus, menusPresent: menusPresent)
    }
}

extension Scene.Menu {
    public static func make(title: String, apple: Bool, left: Int, id: Int,
                            items: [Scene.MenuItem],
                            itemsPresent: Bool = true) -> Scene.Menu {
        Scene.Menu(title: title, apple: apple, left: left, id: id,
                   items: items, itemsPresent: itemsPresent)
    }
}

extension Scene.MenuItem {
    public static func make(title: String, index: Int, separator: Bool,
                            enabled: Bool, mark: Bool,
                            cmd: String) -> Scene.MenuItem {
        Scene.MenuItem(title: title, index: index, separator: separator,
                       enabled: enabled, mark: mark, cmd: cmd)
    }
}

extension Scene.Window {
    public static func make(id: String, app: String, psn: String,
                            title: String, kind: Int? = nil, rect: Rect,
                            front: Bool, z: Int, visible: Bool,
                            controls: [Scene.Control],
                            controlsPresent: Bool = true,
                            text: Scene.TextContent? = nil,
                            items: [Scene.DesktopItem]? = nil,
                            display: [DisplayOp]? = nil,
                            island: PixelIsland? = nil) -> Scene.Window {
        Scene.Window(id: id, app: app, psn: psn, title: title, kind: kind,
                     rect: rect, front: front, z: z, visible: visible,
                     controls: controls, controlsPresent: controlsPresent,
                     text: text, items: items, display: display,
                     island: island)
    }
}

extension Scene.Control {
    public static func make(ref: String, role: String, title: String,
                            rect: Rect? = nil, enabled: Bool, visible: Bool,
                            value: Int? = nil, min: Int? = nil,
                            max: Int? = nil,
                            checked: Bool) -> Scene.Control {
        Scene.Control(ref: ref, role: role, title: title, rect: rect,
                      enabled: enabled, visible: visible, value: value,
                      min: min, max: max, checked: checked)
    }
}

extension Scene.TextContent {
    public static func make(content: String,
                            active: Bool) -> Scene.TextContent {
        Scene.TextContent(content: content, active: active)
    }
}

extension Scene.DesktopItem {
    public static func make(name: String, kind: String, type: String? = nil,
                            creator: String? = nil, x: Int, y: Int,
                            placed: Bool, alias: Bool,
                            invisible: Bool) -> Scene.DesktopItem {
        Scene.DesktopItem(name: name, kind: kind, type: type,
                          creator: creator, x: x, y: y, placed: placed,
                          alias: alias, invisible: invisible)
    }
}

extension Scene.Meta {
    public static func make(latencyMs: Double? = nil, bytes: Int? = nil,
                            errors: [String], errorsPresent: Bool = true,
                            plane: String? = nil) -> Scene.Meta {
        Scene.Meta(latencyMs: latencyMs, bytes: bytes, errors: errors,
                   errorsPresent: errorsPresent, plane: plane)
    }
}
