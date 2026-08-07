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
        /* The box the Finder DREW. Absent from a producer that
           asked only for a position, which is why both are
           optional; see FinderItems on the list view. */
        "desktopItems[].w",
        "desktopItems[].h",

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
        "Scene.DesktopItem.w", "Scene.DesktopItem.h",
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
        // 2026-08-02. `windows[].ref` was never held out on purpose - the
        // producer emits it, the frozen list simply never named it, so the
        // decoder dropped it silently and every window act was unreachable.
        // Additive: a consumer that has not heard of it is where we already
        // were.
        "windows[].ref",

        // 2026-08-03. The window record's own address, and the only exact
        // join key between a scene and the machine it describes. Titles
        // collide, modal alerts have none, and `id` moves when the title or
        // the stacking does - so a structural differ keyed on any of them
        // mis-joins, and a mis-join reads exactly like a mismatch. Absent
        // when the producer could not say.
        "windows[].addr",

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
        "windows[].items[].w",
        "windows[].items[].h",

        /* 2026-08-07. WHERE a position came from — `drawn`, `saved` or
           `unknown`. Optional, and absent means the producer did not say,
           which reads as untrustworthy.

           It is on the wire because `placed` was three provenances wearing
           one boolean: set from the box the Finder drew, from the saved
           `fdLocation` grid, and from a layout rule the HOST invented for
           volumes. A consumer that must decide whether it may return an
           item to a position was being told "yes, we know where this is"
           by the one producer that had made the answer up. */
        "desktopItems[].origin",
        "windows[].items[].origin",
    ]

    /// Declared properties added after the freeze (wire-bearing or not).
    public static let v1AdditionalProperties: Set<String> = [
        // 2026-08-03. See windows[].addr in v1Additions: the exact join key
        // a structural differ needs, carried for harnesses rather than for
        // rendering.
        "Scene.Window.addr",

        "Scene.Window.ref",

        /* 2026-08-06. The guest's own account of a text run's length.
           These ride the wire already — the resident has emitted `len`,
           `fullLen` and `trunc` on every text record since QDPeek
           shipped — and it was the HOST that dropped them, so a
           truncation the guest declared became a silent one at the
           glass (R2 of the fidelity sweep). Additive in the ordinary
           sense: nothing changes shape, and a reader that has never
           heard of them is exactly as correct as it was yesterday. */
        "DisplayOp.len", "DisplayOp.fullLen", "DisplayOp.trunc",

        /* 2026-08-07. See desktopItems[].origin in v1Additions. */
        "Scene.DesktopItem.origin",
    ]

    // MARK: - IR v2 semantic evidence

    public static let v2Additions: Set<String> = [
        /* 2026-08-07. The process's own `modeOnlyBackground` declaration:
           it has no user interface by design, so having no windows is its
           normal state rather than an unobserved one. Additive, and
           deliberately three-valued on this side — absent means the
           producer did not say, which is NOT a claim that the process has
           a face. It replaces an inference from window counts that could
           not tell a faceless process from an application with nothing
           open, and an `ax_oracle_not_found` that was an error word for a
           normal condition. */
        "apps[].backgroundOnly",
        "processes[].backgroundOnly",

        "apps[].incarnation",
        "processes[].incarnation",
        "windows[].incarnation",
        "meta.coverage",
        "meta.coverage[].scope",
        "meta.coverage[].owner",
        "meta.coverage[].status",
        "meta.coverage[].reason",
        "windows[].controls[].semantic",
        "windows[].controls[].semantic.knowledge",
        "windows[].controls[].semantic.kind",
        "windows[].controls[].semantic.definition",
        "windows[].controls[].semantic.action",
        "windows[].controls[].semantic.state",
        /* 2026-08-07. See Scene.DesktopItem.aliasTarget below: the target
           an alias resolves to, on both the desktop's items and a
           window's, because a container's items are the same shape. */
        "desktopItems[].aliasTarget",
        "desktopItems[].aliasTarget.name",
        "desktopItems[].aliasTarget.kind",
        "desktopItems[].aliasTarget.type",
        "desktopItems[].aliasTarget.creator",
        "windows[].items[].aliasTarget",
        "windows[].items[].aliasTarget.name",
        "windows[].items[].aliasTarget.kind",
        "windows[].items[].aliasTarget.type",
        "windows[].items[].aliasTarget.creator",
        "windows[].controls[].semantic.value",
        "windows[].controls[].semantic.listCells",
        "windows[].controls[].semantic.listCells[].row",
        "windows[].controls[].semantic.listCells[].column",
        "windows[].controls[].semantic.listCells[].text",
        "windows[].controls[].semantic.listCells[].selected",
        "windows[].controls[].semantic.listTotalCount",
        "windows[].controls[].semantic.selection",
        "windows[].controls[].semantic.selection.start",
        "windows[].controls[].semantic.selection.end",
        "windows[].controls[].semantic.focused",
        "windows[].controls[].semantic.isDefault",
        "windows[].controls[].semantic.provenance",
        "windows[].controls[].semantic.completeness",
        "windows[].dialogItems",
        "windows[].dialogItems[].number",
        "windows[].dialogItems[].title",
        "windows[].dialogItems[].rect",
        "windows[].dialogItems[].rect.l",
        "windows[].dialogItems[].rect.t",
        "windows[].dialogItems[].rect.r",
        "windows[].dialogItems[].rect.b",
        "windows[].dialogItems[].enabled",
        "windows[].dialogItems[].visible",
        "windows[].dialogItems[].ref",
        "windows[].dialogItems[].semantic",
        "windows[].dialogItems[].semantic.knowledge",
        "windows[].dialogItems[].semantic.kind",
        "windows[].dialogItems[].semantic.definition",
        "windows[].dialogItems[].semantic.action",
        "windows[].dialogItems[].semantic.state",
        "windows[].dialogItems[].semantic.value",
        "windows[].dialogItems[].semantic.selection",
        "windows[].dialogItems[].semantic.selection.start",
        "windows[].dialogItems[].semantic.selection.end",
        "windows[].dialogItems[].semantic.focused",
        "windows[].dialogItems[].semantic.isDefault",
        "windows[].dialogItems[].semantic.provenance",
        "windows[].dialogItems[].semantic.completeness",

        /* 2026-08-07. What colour the machine draws with, read from the
           live Appearance Manager rather than assumed by the renderer.
           Additive: a reader that has never heard of it falls back to the
           constants it was already using, which is exactly as correct as
           yesterday - and no more, which was the problem. An absent KEY
           means the guest asked and the brush refused; an absent `theme`
           means the producer did not ask. */
        "meta.theme",
        "meta.theme.dialogBackground",
        "meta.theme.alertBackground",
        "meta.theme.documentBackground",
        "meta.theme.highlight",
        "meta.theme.depth",

        /* 2026-08-07. What a bounded ledger had to forget. Carried only
           by the `depth` claim, and only when nonzero. Additive; a reader
           that has never heard of it reads the claim exactly as before,
           which was the problem: `partial` said the order was incomplete
           and could not say that a named process's rank was LOST rather
           than never taken. */
        /* 2026-08-07. What the desktop is drawn from, asked of the running
           machine. Additive: a reader that has never heard of it keeps
           reading the asset pack's manifest, which is exactly as correct
           as yesterday — and the point is that nothing could tell you
           whether that was correct at all. An absent `meta.desktop` means
           the producer did not ask, and is the only state in which the
           pack may stand in; `source: unknown` means we asked and the
           machine would not say. */
        "meta.desktop",
        "meta.desktop.source",
        "meta.desktop.hasPattern",
        "meta.desktop.hasPicture",
        "meta.desktop.patternBytes",
        "meta.desktop.patternName",
        "meta.desktop.pictureName",

        "meta.coverage[].evicted",
    ]

    public static let v2AdditionalProperties: Set<String> = [
        // See meta.theme in v2Additions.
        "Scene.Meta.theme",
        "Scene.Theme.dialogBackground", "Scene.Theme.alertBackground",
        "Scene.Theme.documentBackground", "Scene.Theme.highlight",
        "Scene.Theme.depth",

        // See meta.desktop in v2Additions.
        "Scene.Meta.desktop",
        "Scene.Desktop.source",
        "Scene.Desktop.hasPattern", "Scene.Desktop.hasPicture",
        "Scene.Desktop.patternBytes",
        "Scene.Desktop.patternName", "Scene.Desktop.pictureName",

        // See apps[].backgroundOnly in v2Additions.
        "Scene.AppRef.backgroundOnly",
        "Scene.ProcessRef.backgroundOnly",

        "Scene.AppRef.incarnation",
        "Scene.ProcessRef.incarnation",
        "Scene.Window.incarnation",
        "Scene.Meta.coverage",
        "Scene.CoverageClaim.scope", "Scene.CoverageClaim.owner",
        "Scene.CoverageClaim.status", "Scene.CoverageClaim.reason",
        "Scene.CoverageClaim.evicted",
        "Scene.Window.dialogItems",
        "Scene.Control.semantic",
        "Scene.DialogItem.number", "Scene.DialogItem.title",
        "Scene.DialogItem.rect", "Scene.DialogItem.enabled",
        "Scene.DialogItem.visible", "Scene.DialogItem.ref",
        "Scene.DialogItem.semantic",
        "Scene.Semantics.knowledge", "Scene.Semantics.kind",
        "Scene.Semantics.definition",
        "Scene.Semantics.action", "Scene.Semantics.state",
        "Scene.Semantics.value", "Scene.Semantics.selection",
        "Scene.Semantics.listCells", "Scene.Semantics.listTotalCount",
        "Scene.ListCell.row", "Scene.ListCell.column",
        "Scene.ListCell.text", "Scene.ListCell.selected",
        "Scene.Semantics.focused", "Scene.Semantics.isDefault",
        "Scene.Semantics.provenance", "Scene.Semantics.completeness",
        "Scene.Selection.start", "Scene.Selection.end",

        /* THE THIRD HOST-INTERNAL SHELF (plan 018 slice 1), declared here
           for the same reason `Scene.Window.island` is: it must never
           reach the wire, and the way to keep it off is to freeze the
           DECLARATION so that quietly adding it to `CodingKeys` shows up
           as a wire-path change rather than as nothing. Every number in it
           already crosses on the drain records; no contract field was
           added for any of it. */
        "Scene.Window.displayEpoch",
        /* 2026-08-07. What an alias POINTS AT. Additive in the ordinary
           sense — absent when the producer did not ask, and a consumer
           that has never heard of it keeps the answer it had. It exists
           because an alias file's own kind and type describe the alias
           and never its target, so every alias was unclassifiable and
           opening one predicted a Finder window that no Finder makes:
           `open "Mail"` reported timedOut after 18 s having worked
           (fidelity sweep A). */
        "Scene.DesktopItem.aliasTarget",
        "Scene.DesktopItem.AliasTarget.name",
        "Scene.DesktopItem.AliasTarget.kind",
        "Scene.DesktopItem.AliasTarget.type",
        "Scene.DesktopItem.AliasTarget.creator",
    ]

    // MARK: - What the gate compares against

    /// The wire shape this build promises for `major`, or nil if it makes no
    /// promise about that major (which is itself the answer a gate wants).
    public static func expectedWirePaths(major: Int) -> Set<String>? {
        switch major {
        case 1: return v1Frozen.union(v1Additions)
        case 2: return v1Frozen.union(v1Additions).union(v2Additions)
        default: return nil
        }
    }

    public static func expectedProperties(major: Int) -> Set<String>? {
        switch major {
        case 1:
            return v1FrozenProperties.union(v1AdditionalProperties)
        case 2:
            return v1FrozenProperties.union(v1AdditionalProperties)
                .union(v2AdditionalProperties)
        default:
            return nil
        }
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
