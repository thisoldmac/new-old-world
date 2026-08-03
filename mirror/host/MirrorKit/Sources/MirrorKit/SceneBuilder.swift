import Foundation

/// Normalizers: raw wire payloads (`axtree` / `observe` results, decoded to
/// `[String: Any]`) → `Scene`. Direct port of `scene.py`; the sharp edges are
/// documented there and in `CONTROL-SURFACE.md` and MUST survive the port:
///
/// - rect order: `axtree` serializes `[l,t,r,b]` (verbs.c); `observe`
///   own-windows are Mac memory order `[t,l,b,r]`.
/// - axtree window rects are the CONTENT port; the title bar sits above, so
///   the rendered box grows up by `titleBarHeight`.
/// - AXPeek can read one slot past the real MenuList → drop menus whose title
///   is non-printable (a real title is the Apple byte or printable text).
/// - Off-screen "hidden" sentinel rects (16000,16000,…) from faceless apps
///   are dropped.
public enum SceneBuilder {

    /// Classic title-bar height (px) added above the content rect.
    public static let titleBarHeight = 20

    /// Apple-menu title byte in Chicago (0x14); the wire sends it raw.
    static let appleMenuTitle = "\u{14}"

    public enum RectOrder {
        /// Mac memory order (top, left, bottom, right) — observe plane.
        case tlbr
        /// axtree's serialization (left, top, right, bottom).
        case ltrb
    }

    // MARK: - Rect

    public static func normalizeRect(_ raw: Any?, order: RectOrder) -> Rect? {
        if let dict = raw as? [String: Any] {
            guard let l = intValue(dict["l"]), let t = intValue(dict["t"]),
                  let r = intValue(dict["r"]), let b = intValue(dict["b"]) else {
                return nil
            }
            return Rect(l: l, t: t, r: r, b: b)
        }
        guard let list = raw as? [Any], list.count == 4,
              let a = intValue(list[0]), let b = intValue(list[1]),
              let c = intValue(list[2]), let d = intValue(list[3]) else {
            return nil
        }
        switch order {
        case .ltrb: return Rect(l: a, t: b, r: c, b: d)
        case .tlbr: return Rect(l: b, t: a, r: d, b: c)
        }
    }

    // MARK: - Scenes

    /// Normalize one `axtree` result (scope=all or scope=front) into a scene.
    /// Per-app oracle errors (`ax_oracle_not_found`, `ax_oracle_stale`) are
    /// surfaced honestly, not hidden.
    public static func sceneFromAxtree(_ result: [String: Any], seq: Int,
                                       screen: Scene.ScreenSize,
                                       capturedAt: Double,
                                       latencyMs: Double? = nil,
                                       bytes: Int? = nil) -> Scene {
        // scope=front returns a flat {front, windows, menus} -> wrap as one
        // entry so both scopes normalize identically.
        let rawApps: [Any]
        if let apps = result["apps"] as? [Any] {
            rawApps = apps
        } else {
            rawApps = [[
                "process": result["front"] as? [String: Any] ?? [:],
                "windows": result["windows"] as Any,
                "menus": result["menus"] as Any,
            ] as [String: Any]]
        }
        let entries = rawApps.compactMap { $0 as? [String: Any] }

        var apps: [Scene.AppRef] = []
        var errors: [String] = []
        var frontWindows: [Scene.Window] = []
        var restWindows: [Scene.Window] = []
        var menubar: Scene.Menubar?

        for entry in entries {
            let proc = entry["process"] as? [String: Any] ?? [:]
            let name = stringValue(proc["name"]) ?? "?"
            let psn = psnString(proc)
            let isFront = boolValue(proc["front"]) ?? (entries.count == 1)
            let errCode: String? = {
                if let err = entry["error"] as? [String: Any] {
                    return stringValue(err["code"]).flatMap { $0.isEmpty ? nil : $0 }
                }
                return stringValue(entry["error"]).flatMap { $0.isEmpty ? nil : $0 }
            }()
            apps.append(.init(psn: psn, name: name, front: isFront,
                              error: errCode))
            if let code = errCode {
                errors.append("\(name): \(code)")
                continue
            }
            let wins = normalizeWindows(appName: name, psn: psn,
                                        rawWindows: entry["windows"],
                                        isFrontApp: isFront, order: .ltrb)
            if isFront {
                frontWindows = wins
                if let rawMenus = entry["menus"] as? [Any], !rawMenus.isEmpty {
                    menubar = .init(app: name, menus: normalizeMenus(rawMenus))
                }
            } else {
                restWindows.append(contentsOf: wins)
            }
        }

        // Known approximation (v0): per-app z is real; cross-app global
        // stacking is reconstructed front-app-first. True global order needs
        // the WindowList cross-links — a source improvement, not a renderer
        // change.
        //
        // The desktop backdrop (Finder's "Desktop") is always backmost and
        // never front: Finder lists it first, which would otherwise steal the
        // front slot from a real open folder window.
        let frontName = apps.first(where: { $0.front })?.name
        let combined = frontWindows + restWindows
        let foreground = combined.filter { !HitTester.isDesktopBackdrop($0) }
        let backdrops = combined.filter { HitTester.isDesktopBackdrop($0) }
        var ordered = foreground + backdrops
        for i in ordered.indices { ordered[i].front = false }
        if let firstReal = ordered.firstIndex(where: {
            !HitTester.isDesktopBackdrop($0) && $0.app == frontName
        }) {
            ordered[firstReal].front = true
        }
        for i in ordered.indices { ordered[i].z = i }

        return Scene(version: IR.version, seq: seq, source: "axtree",
                     capturedAt: capturedAt, screen: screen, apps: apps,
                     processes: nil, menubar: menubar, windows: ordered,
                     desktopItems: nil,
                     meta: .init(latencyMs: latencyMs, bytes: bytes,
                                 errors: errors, plane: nil))
    }

    /// Normalize an `observe` result into a scene. `observe` is
    /// process-local: `processes` is the real cross-process truth, but
    /// windows reflect only the serving Worker's own (faceless => usually
    /// empty) A5 world. Foreign window geometry is absent by construction —
    /// that is the AXPeek upgrade, not a bug here.
    public static func sceneFromObserve(_ result: [String: Any], seq: Int,
                                        screen: Scene.ScreenSize,
                                        capturedAt: Double,
                                        latencyMs: Double? = nil,
                                        bytes: Int? = nil) -> Scene {
        let procs = (result["processes"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
        var apps: [Scene.AppRef] = []
        var processes: [Scene.ProcessRef] = []
        for p in procs {
            let name = stringValue(p["name"]) ?? "?"
            let psn = psnString(p)
            let front = boolValue(p["front"]) ?? false
            let sig = stringValue(p["signature"]) ?? ""
            apps.append(.init(psn: psn, name: name, front: front, error: nil))
            processes.append(.init(psn: psn, name: name, front: front,
                                   signature: sig))
        }

        let frontName = apps.first(where: { $0.front })?.name
        var ownWindows = normalizeWindows(appName: frontName ?? "worker",
                                          psn: "self",
                                          rawWindows: result["windows"],
                                          isFrontApp: true, order: .tlbr)
        for i in ownWindows.indices {
            ownWindows[i].z = i
        }

        return Scene(version: IR.version, seq: seq, source: "observe",
                     capturedAt: capturedAt, screen: screen, apps: apps,
                     processes: processes, menubar: nil, windows: ownWindows,
                     desktopItems: nil,
                     meta: .init(latencyMs: latencyMs, bytes: bytes,
                                 errors: [],
                                 plane: "process-list (pre-AXPeek)"))
    }

    // MARK: - Desktop items

    /// fdIsAlias / fdInvisible bits in the Finder flags word.
    static let fdIsAlias = 0x8000
    static let fdInvisible = 0x4000

    /// Normalize a `list` result (of the Desktop Folder) into desktop items.
    /// The invisible ones are dropped (they aren't on the real desktop).
    public static func desktopItems(from result: [String: Any]) -> [Scene.DesktopItem] {
        var items: [Scene.DesktopItem] = []
        for raw in (result["items"] as? [Any] ?? []) {
            guard let it = raw as? [String: Any] else { continue }
            let loc = it["loc"] as? [String: Any] ?? [:]
            let h = intValue(loc["h"]) ?? 0
            let v = intValue(loc["v"]) ?? 0
            let flags = intValue(it["flags"]) ?? 0
            if flags & fdInvisible != 0 { continue }
            items.append(.init(
                name: stringValue(it["name"]) ?? "",
                kind: stringValue(it["kind"]) ?? "file",
                type: stringValue(it["type"]),
                creator: stringValue(it["creator"]),
                x: h, y: v,
                placed: !(h == 0 && v == 0),
                alias: flags & fdIsAlias != 0,
                invisible: false))
        }
        return items
    }

    // MARK: - Windows

    static func normalizeWindows(appName: String, psn: String,
                                 rawWindows: Any?, isFrontApp: Bool,
                                 order: RectOrder) -> [Scene.Window] {
        var windows: [Scene.Window] = []
        let raw = (rawWindows as? [Any] ?? [])
        for (idx, item) in raw.enumerated() {
            guard let win = item as? [String: Any],
                  let content = normalizeRect(win["rect"], order: order) else {
                continue
            }
            // AXPeek's off-screen "hidden" sentinel rects.
            if content.l >= 8000 || content.t >= 8000 {
                continue
            }
            let box = Rect(l: content.l, t: content.t - titleBarHeight,
                           r: content.r, b: content.b)
            var controls: [Scene.Control] = []
            for rawCtl in (win["controls"] as? [Any] ?? []) {
                guard let ctl = rawCtl as? [String: Any] else { continue }
                let global = normalizeRect(ctl["rect"], order: order)
                // Content-relative for render.
                let local = global.map {
                    Rect(l: $0.l - content.l, t: $0.t - content.t,
                         r: $0.r - content.l, b: $0.b - content.t)
                }
                controls.append(.init(
                    ref: stringValue(ctl["ref"]) ?? "",
                    role: stringValue(ctl["role"]) ?? "control",
                    title: stringValue(ctl["title"]) ?? "",
                    rect: local,
                    enabled: boolValue(ctl["enabled"]) ?? true,
                    visible: boolValue(ctl["visible"]) ?? true,
                    value: intValue(ctl["value"]),
                    min: intValue(ctl["min"]),
                    max: intValue(ctl["max"]),
                    checked: boolValue(ctl["checked"]) ?? false))
            }
            var text: Scene.TextContent?
            if let te = win["textEdit"] as? [String: Any], te["text"] != nil {
                text = .init(content: stringValue(te["text"]) ?? "",
                             active: boolValue(te["active"]) ?? false)
            }
            let title = stringValue(win["title"]) ?? ""
            let z = intValue(win["z"]) ?? idx
            windows.append(.init(
                id: "\(psn)/\(title)#\(idx)",
                app: appName,
                psn: psn,
                title: title,
                kind: intValue(win["kind"]),
                rect: box,
                front: isFrontApp && z == 0,
                z: z,
                visible: boolValue(win["visible"]) ?? true,
                controls: controls,
                /* Carried, where it used to be discarded. The producer has
                   always sent one; nothing on this side ever read it, so no
                   window could be closed, moved or resized from a mirror -
                   every act addressed by reference needs one, and the
                   windowID beside it is a rendering key no guest can
                   resolve. */
                ref: stringValue(win["ref"]),
                text: text,
                items: nil,
                display: nil))
        }
        windows.sort { $0.z < $1.z }
        return windows
    }

    // MARK: - Menus

    static func normalizeMenus(_ raw: [Any]) -> [Scene.Menu] {
        var menus: [Scene.Menu] = []
        for rawMenu in raw {
            guard let menu = rawMenu as? [String: Any] else { continue }
            let title = stringValue(menu["title"]) ?? ""
            let isApple = title == appleMenuTitle
            // Drop garbage menus: AXPeek sometimes reads one slot past the
            // real MenuList, yielding a non-printable title.
            if !isApple {
                let garbage = title.isEmpty || title.unicodeScalars.contains {
                    $0.value < 32 || $0.value == 127
                }
                if garbage { continue }
            }
            var items: [Scene.MenuItem] = []
            for (idx, rawItem) in (menu["items"] as? [Any] ?? []).enumerated() {
                guard let item = rawItem as? [String: Any] else { continue }
                let itemTitle = stringValue(item["title"]) ?? ""
                items.append(.init(
                    title: itemTitle,
                    index: intValue(item["index"]) ?? idx + 1,
                    separator: itemTitle == "-",
                    enabled: boolValue(item["enabled"]) ?? true,
                    mark: truthy(item["mark"]),
                    cmd: menuCommand(item["command"])))
            }
            menus.append(.init(title: isApple ? "" : title, apple: isApple,
                               left: intValue(menu["left"]) ?? 0,
                               id: intValue(menu["id"]) ?? 0,
                               items: items))
        }
        return menus
    }

    /// Mounted volumes from the `volumes` verb. They carry no position — the
    /// Finder keeps that in its own desktop database, which is not a File
    /// Manager fact — so they arrive unplaced and the poller lays them out.
    public static func volumeItems(from result: [String: Any])
        -> [Scene.DesktopItem]? {
        guard let raw = result["volumes"] as? [Any] else { return nil }
        return raw.compactMap { entry -> Scene.DesktopItem? in
            guard let v = entry as? [String: Any],
                  let name = stringValue(v["name"]), !name.isEmpty else {
                return nil
            }
            // "disk", not "volume": IconAtlas and the renderer already know
            // that kind and draw the hard-disk glyph for it. Inventing a second
            // spelling for the same thing is how it ended up as a generic
            // document icon.
            return .init(name: name, kind: "disk", type: nil, creator: nil,
                         x: 0, y: 0,
                         placed: boolValue(v["placed"]) ?? false,
                         alias: false, invisible: false)
        }
    }

    /// The wire's `command` is the raw ⌘ char code; only printable ASCII
    /// survives as a shortcut char.
    static func menuCommand(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let code = intValue(raw), code > 32, code < 127,
           let scalar = Unicode.Scalar(UInt32(code)) {
            return String(Character(scalar))
        }
        return ""
    }

    // MARK: - Wire-value coercion

    static func psnString(_ entry: [String: Any]) -> String {
        let hi = intValue(entry["serialHi"]) ?? 0
        let lo = intValue(entry["serialLo"]) ?? 0
        return "\(hi).\(lo)"
    }

    /// JSONSerialization yields NSNumber for every numeric; booleans are
    /// NSNumber too, so coercion must mirror Python's loose typing exactly:
    /// int(v) truncates, bool(v) is truthiness where scene.py used bool().
    static func intValue(_ raw: Any?) -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    static func stringValue(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    static func boolValue(_ raw: Any?) -> Bool? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    /// Python bool(x) semantics for fields scene.py truthy-tested (mark).
    static func truthy(_ raw: Any?) -> Bool {
        guard let raw, !(raw is NSNull) else { return false }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return !s.isEmpty }
        return true
    }
}
