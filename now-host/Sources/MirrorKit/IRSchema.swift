import Foundation

/// The frozen shape of the scene IR — the ledger the parity gate compares
/// against, and the machinery that reads a shape off a live value.
///
/// Two independent enumerations, because each catches what the other misses:
///
/// - **`v1Frozen`** — wire key paths of the *encoded* scene (`windows[].rect.l`).
///   This is what a consumer actually sees, so it is the contract. It can only
///   observe a field that the probe scene populates.
/// - **`v1FrozenProperties`** — `Type.property` pairs read back off a live
///   value with `Mirror`, which lists `nil` optionals too. This one still sees
///   a newly-added field that the probe forgot to fill, which is exactly the
///   hole the wire-path list has.
///
/// ## Editing rules
///
/// `v1Frozen` and `v1FrozenProperties` are **final**. A new field goes in
/// `v1Additions` / `v1AdditionalProperties`, which keeps `IR.version` at 1 —
/// old consumers ignore keys they do not know, so that is not a break. A field
/// that must *leave* moves `IR.version`, and a diff that deletes a line from a
/// `Frozen` list without moving the version is the thing code review is for.
public enum IRSchema {

    // MARK: - The v1 freeze (2026-07-31) — final; do not edit

    /// Wire key paths of the encoded scene. `[]` marks an array level.
    public static let v1Frozen: Set<String> = [
        "capturedAt",
        "seq",
        "source",
        "version",

        "screen",
        "screen.h",
        "screen.w",

        "apps",
        "apps[].error",
        "apps[].front",
        "apps[].name",
        "apps[].psn",

        "processes",
        "processes[].front",
        "processes[].name",
        "processes[].psn",
        "processes[].signature",

        "menubar",
        "menubar.app",
        "menubar.menus",
        "menubar.menus[].apple",
        "menubar.menus[].id",
        "menubar.menus[].left",
        "menubar.menus[].title",
        "menubar.menus[].items",
        "menubar.menus[].items[].cmd",
        "menubar.menus[].items[].enabled",
        "menubar.menus[].items[].index",
        "menubar.menus[].items[].mark",
        "menubar.menus[].items[].separator",
        "menubar.menus[].items[].title",

        "windows",
        "windows[].app",
        "windows[].front",
        "windows[].id",
        "windows[].kind",
        "windows[].psn",
        "windows[].title",
        "windows[].visible",
        "windows[].z",
        "windows[].rect",
        "windows[].rect.b",
        "windows[].rect.l",
        "windows[].rect.r",
        "windows[].rect.t",
        "windows[].text",
        "windows[].text.active",
        "windows[].text.content",
        "windows[].controls",
        "windows[].controls[].checked",
        "windows[].controls[].enabled",
        "windows[].controls[].max",
        "windows[].controls[].min",
        "windows[].controls[].ref",
        "windows[].controls[].role",
        "windows[].controls[].title",
        "windows[].controls[].value",
        "windows[].controls[].visible",
        "windows[].controls[].rect",
        "windows[].controls[].rect.b",
        "windows[].controls[].rect.l",
        "windows[].controls[].rect.r",
        "windows[].controls[].rect.t",
        "windows[].display",
        "windows[].display[].dst",
        "windows[].display[].ext",
        "windows[].display[].face",
        "windows[].display[].font",
        "windows[].display[].from",
        "windows[].display[].kind",
        "windows[].display[].op",
        "windows[].display[].origin",
        "windows[].display[].pen",
        "windows[].display[].rect",
        "windows[].display[].rgb",
        "windows[].display[].size",
        "windows[].display[].src",
        "windows[].display[].text",
        "windows[].display[].ticks",
        "windows[].display[].to",
        "windows[].display[].verb",

        "desktopItems",
        "desktopItems[].alias",
        "desktopItems[].creator",
        "desktopItems[].invisible",
        "desktopItems[].kind",
        "desktopItems[].name",
        "desktopItems[].placed",
        "desktopItems[].type",
        "desktopItems[].x",
        "desktopItems[].y",

        "meta",
        "meta.bytes",
        "meta.errors",
        "meta.latencyMs",
        "meta.plane",
    ]

    /// Stored properties of the IR value types, `Type.property`. Includes the
    /// two shelves that are deliberately absent from the wire
    /// (`Scene.Window.island`, `Scene.Window.items`) — they are part of the
    /// frozen *declaration* precisely so that quietly re-adding either one to
    /// `CodingKeys` shows up as a wire-path change and not as nothing.
    public static let v1FrozenProperties: Set<String> = [
        "Scene.version", "Scene.seq", "Scene.source", "Scene.capturedAt",
        "Scene.screen", "Scene.apps", "Scene.processes", "Scene.menubar",
        "Scene.windows", "Scene.desktopItems", "Scene.meta",

        "Scene.ScreenSize.w", "Scene.ScreenSize.h",

        "Scene.AppRef.psn", "Scene.AppRef.name", "Scene.AppRef.front",
        "Scene.AppRef.error",

        "Scene.ProcessRef.psn", "Scene.ProcessRef.name",
        "Scene.ProcessRef.front", "Scene.ProcessRef.signature",

        "Scene.Menubar.app", "Scene.Menubar.menus",

        "Scene.Menu.title", "Scene.Menu.apple", "Scene.Menu.left",
        "Scene.Menu.id", "Scene.Menu.items",

        "Scene.MenuItem.title", "Scene.MenuItem.index",
        "Scene.MenuItem.separator", "Scene.MenuItem.enabled",
        "Scene.MenuItem.mark", "Scene.MenuItem.cmd",

        "Scene.Window.id", "Scene.Window.app", "Scene.Window.psn",
        "Scene.Window.title", "Scene.Window.kind", "Scene.Window.rect",
        "Scene.Window.front", "Scene.Window.z", "Scene.Window.visible",
        "Scene.Window.controls", "Scene.Window.text", "Scene.Window.items",
        "Scene.Window.display", "Scene.Window.island",

        "Scene.Control.ref", "Scene.Control.role", "Scene.Control.title",
        "Scene.Control.rect", "Scene.Control.enabled", "Scene.Control.visible",
        "Scene.Control.value", "Scene.Control.min", "Scene.Control.max",
        "Scene.Control.checked",

        "Scene.TextContent.content", "Scene.TextContent.active",

        "Scene.DesktopItem.name", "Scene.DesktopItem.kind",
        "Scene.DesktopItem.type", "Scene.DesktopItem.creator",
        "Scene.DesktopItem.x", "Scene.DesktopItem.y",
        "Scene.DesktopItem.placed", "Scene.DesktopItem.alias",
        "Scene.DesktopItem.invisible",

        "Scene.Meta.latencyMs", "Scene.Meta.bytes", "Scene.Meta.errors",
        "Scene.Meta.plane",

        "Rect.l", "Rect.t", "Rect.r", "Rect.b",

        "DisplayOp.op", "DisplayOp.ticks", "DisplayOp.text", "DisplayOp.pen",
        "DisplayOp.font", "DisplayOp.size", "DisplayOp.face", "DisplayOp.verb",
        "DisplayOp.rect", "DisplayOp.ext", "DisplayOp.from", "DisplayOp.to",
        "DisplayOp.kind", "DisplayOp.origin", "DisplayOp.rgb", "DisplayOp.src",
        "DisplayOp.dst",

        "PixelIsland.width", "PixelIsland.height", "PixelIsland.rgba",
        "PixelIsland.originX", "PixelIsland.originY", "PixelIsland.scale",
    ]

    // MARK: - Additive extensions to v1 — append here, never delete

    /// Wire paths added after the freeze. Additive within v1: `IR.version`
    /// stays 1, because a consumer that has never heard of the key ignores it.
    public static let v1Additions: Set<String> = [
        // Lane H2, 2026-07-31. `windows[].items` was deliberately held out of
        // the freeze because its values were known wrong: the only source then
        // was `fdLocation`, the saved icon grid, not where the Finder had
        // actually laid the icons out. It re-enters now that the positions are
        // the Finder's own live `position of` — measured by clicking a
        // computed point and being told the right file was selected. The
        // element shape is `DesktopItem`, already frozen for the desktop.
        "windows[].items",
        "windows[].items[].alias",
        "windows[].items[].creator",
        "windows[].items[].invisible",
        "windows[].items[].kind",
        "windows[].items[].name",
        "windows[].items[].placed",
        "windows[].items[].type",
        "windows[].items[].x",
        "windows[].items[].y",
    ]

    /// Declared properties added after the freeze (wire-bearing or not).
    public static let v1AdditionalProperties: Set<String> = []

    // MARK: - What the gate compares against

    /// The wire shape this build promises for `major`, or nil if it makes no
    /// promise about that major (which is itself the answer a gate wants).
    public static func expectedWirePaths(major: Int) -> Set<String>? {
        guard major == 1 else { return nil }
        return v1Frozen.union(v1Additions)
    }

    public static func expectedProperties(major: Int) -> Set<String>? {
        guard major == 1 else { return nil }
        return v1FrozenProperties.union(v1AdditionalProperties)
    }

    // MARK: - Reading a shape off a value

    /// Key paths of an encoded JSON payload. Arrays collapse to one `[]` level
    /// and the union of their elements' paths, so a heterogeneous array (which
    /// the IR does not have) would show every variant rather than the first.
    public static func wirePaths(ofEncoded data: Data) throws -> Set<String> {
        wirePaths(of: try JSONSerialization.jsonObject(with: data), prefix: "")
    }

    static func wirePaths(of value: Any, prefix: String) -> Set<String> {
        var out: Set<String> = []
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                out.insert(path)
                out.formUnion(wirePaths(of: child, prefix: path))
            }
        } else if let list = value as? [Any] {
            for child in list {
                out.formUnion(wirePaths(of: child, prefix: prefix + "[]"))
            }
        }
        return out
    }

    /// `Type.property` pairs reachable from a value, via `Mirror`. Unlike the
    /// wire walk this sees `nil` optionals (the label is there even when the
    /// value is not), so it catches a field added but never populated.
    ///
    /// Recursion stops at leaves; a `nil` optional is a leaf by necessity —
    /// there is no instance to reflect — which is why the probe value should
    /// still populate everything it can.
    public static func declaredProperties(of value: Any) -> Set<String> {
        var out: Set<String> = []
        collect(value, into: &out)
        return out
    }

    private static let leafTypes: Set<String> = [
        "Swift.String", "Swift.Int", "Swift.Double", "Swift.Bool",
        "Foundation.Data", "Foundation.Date",
    ]

    private static func collect(_ value: Any, into out: inout Set<String>) {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            if let wrapped = mirror.children.first?.value {
                collect(wrapped, into: &out)
            }
        case .collection, .set, .tuple:
            for child in mirror.children { collect(child.value, into: &out) }
        case .struct, .class:
            let name = typeName(of: value)
            guard !leafTypes.contains(name) else { return }
            let short = name.hasPrefix("MirrorKit.")
                ? String(name.dropFirst("MirrorKit.".count)) : name
            for child in mirror.children {
                guard let label = child.label else { continue }
                out.insert("\(short).\(label)")
                collect(child.value, into: &out)
            }
        default:
            return
        }
    }

    private static func typeName(of value: Any) -> String {
        String(reflecting: type(of: value))
    }
}
