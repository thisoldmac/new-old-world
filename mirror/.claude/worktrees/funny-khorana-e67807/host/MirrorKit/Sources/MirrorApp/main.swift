import AppKit
import Foundation
import MirrorKit
import MirrorKitUI
import SwiftUI

/// MirrorApp shell v0: CLI → MirrorTarget → live polling / render-screenshot.
///
///     MirrorApp --host 127.0.0.1 --port 1410 --machine mac99 \
///               [--scope all] [--qmp path] [--plane axtree|observe] \
///               [--poll N] [--interval SECONDS] [--json] [--snapshot out.png]
///     MirrorApp --render-fixture <raw.json> --out <png>
///
/// `--render-fixture` rasterizes a capture envelope offscreen — no guest, no
/// window: the agent path for renderer verification (a screenshot of the
/// RENDER, MIRRORKIT-PLAN decision 7). `--snapshot` polls the live target
/// once and writes the same pixels a window would show. The window itself
/// arrives when the shell grows MirrorKitUI's live view; until then --poll N
/// is the headless smoke check.
struct Options {
    var target: MirrorTarget?
    var plane = ScenePoller.Plane.axtree
    var polls = 1
    var interval = 1.0
    var json = false
    var snapshot: String?
    var renderFixture: String?
    var out: String?
    var renderMenu: Int?        // open this menu index in the offscreen render
    var hoverItem: Int?         // highlight this row — proves hover offscreen
    var selectItem: String?     // draw this desktop icon selected, for proofs
    var appMenu = false         // draw the app switcher open, for proofs
    /// Live actuation through the real core path (hit-test / action model /
    /// dispatcher): poll → resolve → perform → re-poll.
    var actMenu: String?        // "File>New" — ⌘ via key, else QMP menu-drag
    var actControl: String?     // control title in the front window → axdo
    var actTitlebar: String?    // window title → activate via titlebar hit
    var actDragFront: String?   // "dx,dy" → drag the front titlebar (QMP)
    var actGrow: String?        // "dx,dy" → resize the front window (QMP)
    var actWidget: String?      // close|zoom|collapse on the front window
    var battery = false         // the actuation battery
    var window = false          // the live mirror window (slice 6)
    var display = false         // QDPeek content plane (qdtrace) on the front window
    var island: String?         // "l,t,r,b" → fetch that region's real pixels (M3)
    var islands = false         // M3: fetch the front window's content as pixels
    var actScroll: String?      // "down|up|pageDown|pageUp|thumb:VALUE|wheel:N"
    var serve: String?          // socket path: the agent-facing mirror service
    var managedServe = false    // 0.7 Host-managed lifecycle (readiness/quit)
}

func parseArgs() -> Options? {
    var o = Options()
    var host = "127.0.0.1"
    var port: Int?
    var scope = "all"
    var machine = "?"
    var qmp: String?

    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        func value() -> String? { it.next() }
        switch arg {
        case "--host": host = value() ?? host
        case "--port": port = value().flatMap(Int.init)
        case "--scope": scope = value() ?? scope
        case "--machine": machine = value() ?? machine
        case "--qmp": qmp = value()
        case "--plane": o.plane = value().flatMap(ScenePoller.Plane.init) ?? o.plane
        case "--poll": o.polls = value().flatMap(Int.init) ?? o.polls
        case "--interval": o.interval = value().flatMap(Double.init) ?? o.interval
        case "--json": o.json = true
        case "--display": o.display = true
        case "--snapshot": o.snapshot = value()
        case "--island": o.island = value()
        case "--islands": o.islands = true
        case "--act-scroll": o.actScroll = value()
        case "--serve": o.serve = value()
        case "--managed-serve": o.managedServe = true
        case "--render-fixture": o.renderFixture = value()
        case "--render-menu": o.renderMenu = value().flatMap(Int.init)
        case "--hover-item": o.hoverItem = value().flatMap(Int.init)
        case "--select-item": o.selectItem = value()
        case "--app-menu": o.appMenu = true
        case "--out": o.out = value()
        case "--act-menu": o.actMenu = value()
        case "--act-control": o.actControl = value()
        case "--act-titlebar": o.actTitlebar = value()
        case "--act-drag-front": o.actDragFront = value()
        case "--act-grow": o.actGrow = value()
        case "--act-widget": o.actWidget = value()
        case "--battery": o.battery = true
        case "--window": o.window = true
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
            return nil
        }
    }
    // Under Host-managed launch the guest coordinates are not passed as flags
    // (the launch template is fixed) — the supervisor injects them as env, so
    // the mirror learns which guest to drive without a compiled-in default.
    if o.managedServe && port == nil {
        let env = ProcessInfo.processInfo.environment
        host = env["TBT_MIRROR_GUEST_HOST"] ?? host
        port = env["TBT_MIRROR_GUEST_PORT"].flatMap(Int.init)
        scope = env["TBT_MIRROR_GUEST_SCOPE"] ?? scope
        machine = env["TBT_MIRROR_GUEST_MACHINE"] ?? machine
        qmp = env["TBT_MIRROR_GUEST_QMP"] ?? qmp
    }
    if let port {
        o.target = MirrorTarget(host: host, port: port, scope: scope,
                                machine: machine, qmp: qmp)
    }
    if o.managedServe {
        return o
    }
    if o.target == nil && o.renderFixture == nil {
        let usage = "usage: MirrorApp --host H --port P --machine M "
            + "[--scope all] [--qmp SOCK] [--plane axtree|observe] "
            + "[--poll N] [--interval S] [--json] [--snapshot out.png]\n"
            + "       MirrorApp --render-fixture raw.json --out out.png\n"
        FileHandle.standardError.write(Data(usage.utf8))
        return nil
    }
    return o
}

func summarize(_ scene: MirrorKit.Scene) -> String {
    let windows = scene.windows.map {
        "\"\($0.title)\"(\($0.app), z\($0.z)\($0.front ? ", front" : ""), " +
        "\($0.controls.count) ctl\($0.text != nil ? ", text" : ""))"
    }.joined(separator: " · ")
    let errors = scene.meta.errors.isEmpty
        ? "" : "  errors: \(scene.meta.errors.joined(separator: "; "))"
    let menus = scene.menubar.map { "\($0.menus.count) menus" } ?? "no menubar"
    return String(format: "seq %d [%@] %d apps, %d windows, %@, %.1f ms, %d B%@\n  %@",
                  scene.seq, scene.source, scene.apps.count,
                  scene.windows.count, menus,
                  scene.meta.latencyMs ?? -1, scene.meta.bytes ?? -1,
                  errors, windows.isEmpty ? "(no windows)" : windows)
}

@MainActor
func writeRenderShot(_ scene: MirrorKit.Scene, to path: String,
                     openMenu: Int? = nil, hoveredItem: Int? = nil,
                     selectedItem: String? = nil,
                     appMenuOpen: Bool = false) throws {
    let png = try RenderShot.png(scene: scene, openMenu: openMenu,
                                 hoveredItem: hoveredItem,
                                 selectedItem: selectedItem,
                                 appMenuOpen: appMenuOpen)
    try png.write(to: URL(fileURLWithPath: path))
    print("render-screenshot: \(path) (\(png.count) bytes, " +
          "\(scene.windows.count) windows)")
}

// Render REAL captured ops: --render-ops <ops.json> <out.png>. ops.json is the
// `ops` array from a `qdtrace fetch`. Proves the replay of real pen/font data
// (coordinate mapping) without the live poller.
if let oi = CommandLine.arguments.firstIndex(of: "--render-ops"),
   oi + 2 < CommandLine.arguments.count {
    let opsPath = CommandLine.arguments[oi + 1]
    let out = CommandLine.arguments[oi + 2]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: opsPath))
        let arr = (try JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        let ops = arr.compactMap { ($0 as? [String: Any]).flatMap(DisplayOp.init) }
        let axtree: [String: Any] = [
            "front": ["name": "SimpleText", "serialHi": 1, "serialLo": 2,
                      "front": true],
            "windows": [["title": "captured", "kind": 8,
                         "rect": [40, 80, 620, 500], "visible": true,
                         "controls": []]],
            "menus": [["title": "File", "left": 38, "items": []]],
        ]
        var scene = SceneBuilder.sceneFromAxtree(
            axtree, seq: 1, screen: .init(w: 800, h: 600),
            capturedAt: 1_000_000_000)
        if !scene.windows.isEmpty { scene.windows[0].display = ops }
        try MainActor.assumeIsolated { try writeRenderShot(scene, to: out) }
        print("rendered \(ops.count) ops")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-ops failed: \(error)\n".utf8))
        exit(1)
    }
}

// Offscreen demo: a synthetic SimpleText window carrying display ops, so the
// DisplayReplay render path is verifiable without a guest. --display-demo out.png
if CommandLine.arguments.contains("--display-demo"),
   let out = CommandLine.arguments.last {
    func textOp(_ s: String, _ h: Int, _ v: Int) -> DisplayOp {
        var op = DisplayOp(op: "text", ticks: 0)
        op.text = s; op.pen = [h, v]; op.font = 3; op.size = 12; op.face = 0
        return op
    }
    var fgBlack = DisplayOp(op: "state", ticks: 0)
    fgBlack.kind = "fg"; fgBlack.rgb = [0, 0, 0]
    var origin = DisplayOp(op: "state", ticks: 0)
    origin.kind = "origin"; origin.origin = [0, 0]
    let lines = ["The quick brown fox", "jumps over the lazy dog.",
                 "QuickDraw content, replayed", "through the real Geneva strike."]
    var ops: [DisplayOp] = [origin, fgBlack]
    for (i, line) in lines.enumerated() {
        ops.append(textOp(line, 4, 16 + i * 16))
    }
    // Build a real scene via the public normalizer (memberwise inits are
    // internal), then attach the ops to the front window's display.
    let axtree: [String: Any] = [
        "front": ["name": "SimpleText", "serialHi": 1, "serialLo": 2,
                  "front": true],
        "windows": [["title": "untitled", "kind": 8,
                     "rect": [40, 80, 560, 460], "visible": true,
                     "controls": []]],
        "menus": [["title": "File", "left": 38, "items": []]],
    ]
    var scene = SceneBuilder.sceneFromAxtree(
        axtree, seq: 1, screen: .init(w: 800, h: 600),
        capturedAt: 1_000_000_000)
    if !scene.windows.isEmpty { scene.windows[0].display = ops }
    do {
        try MainActor.assumeIsolated { try writeRenderShot(scene, to: out) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("demo render failed: \(error)\n".utf8))
        exit(1)
    }
}

guard let options = parseArgs() else {
    exit(2)
}

// Host-managed 0.7 service: --managed-serve. The supervisor injects the
// readiness identity and the loopback port it will probe; the mirror binds the
// unix method socket (fixed IPC-contract path) AND the TCP readiness/quit
// endpoint. Same MirrorService brain as the standalone --serve path.
if options.managedServe {
    let env = ProcessInfo.processInfo.environment
    guard let identity = env["TBT_HOST_SERVICE_READINESS_IDENTITY"],
          let portText = env["TBT_HOST_SERVICE_ENDPOINT_PORT"],
          let readinessPort = UInt16(portText) else {
        FileHandle.standardError.write(Data((
            "mirror --managed-serve: the supervisor must inject "
            + "TBT_HOST_SERVICE_READINESS_IDENTITY and "
            + "TBT_HOST_SERVICE_ENDPOINT_PORT\n").utf8))
        exit(2)
    }
    guard let target = options.target else {
        FileHandle.standardError.write(Data((
            "mirror --managed-serve: no guest target — inject "
            + "TBT_MIRROR_GUEST_HOST/PORT (or pass --host/--port)\n").utf8))
        exit(2)
    }
    let defaultSock = "~/Library/Application Support/TimBotTu/Host Next/"
        + "Runtime/mirror.sock"
    let sock = ((env["TBT_MIRROR_SOCKET"] ?? defaultSock) as NSString)
        .expandingTildeInPath
    let service = MirrorService(target: target, socketPath: sock)
    service.managedReadiness = (identity: identity, port: readinessPort)
    service.run()
}

// The agent-facing mirror service: --serve <socket>. Implements
// mcp/mirror-service-ipc.toml over a unix stream — the headless head of
// the one-brain-two-heads architecture. Blocks forever.
if let sock = options.serve, let target = options.target {
    MirrorService(target: target, socketPath: sock).run()
}

// M3 pixel island: --island "l,t,r,b" [--out png]. Fetches ONE screen region's
// real pixels off the guest (the W1 pager + PackBits codec) and writes it as a
// PNG. This is the honest fallback for content with no semantics to read —
// see PixelIsland.swift and the `finder-window-icons-are-offscreen-blits`
// finding. Proves the pixel path end-to-end without the renderer.
if let spec = options.island, let target = options.target {
    let n = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard n.count == 4 else { fail("--island needs \"left,top,right,bottom\"") }
    do {
        let wire = WireClient(target: target)
        let t0 = Date()
        let island = try wire.captureRegion(left: n[0], top: n[1],
                                            right: n[2], bottom: n[3])
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "island %dx%d origin=(%d,%d) scale=%d — %.0f ms",
                     island.width, island.height, island.originX,
                     island.originY, island.scale, ms))
        if let out = options.out {
            guard let provider = CGDataProvider(data: island.rgba as CFData),
                  let cg = CGImage(
                    width: island.width, height: island.height,
                    bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: island.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)
            else { fail("island: CGImage failed") }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:])
            else { fail("island: png encode failed") }
            try png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(png.count) bytes)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("island failed: \(error)\n".utf8))
        exit(1)
    }
}


// Offscreen fixture render: no guest, no window.
if let fixture = options.renderFixture {
    guard let out = options.out else {
        FileHandle.standardError.write(Data("--render-fixture needs --out\n".utf8))
        exit(2)
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let scene = try FixtureEnvelope.scene(from: data)
        try MainActor.assumeIsolated {
            try writeRenderShot(scene, to: out, openMenu: options.renderMenu,
                                hoveredItem: options.hoverItem)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
        exit(1)
    }
}

guard let target = options.target else { exit(2) }

// The actuation battery: drive the real action model through a gesture suite.
if options.battery {
    print("actuation battery @ \(target.host):\(target.port)")
    var battery = ActBattery(target: target)
    let results = battery.run()
    let pass = results.filter { $0.status == .pass }.count
    let fail = results.filter { $0.status == .fail }.count
    let skip = results.filter { $0.status == .skip }.count
    print("battery: \(pass) pass, \(fail) fail, \(skip) skip")
    exit(fail == 0 ? 0 : 1)
}

// The live mirror window (slice 6): SceneView pixels + core-routed input.
if options.window {
    final class SnapshotBridge: NSObject {
        let controller: LiveMirrorController
        init(controller: LiveMirrorController) { self.controller = controller }

        /// Decision 7's live snapshot: the app's own drawn scene → PNG.
        /// Menu actions arrive on the main thread.
        @objc func saveRenderShot(_ sender: Any?) {
            MainActor.assumeIsolated {
                guard let scene = controller.scene else { return }
                do {
                    let png = try RenderShot.png(scene: scene)
                    let dir = FileManager.default.urls(
                        for: .desktopDirectory, in: .userDomainMask)[0]
                    let url = dir.appendingPathComponent(
                        "mirror-render-seq\(scene.seq).png")
                    try png.write(to: url)
                    print("render-screenshot: \(url.path)")
                } catch {
                    print("render-screenshot failed: \(error)")
                }
            }
        }
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let controller = LiveMirrorController(target: target,
                                          display: options.display,
                                          islands: options.islands)
    controller.start(interval: options.interval)
    let bridge = SnapshotBridge(controller: controller)

    let mainMenu = NSMenu()
    let appEntry = NSMenuItem()
    mainMenu.addItem(appEntry)
    let appMenu = NSMenu()
    let shot = NSMenuItem(title: "Save Render-Screenshot",
                          action: #selector(SnapshotBridge.saveRenderShot(_:)),
                          keyEquivalent: "s")
    shot.target = bridge
    appMenu.addItem(shot)
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(
        title: "Quit Mirror",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appEntry.submenu = appMenu
    app.mainMenu = mainMenu

    // Match the guest resolution's aspect (detected from the guest, not
    // assumed). The content view fills the whole window and the renderer
    // scales the guest surface uniformly into it, so enlarging the window
    // scales the render without distorting guest coords. Lock the aspect
    // ratio so a resize stays 1:1 with the guest (no letterbox, no skew).
    let guestAspect = NSSize(width: controller.screen.w,
                             height: controller.screen.h)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: controller.screen.w,
                            height: controller.screen.h),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "Mirror — \(target.machine) @ \(target.host):\(target.port)"
    window.contentAspectRatio = guestAspect
    window.contentMinSize = NSSize(width: 400, height: 300)
    window.contentView = NSHostingView(
        rootView: LiveMirrorView(controller: controller))
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.isReleasedWhenClosed = false
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// Live actuation: poll → resolve through the core (hit-test / action
// model) → dispatch → re-poll, printing before/after summaries.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

if options.actScroll != nil || options.actMenu != nil || options.actControl != nil
    || options.actTitlebar != nil || options.actDragFront != nil
    || options.actGrow != nil || options.actWidget != nil {
    // Share one wire (single-connection worker) between poll and dispatch.
    let actWire = WireClient(target: target)
    var actPoller = ScenePoller(target: target, wire: actWire)
    // Honour the content flags here too: ONE poller spans before → act → after,
    // which is what makes a focus change verifiable (raise a window and the
    // island lifecycle is exercised across the two polls, in one process).
    actPoller.includeDisplay = options.display
    actPoller.includeIslands = options.islands
    actPoller.detectScreen()
    let dispatcher = ActionDispatcher(target: target, wire: actWire)
    do {
        let before = try actPoller.poll(options.plane)
        print("before: " + summarize(before))

        let actions: [MirrorAction]
        if let spec = options.actScroll {
            // Resolve the front window's live scrollbar, then drive the region
            // the spec names — through the REAL hit-test where possible, so
            // this exercises the same path a click in the window would.
            guard let win = before.windows.first(where: { $0.front }),
                  let bar = win.controls.first(where: Scrollbar.isLive)
            else { fail("no live scrollbar on the front window (nothing to scroll?)") }
            let origin = (x: win.rect.l, y: win.rect.t + HitTester.titlebar)
            print("scrollbar: value=\(bar.value ?? -1) range=\(bar.min ?? -1)…\(bar.max ?? -1) "
                  + "rect=\(bar.rect.map { "[\($0.l),\($0.t),\($0.r),\($0.b)]" } ?? "?")")
            func global(_ p: (x: Int, y: Int)) -> (x: Int, y: Int) {
                (p.x + origin.x, p.y + origin.y)
            }
            if spec.hasPrefix("thumb:") {
                guard let want = Int(spec.dropFirst(6)),
                      let from = Scrollbar.center(bar, .thumb),
                      let to = Scrollbar.thumbTarget(bar, value: want)
                else { fail("--act-scroll thumb:VALUE needs a live thumb") }
                actions = ActionModel.thumbDrag(from: global(from), to: global(to))
            } else if spec.hasPrefix("wheel:") {
                guard let n = Int(spec.dropFirst(6)) else { fail("wheel:N") }
                actions = ActionModel.wheel(n, on: bar, contentOrigin: origin)
            } else {
                let part: Scrollbar.Part
                switch spec {
                case "down": part = .lineDown
                case "up": part = .lineUp
                case "pageDown": part = .pageDown
                case "pageUp": part = .pageUp
                default: fail("--act-scroll: down|up|pageDown|pageUp|thumb:V|wheel:N")
                }
                guard let c = Scrollbar.center(bar, part) else { fail("no \(spec) region") }
                let g = global(c)
                // Through the hit-tester, so a miss shows up as a wrong target
                // rather than a silently-right click.
                let hit = HitTester.hitTest(before, x: g.x, y: g.y)
                guard case .scrollbar(_, _, let hitPart, _, _) = hit, hitPart == part
                else { fail("hit-test at \(g) resolved to \(hit), not \(part)") }
                actions = ActionModel.click(on: hit)
            }
            guard !actions.isEmpty else { fail("scroll action is inert: \(spec)") }
        } else if let spec = options.actMenu {
            let parts = spec.split(separator: ">", maxSplits: 1)
            guard parts.count == 2,
                  let menu = before.menubar?.menus
                      .first(where: { $0.title == String(parts[0]) }),
                  let item = menu.items
                      .first(where: { $0.title.hasPrefix(String(parts[1])) })
            else { fail("menu item not found: \(spec)") }
            actions = ActionModel.menuSelect(menu: menu, item: item)
            guard !actions.isEmpty else { fail("menu item is inert: \(spec)") }
        } else if let spec = options.actWidget {
            guard let front = before.windows.first(where: { $0.front })
            else { fail("no front window") }
            let kind: HitTester.WidgetKind = spec == "zoom" ? .zoom
                : spec == "collapse" ? .collapse : .close
            let boxY = front.rect.t + 4
            let boxX = kind == .close ? front.rect.l + 6
                : kind == .collapse ? front.rect.r - 17
                : front.rect.r - 33
            let hit = HitTester.hitTest(before, x: boxX + 5, y: boxY + 5)
            guard case .widget = hit else { fail("widget hit missed: \(hit)") }
            actions = ActionModel.click(on: hit)
        } else if let spec = options.actGrow {
            let parts = spec.split(separator: ",")
            guard parts.count == 2, let dx = Int(parts[0]),
                  let dy = Int(parts[1]),
                  let front = before.windows.first(where: { $0.front })
            else { fail("--act-grow needs dx,dy and a front window") }
            let grab = (x: front.rect.r - 7, y: front.rect.b - 7)
            actions = ActionModel.growDrag(
                from: grab, to: (grab.x + dx, grab.y + dy))
        } else if let title = options.actControl {
            guard let front = before.windows.first(where: { $0.front }),
                  let ctl = front.controls
                      .first(where: { $0.title == title && $0.visible })
            else { fail("control not found in front window: \(title)") }
            // Resolve through the hit-tester at the control's center, so
            // the tested path is pixel-click-shaped, not a title lookup.
            let r = ctl.rect!
            let hit = HitTester.hitTest(
                before,
                x: front.rect.l + (r.l + r.r) / 2,
                y: front.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
            actions = ActionModel.click(on: hit)
            guard !actions.isEmpty else { fail("control is inert: \(title)") }
        } else if let title = options.actTitlebar {
            guard let win = before.windows
                .first(where: { $0.title == title && $0.visible })
            else { fail("window not found: \(title)") }
            let hit = HitTester.hitTest(before, x: win.rect.l + 40,
                                        y: win.rect.t + 5)
            actions = ActionModel.click(on: hit)
        } else {
            let parts = (options.actDragFront ?? "").split(separator: ",")
            guard parts.count == 2, let dx = Int(parts[0]),
                  let dy = Int(parts[1]),
                  let front = before.windows.first(where: { $0.front })
            else { fail("--act-drag-front needs dx,dy and a front window") }
            let grab = (x: front.rect.l + front.rect.width / 2,
                        y: front.rect.t + 5)
            actions = ActionModel.titlebarDrag(
                from: grab, to: (grab.x + dx, grab.y + dy))
        }

        for action in actions {
            let availability = ActionModel.availability(action, target: target)
            guard availability == .available else {
                fail("not available on this target: \(availability)")
            }
            let reply = try dispatcher.perform(action)
            print("performed \(action) -> \(reply)")
        }
        Thread.sleep(forTimeInterval: 1.0)
        let after = try actPoller.poll(options.plane)
        print("after:  " + summarize(after))
        if let snapshot = options.snapshot {
            try MainActor.assumeIsolated {
                try writeRenderShot(after, to: snapshot)
            }
        }
        // The scroll's verification signal: the guest's own scrollbar value.
        if options.actScroll != nil,
           let bar = after.windows.first(where: { $0.front })?
                .controls.first(where: Scrollbar.isLive) {
            print("scrollbar now: value=\(bar.value ?? -1) "
                  + "range=\(bar.min ?? -1)…\(bar.max ?? -1)")
        }
    } catch {
        fail("actuation failed: \(error)")
    }
    exit(0)
}

// Live polling.
var poller = ScenePoller(target: target)
poller.includeDesktopItems = true
poller.includeDisplay = options.display
poller.includeIslands = options.islands
poller.detectScreen()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

for i in 0..<max(1, options.polls) {
    do {
        let scene = try poller.poll(options.plane)
        if options.json {
            let data = try encoder.encode(scene)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(summarize(scene))
        }
        if let snapshot = options.snapshot, i == options.polls - 1 {
            try MainActor.assumeIsolated {
                // --render-menu/--hover-item apply to the LIVE snapshot too:
                // that is how the menu surface gets verified offscreen, since an
                // agent cannot screenshot the window itself.
                try writeRenderShot(scene, to: snapshot,
                                    openMenu: options.renderMenu,
                                    hoveredItem: options.hoverItem,
                                    selectedItem: options.selectItem,
                                    appMenuOpen: options.appMenu)
            }
        }
    } catch {
        FileHandle.standardError.write(Data("poll failed: \(error)\n".utf8))
        exit(1)
    }
    if i < options.polls - 1 {
        Thread.sleep(forTimeInterval: options.interval)
    }
}
