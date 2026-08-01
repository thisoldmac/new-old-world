import Foundation
import MirrorKit
import MirrorKitUI

/// The agent-facing mirror service — `MirrorApp --serve <socket>`.
///
/// Implements `mcp/mirror-service-ipc.toml`: a unix-stream server with
/// 0.7 framing (uint32-BE length + canonical JSON, one request per
/// connection), a session-scoped grant model (semantic / tracking planes),
/// and fifteen element-first methods dispatched onto the SAME MirrorKit core
/// the human window uses. The classic worker wire and QMP never appear on
/// this surface — they are implementation detail, and this process is the one
/// wire client (which is what resolves single-connection contention).
final class MirrorService {
    private let target: MirrorTarget
    /// One serial queue owns the wire — poller and dispatcher both live here,
    /// exactly like LiveMirrorController.
    private let queue = DispatchQueue(label: "mirror.serve.wire")
    private var poller: ScenePoller
    private let dispatcher: ActionDispatcher
    private let socketPath: String

    // MARK: Session (one at a time — the service drives one guest)
    private struct Session {
        let id: String
        let planes: Set<String>
    }
    private var session: Session?
    private var lastScene: Scene?

    /// When the mirror runs as a Host-managed 0.7 service, the supervisor
    /// injects a readiness identity and a loopback port; the service must serve
    /// the `/.well-known/timbottu/{readiness,quit}` HTTP handshake there so the
    /// coordinator can prove it ready and stop it cooperatively. Nil for the
    /// standalone `--serve <socket>` dev path.
    var managedReadiness: (identity: String, port: UInt16)?

    init(target: MirrorTarget, socketPath: String) {
        self.target = target
        self.socketPath = socketPath
        let wire = WireClient(target: target)
        var poller = ScenePoller(target: target, wire: wire)
        poller.includeDesktopItems = true
        poller.detectScreen()
        self.poller = poller
        self.dispatcher = ActionDispatcher(target: target, wire: wire)
    }

    // MARK: - Socket server (accept loop; one request per connection)

    private func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("mirror service: \(message)\n".utf8))
        exit(1)
    }

    func run() -> Never {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { die("socket: \(String(cString: strerror(errno)))") }
        unlink(socketPath)
        // sun_path is ~104 bytes. A deep workspace path exceeds it, so bind
        // RELATIVE from the socket's directory — the bound inode is identical
        // and clients using the full path still connect.
        let dir = (socketPath as NSString).deletingLastPathComponent
        let base = (socketPath as NSString).lastPathComponent
        let bindPath = socketPath.utf8.count < 100 ? socketPath : base
        if bindPath == base {
            guard FileManager.default.changeCurrentDirectoryPath(dir) else {
                die("cannot chdir to \(dir) for a long socket path")
            }
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(bindPath.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard ok else { die("socket path too long even relative: \(bindPath)") }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0 else { die("bind: \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else { die("listen failed") }
        FileHandle.standardOutput.write(Data(
            "mirror service: \(socketPath) (target \(target.host):\(target.port))\n".utf8))

        let acceptThread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                self.handle(client: client)
            }
        }
        acceptThread.name = "mirror.serve.accept"
        acceptThread.start()

        // Host-managed lifecycle plane: the loopback readiness/quit endpoint the
        // 0.7 coordinator probes. Independent of the unix method socket above —
        // agents still reach the fifteen mirror.* methods over the socket; this
        // TCP plane carries only the supervisor handshake.
        if let managed = managedReadiness {
            ManagedReadinessListener(
                identity: managed.identity, port: managed.port
            ).start()
        }
        // Main thread parks in the run loop — mirror.shot hops here for the
        // @MainActor ImageRenderer.
        RunLoop.main.run()
        fatalError("run loop exited")
    }

    private func handle(client: Int32) {
        defer { close(client) }
        guard let frame = Self.readFrame(client),
              let obj = try? JSONSerialization.jsonObject(with: frame)
                as? [String: Any],
              let method = obj["method"] as? String else {
            Self.writeFrame(client, Self.encode(
                ["ok": false,
                 "error": ["code": "bad_request",
                           "message": "expected {method, params} frame"]]))
            return
        }
        // One request per connection: the client half-closes after the frame,
        // so anything already readable past it is a framing violation. A
        // non-blocking peek keeps a merely-slow client (hasn't sent EOF yet)
        // from hanging the single accept thread — EAGAIN means "nothing extra
        // yet", not "trailing bytes".
        if Self.hasTrailingBytes(client) {
            Self.writeFrame(client, Self.encode(
                ["ok": false,
                 "error": ["code": "bad_request",
                           "message": "bytes after frame (one request per connection)"]]))
            return
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        // All wire work is serial on the queue; shot additionally hops to main.
        var reply: [String: Any] = [:]
        queue.sync {
            reply = self.dispatch(method: method, params: params)
        }
        Self.writeFrame(client, Self.encode(reply))
    }

    private static func readFrame(_ fd: Int32) -> Data? {
        func readN(_ n: Int) -> Data? {
            var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while out.count < n {
                let r = read(fd, &buf, min(buf.count, n - out.count))
                if r <= 0 { return nil }
                out.append(contentsOf: buf[0..<r])
            }
            return out
        }
        guard let hdr = readN(4) else { return nil }
        let n = hdr.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        guard n > 0, n <= 1_048_576 else { return nil }
        return readN(Int(n))
    }

    /// True if bytes are already readable past the framed request — a
    /// one-request-per-connection violation. Non-blocking: EAGAIN/EOF are not
    /// trailing bytes.
    private static func hasTrailingBytes(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let r = recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        return r > 0
    }

    private static func writeFrame(_ fd: Int32, _ payload: Data) {
        var n = UInt32(payload.count).bigEndian
        _ = withUnsafeBytes(of: &n) { write(fd, $0.baseAddress, 4) }
        payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let w = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if w <= 0 { return }
                sent += w
            }
        }
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj,
                                     options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: - Dispatch

    private func err(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }
    private func okay(_ result: [String: Any]) -> [String: Any] {
        ["ok": true, "result": result]
    }

    /// Refuse a parameter this method does not know, instead of ignoring it.
    /// The rule and the incident behind it are documented on `ParamCheck`.
    private func rejectUnknownParams(_ p: [String: Any],
                                     _ known: Set<String>,
                                     _ method: String) -> [String: Any]? {
        let extras = ParamCheck.unknown(Set(p.keys), known: known)
        guard !extras.isEmpty else { return nil }
        return err("bad_request",
                   ParamCheck.message(method: method, got: extras,
                                      known: known))
    }

    /// Methods whose plane is FIXED (checked at dispatch). act.menu is absent
    /// because its plane depends on the item (keystroke=semantic / drag=tracking).
    static let methodPlane: [String: String] = [
        "mirror.act.open": "tracking",
        "mirror.act.window": "tracking",
        "mirror.act.scroll": "tracking",
    ]

    private func dispatch(method: String,
                          params: [String: Any]) -> [String: Any] {
        switch method {
        case "mirror.attach":   return attach(params)
        case "mirror.detach":   return detach(params)
        case "mirror.status":   return status()
        default: break
        }
        // Everything else needs a session.
        guard let sess = session,
              (params["session"] as? String) == sess.id else {
            return err("no_session", "mirror.attach first (or session mismatch)")
        }
        // Plane gate FIRST — an ungranted plane refuses regardless of whether
        // the named element exists, so an agent probing a plane it lacks gets
        // `plane_not_granted`, not a confusing `element_not_found`. Methods
        // whose plane is conditional (act.menu: keystroke vs drag) gate
        // in-method instead.
        if let plane = Self.methodPlane[method], !sess.planes.contains(plane) {
            return err("plane_not_granted", "\(method) needs the \(plane) plane")
        }
        switch method {
        case "mirror.scene":        return sceneMethod(params)
        case "mirror.find":         return find(params)
        case "mirror.shot":         return shot(params)
        case "mirror.wait":         return waitMethod(params)
        case "mirror.act.control":  return actControl(params, sess)
        case "mirror.act.menu":     return actMenu(params, sess)
        case "mirror.act.type":     return actType(params, sess)
        case "mirror.act.key":      return actKey(params, sess)
        case "mirror.act.open":     return actOpen(params, sess)
        case "mirror.act.window":   return actWindow(params, sess)
        case "mirror.act.scroll":   return actScroll(params, sess)
        case "mirror.app":          return appMethod(params, sess)
        default:
            return err("unknown_method", method)
        }
    }

    // MARK: - Lifecycle

    private func attach(_ p: [String: Any]) -> [String: Any] {
        let wanted = Set((p["planes"] as? [String]) ?? ["semantic"])
        let unknown = wanted.subtracting(["semantic", "tracking"])
        guard unknown.isEmpty else {
            return err("bad_request", "unknown planes: \(unknown.sorted())")
        }
        var granted = wanted
        if wanted.contains("tracking") && target.qmp == nil {
            granted.remove("tracking")   // plane_unavailable at act time
        }
        let id = UUID().uuidString
        session = Session(id: id, planes: granted)
        guard let scene = pollScene() else {
            session = nil
            return err("worker_unreachable", "first poll failed")
        }
        return okay([
            "session": id,
            "granted": granted.sorted(),
            "guest": ["machine": target.machine,
                      "frontApp": scene.menubar?.app ?? ""],
            "screen": ["w": scene.screen.w, "h": scene.screen.h],
            "irVersion": scene.version,
        ])
    }

    private func detach(_ p: [String: Any]) -> [String: Any] {
        session = nil
        lastScene = nil
        return okay(["detached": true])
    }

    private func status() -> [String: Any] {
        let start = DispatchTime.now()
        let alive = pollScene() != nil
        let ms = Double(DispatchTime.now().uptimeNanoseconds
                        - start.uptimeNanoseconds) / 1e6
        return okay([
            "service": "mirror",
            "session": session?.id ?? NSNull(),
            "worker": ["healthy": alive],
            "pollLatencyMs": (ms * 10).rounded() / 10,
            "islandBytesFetched": poller.islandBytesFetched,
            "actAvailability": [
                "semantic": true,
                "tracking": target.qmp != nil,
            ],
        ])
    }

    // MARK: - Perceive

    /// Resolve a window handle robustly. The IR id is `psn/title#occurrence`,
    /// and the occurrence index shifts when windows reorder between polls — so
    /// an exact match can miss a window an agent captured a moment ago. Fall
    /// back to the `psn/title` identity (drop the `#n`), which stays valid as
    /// long as that window is open.
    private func resolveWindow(_ handle: String, in s: Scene) -> Scene.Window? {
        if let exact = s.windows.first(where: { $0.id == handle }) {
            return exact
        }
        guard let hash = handle.lastIndex(of: "#") else { return nil }
        let identity = handle[..<hash]                       // psn/title
        return s.windows.first {
            $0.id.hasPrefix(identity + "#") || String($0.id.prefix(upTo:
                $0.id.lastIndex(of: "#") ?? $0.id.endIndex)) == identity
        }
    }

    private func pollScene(content: Bool = false,
                           islands: Bool = false) -> Scene? {
        poller.includeDisplay = content || islands
        poller.includeIslands = islands
        guard let s = try? poller.poll() else { return nil }
        lastScene = s
        return s
    }

    private func sceneMethod(_ p: [String: Any]) -> [String: Any] {
        let include = Set((p["include"] as? [String]) ?? [])
        let maxAge = (p["maxAgeMs"] as? NSNumber)?.doubleValue
        var scene: Scene?
        if let maxAge, let cached = lastScene,
           Date().timeIntervalSince1970 - cached.capturedAt < maxAge / 1000 {
            scene = cached
        } else {
            scene = pollScene(content: include.contains("content"),
                              islands: include.contains("islandMeta"))
        }
        guard var s = scene else {
            return err("worker_unreachable", "poll failed")
        }
        // Island pixels never ride the scene — metadata only.
        for i in s.windows.indices {
            s.windows[i].island = nil
        }
        guard let data = try? JSONEncoder().encode(s),
              var obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return err("act_failed", "scene encode failed")
        }
        if include.contains("islandMeta"), let cached = lastScene {
            obj["islands"] = cached.windows.compactMap { w -> [String: Any]? in
                guard let island = w.island else { return nil }
                return ["window": w.id, "width": island.width,
                        "height": island.height]
            }
        }
        if !include.contains("desktop") {
            obj["desktopItems"] = nil
        }
        // `irVersion` sits BESIDE `scene`, not inside it, and deliberately.
        //
        // The contract calls it the compatibility gate — "a consumer must
        // refuse an unknown major" — so it has to be readable WITHOUT decoding
        // the payload it gates. A gate nested inside the thing it guards makes
        // the consumer parse first and check second, which is backwards. It
        // also matches mirror.attach, where irVersion is already a top-level
        // result key: one `result["irVersion"]` code path covers both methods,
        // which is the only shape a literal reading of the contract can check.
        //
        // The scene body still carries its own `version` (Scene.version) as
        // the IR's self-stamp, and it is the same number: both are
        // `IR.version`, SceneBuilder stamps the body and this line copies it
        // out. The corpus pins the body stamp; the envelope key is the
        // contract. Frozen at v1 — docs/IR-V1.md.
        return okay(["scene": obj, "irVersion": s.version])
    }

    private func find(_ p: [String: Any]) -> [String: Any] {
        guard let kind = p["kind"] as? String else {
            return err("bad_request", "find needs kind")
        }
        guard let s = lastScene ?? pollScene() else {
            return err("worker_unreachable", "poll failed")
        }
        let name = (p["name"] as? String)?.lowercased()
        // Resolve withinWindow to the CURRENT window id, so a handle captured a
        // poll ago (before an occurrence-index shift) still scopes correctly.
        let within = (p["withinWindow"] as? String)
            .flatMap { resolveWindow($0, in: s)?.id }
        func matches(_ candidate: String) -> Bool {
            guard let name else { return true }
            return candidate.lowercased().contains(name)
        }
        var out: [[String: Any]] = []
        switch kind {
        case "window":
            for w in s.windows
            where !HitTester.isDesktopBackdrop(w) && matches(w.title) {
                out.append(["handle": w.id, "kind": "window", "name": w.title,
                            "rect": ["l": w.rect.l, "t": w.rect.t, "r": w.rect.r, "b": w.rect.b],
                            "front": w.front, "windowKind": w.kind ?? 0,
                            "actionable": true])
            }
        case "control":
            for w in s.windows where within == nil || w.id == within {
                for c in w.controls where c.visible && matches(c.title) {
                    var e: [String: Any] = [
                        "handle": c.ref, "kind": "control", "name": c.title,
                        "window": w.id, "actionable": c.enabled && !c.ref.isEmpty]
                    if let r = c.rect { e["rect"] = ["l": r.l, "t": r.t, "r": r.r, "b": r.b] }
                    out.append(e)
                }
            }
        case "menuItem":
            for m in s.menubar?.menus ?? [] {
                for item in m.items
                where !item.separator && matches(item.title) {
                    out.append(["handle": "\(m.title)>\(item.title)",
                                "kind": "menuItem", "name": item.title,
                                "menu": m.title, "cmd": item.cmd,
                                "actionable": true,
                                "mechanism": item.cmd.isEmpty
                                    ? "drag" : "keystroke"])
                }
            }
        case "windowItem":
            // A folder window's icons, addressable at last. `actionable` is
            // the honest part: an item the Finder has scrolled out of view has
            // a position and no click point, and saying so beats handing back
            // a coordinate that would land on whatever is there instead.
            for w in s.windows where within == nil || w.id == within {
                for item in w.items ?? [] where matches(item.name) {
                    let point = FinderItems.clickPoint(item, in: w)
                    var e: [String: Any] = [
                        "handle": "\(w.id)>\(item.name)", "kind": "windowItem",
                        "name": item.name, "window": w.id,
                        "itemKind": item.kind,
                        "rect": ["l": item.x, "t": item.y,
                                 "r": item.x + FinderItems.iconSize,
                                 "b": item.y + FinderItems.iconSize],
                        "visible": point != nil,
                        "actionable": point != nil]
                    if let type = item.type { e["type"] = type }
                    if let creator = item.creator { e["creator"] = creator }
                    out.append(e)
                }
            }
        case "desktopItem":
            for d in s.desktopItems ?? [] where matches(d.name) {
                out.append(["handle": d.name, "kind": "desktopItem",
                            "name": d.name, "itemKind": d.kind,
                            "rect": ["l": d.x, "t": d.y, "r": d.x + 32, "b": d.y + 32],
                            "actionable": d.placed])
            }
        case "scrollbar":
            for w in s.windows where within == nil || w.id == within {
                for c in w.controls where Scrollbar.isLive(c) {
                    var e: [String: Any] = [
                        "handle": c.ref, "kind": "scrollbar", "window": w.id,
                        // Orientation is explicit so an agent picks the axis
                        // without reasoning about geometry.
                        "orientation": Scrollbar.isVertical(c)
                            ? "vertical" : "horizontal",
                        "actionable": true]
                    if let r = c.rect {
                        e["rect"] = ["l": r.l, "t": r.t, "r": r.r, "b": r.b]
                    }
                    if let v = c.value { e["value"] = v }
                    if let mn = c.min { e["min"] = mn }
                    if let mx = c.max { e["max"] = mx }
                    out.append(e)
                }
            }
        default:
            return err("bad_request", "unknown kind \(kind)")
        }
        return okay(["matches": out])
    }

    private func shot(_ p: [String: Any]) -> [String: Any] {
        guard let s = pollScene(content: true, islands: true) else {
            return err("worker_unreachable", "poll failed")
        }
        let openMenu = (p["openMenu"] as? NSNumber)?.intValue
        var pngData: Data?
        var renderError: String?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                do { pngData = try RenderShot.png(scene: s, openMenu: openMenu) }
                catch { renderError = "\(error)" }
            }
        }
        guard let png = pngData else {
            return err("act_failed", "render failed: \(renderError ?? "?")")
        }
        return okay(["png": png.base64EncodedString(),
                     "bytes": png.count,
                     "width": s.screen.w, "height": s.screen.h])
    }

    // MARK: - Wait / settle predicates

    private func predicateMet(_ predicate: [String: Any],
                              in s: Scene) -> Bool {
        if let title = predicate["windowExists"] as? String,
           !s.windows.contains(where: { $0.title == title }) { return false }
        if let title = predicate["windowGone"] as? String,
           s.windows.contains(where: { $0.title == title }) { return false }
        if let wantDialog = predicate["dialogPresent"] as? Bool {
            let has = s.windows.contains { $0.kind == 2 }
            if has != wantDialog { return false }
        }
        if let app = predicate["frontApp"] as? String,
           s.menubar?.app != app { return false }
        if let cv = predicate["controlValue"] as? [String: Any],
           let ref = cv["ref"] as? String {
            let value = s.windows.lazy
                .flatMap(\.controls).first { $0.ref == ref }?.value
            guard let value else { return false }
            if let eq = (cv["equals"] as? NSNumber)?.intValue, value != eq {
                return false
            }
            if let mn = (cv["min"] as? NSNumber)?.intValue, value < mn {
                return false
            }
            if let mx = (cv["max"] as? NSNumber)?.intValue, value > mx {
                return false
            }
        }
        return true
    }

    /// Poll until the predicate holds or the deadline passes.
    private func settle(_ predicate: [String: Any],
                        timeoutMs: Double) -> (met: Bool, elapsedMs: Int) {
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < timeoutMs {
            if let s = pollScene(), predicateMet(predicate, in: s) {
                return (true, Int(Date().timeIntervalSince(start) * 1000))
            }
            usleep(350_000)
        }
        return (false, Int(timeoutMs))
    }

    private func waitMethod(_ p: [String: Any]) -> [String: Any] {
        guard let predicate = p["until"] as? [String: Any] else {
            return err("bad_request", "wait needs until: predicate")
        }
        let timeout = (p["timeoutMs"] as? NSNumber)?.doubleValue ?? 5000
        let r = settle(predicate, timeoutMs: timeout)
        return okay(["met": r.met, "elapsedMs": r.elapsedMs])
    }

    // MARK: - Acts

    /// Shared act tail: dispatch the actions, then run the optional settle.
    private func performAct(_ actions: [MirrorAction],
                            mechanism: String,
                            plane: String,
                            sess: Session,
                            params: [String: Any]) -> [String: Any] {
        guard sess.planes.contains(plane) else {
            return err("plane_not_granted",
                       "\(mechanism) needs the \(plane) plane")
        }
        if plane == "tracking" && target.qmp == nil {
            return err("plane_unavailable", "no QMP plane on this target")
        }
        guard !actions.isEmpty else {
            return err("act_failed", "element is inert (no actions resolved)")
        }
        do {
            try dispatcher.perform(actions)
        } catch {
            return err("act_failed", "\(error)")
        }
        var result: [String: Any] = [
            "performed": true, "mechanism": mechanism,
            "availability": plane == "tracking" ? "emulator" : "metal-safe"]
        if let predicate = params["settle"] as? [String: Any] {
            let timeout = (params["settleTimeoutMs"] as? NSNumber)?
                .doubleValue ?? 5000
            let r = settle(predicate, timeoutMs: timeout)
            result["settle"] = ["met": r.met, "elapsedMs": r.elapsedMs]
        }
        return okay(result)
    }

    private func actControl(_ p: [String: Any],
                            _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["count", "mods", "ref"],
                                         "mirror.act.control") { return bad }
        guard let ref = p["ref"] as? String else {
            return err("bad_request", "act.control needs ref")
        }
        guard let s = lastScene ?? pollScene(),
              let ctl = s.windows.lazy.flatMap(\.controls)
                .first(where: { $0.ref == ref }) else {
            return err("element_not_found", "no control with that ref")
        }
        let count = (p["count"] as? NSNumber)?.intValue ?? 1
        let mods = (p["mods"] as? NSNumber)?.intValue ?? 0
        return performAct(
            [.axdo(ref: ctl.ref, count: count, mods: mods, text: nil)],
            mechanism: "axdo", plane: "semantic", sess: sess, params: p)
    }

    private func actMenu(_ p: [String: Any],
                         _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["item", "menu"],
                                         "mirror.act.menu") { return bad }
        guard let menuTitle = p["menu"] as? String,
              let itemTitle = p["item"] as? String else {
            return err("bad_request", "act.menu needs menu + item")
        }
        guard let s = pollScene(),
              let menu = s.menubar?.menus
                .first(where: { $0.title == menuTitle }),
              let item = menu.items
                .first(where: { $0.title.hasPrefix(itemTitle) }) else {
            return err("element_not_found", "\(menuTitle)>\(itemTitle)")
        }
        if item.cmd.isEmpty {
            // Shortcut-less items go through the Portal: the guest's in-process
            // agent answers the application's own MenuSelect with this item, so
            // the app runs its real command handler. No menu drawn, no tracking
            // loop, no QMP — so this is metal-safe rather than emulator-only.
            //
            // This replaces the opt-in `allowDrag` path, which was experimental
            // for good reason: it was open-loop through mouse acceleration AND
            // aimed at rows computed from a uniform-16px assumption the guest
            // has since disproved (separators are 6px). `allowDrag` is now
            // ignored; there is no longer a reason to ask for the worse
            // mechanism.
            return performAct(ActionModel.menuSelect(menu: menu, item: item),
                              mechanism: "portal-menuselect", plane: "semantic",
                              sess: sess, params: p)
        }
        return performAct(ActionModel.menuSelect(menu: menu, item: item),
                          mechanism: "keystroke", plane: "semantic",
                          sess: sess, params: p)
    }

    private func actType(_ p: [String: Any],
                         _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["text"],
                                         "mirror.act.type") { return bad }
        guard let text = p["text"] as? String else {
            return err("bad_request", "act.type needs text")
        }
        return performAct([.type(text: text)], mechanism: "type",
                          plane: "semantic", sess: sess, params: p)
    }

    /// Named keys, classic virtual codes + event chars.
    static let namedKeys: [String: (code: Int, char: Int)] = [
        "return": (36, 13), "escape": (53, 27), "tab": (48, 9),
        "space": (49, 32), "delete": (51, 8),
        "left": (123, 28), "right": (124, 29), "up": (126, 30),
        "down": (125, 31),
        "pageUp": (116, 11), "pageDown": (121, 12),
        "home": (115, 1), "end": (119, 4),
    ]

    private func actKey(_ p: [String: Any],
                        _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["key", "mods"],
                                         "mirror.act.key") { return bad }
        var code = 0, char = 0
        if let key = p["key"] as? String {
            if let named = Self.namedKeys[key] {
                (code, char) = named
            } else if key.count == 1, let ch = key.lowercased().first,
                      let ascii = ch.asciiValue {
                code = ActionModel.keycodes[ch] ?? 0
                char = Int(ascii)
            } else {
                return err("bad_request", "unknown key \(key)")
            }
        } else {
            return err("bad_request", "act.key needs key")
        }
        // Same fail-open shape one level down: `mods: "cmd"` (a bare string, not
        // a list) fails the cast and silently means "no modifiers". Refuse it.
        if p["mods"] != nil, p["mods"] as? [String] == nil {
            return err("bad_request",
                       "act.key: mods must be a list of strings")
        }
        var mods = 0
        for m in (p["mods"] as? [String]) ?? [] {
            switch m {
            case "cmd": mods |= 256
            case "shift": mods |= 512
            case "option": mods |= 2048
            case "control": mods |= 4096
            default: return err("bad_request", "unknown mod \(m)")
            }
        }
        return performAct([.key(code: code, char: char, mods: mods)],
                          mechanism: "keystroke", plane: "semantic",
                          sess: sess, params: p)
    }

    private func actOpen(_ p: [String: Any],
                         _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(
                p, ["desktopItem", "windowItem", "window", "preferSemantic"],
                "mirror.act.open") { return bad }
        if p["windowItem"] != nil {
            return actOpenWindowItem(p, sess)
        }
        guard let name = p["desktopItem"] as? String else {
            return err("bad_request",
                       "act.open needs desktopItem or windowItem")
        }
        guard let s = pollScene(),
              let item = (s.desktopItems ?? [])
                .first(where: { $0.name == name }) else {
            return err("element_not_found", "no desktop item \(name)")
        }
        if (p["preferSemantic"] as? Bool) == true {
            // AE odoc by path — metal-safe, no cursor.
            do {
                _ = try poller.wire.request("apple-event", [
                    "event": "odoc",
                    "path": "Macintosh HD:Desktop Folder:\(name)"])
                var result: [String: Any] = ["performed": true,
                                             "mechanism": "apple-event",
                                             "availability": "metal-safe"]
                if let predicate = p["settle"] as? [String: Any] {
                    let r = settle(predicate, timeoutMs: 8000)
                    result["settle"] = ["met": r.met, "elapsedMs": r.elapsedMs]
                }
                return okay(result)
            } catch {
                return err("act_failed", "odoc: \(error)")
            }
        }
        let c = (x: item.x + 16, y: item.y + 16)
        let hit = HitTester.hitTest(s, x: c.x, y: c.y)
        guard case .desktop = hit else {
            return err("element_stale",
                       "icon is occluded by a window — raise/move it first, "
                       + "or preferSemantic: true")
        }
        return performAct(ActionModel.click(on: hit, count: 2),
                          mechanism: "double-click", plane: "tracking",
                          sess: sess, params: p)
    }

    /// Open an icon inside a Finder folder window — the half of `act.open` the
    /// contract has specified since day one and could not implement, because
    /// there was nothing in the scene to name.
    ///
    /// The item is resolved by name within a window; `window` disambiguates
    /// when several windows hold the same name. Positions are re-read from the
    /// Finder before the point is computed: a cached position is fine to draw
    /// with and not fine to AIM with, since a scroll moves every one of them.
    private func actOpenWindowItem(_ p: [String: Any],
                                   _ sess: Session) -> [String: Any] {
        guard let name = p["windowItem"] as? String else {
            return err("bad_request", "act.open: windowItem must be a string")
        }
        poller.refreshWindowItems()
        guard let s = pollScene() else {
            return err("worker_unreachable", "poll failed")
        }
        let scoped = (p["window"] as? String).flatMap { resolveWindow($0, in: s) }
        let candidates = s.windows
            .filter { scoped == nil || $0.id == scoped!.id }
            .compactMap { win -> (Scene.Window, Scene.DesktopItem)? in
                (win.items ?? []).first { $0.name == name }.map { (win, $0) }
            }
        guard let (win, item) = candidates.first else {
            return err("element_not_found",
                       "no item \(name) in any open Finder window")
        }
        guard candidates.count == 1 else {
            return err("element_ambiguous",
                       "\(candidates.count) open windows hold an item named "
                       + "\(name) — pass `window` to choose one")
        }
        if (p["preferSemantic"] as? Bool) == true {
            // AE odoc by path — metal-safe, no cursor, no double-click. The
            // path is the FINDER's answer for that window (`item of window`),
            // never a search for the name (a whole-disk Finder search wedged a
            // real machine for ~12 minutes; lab finding 2026-07-05).
            guard let folder = poller.finderPaths[win.title] else {
                return err("element_stale",
                           "the Finder did not name a folder for window "
                           + "\(win.title)")
            }
            do {
                _ = try poller.wire.request("apple-event", [
                    "event": "odoc", "path": "\(folder)\(name)"])
                var result: [String: Any] = ["performed": true,
                                             "mechanism": "apple-event",
                                             "availability": "metal-safe"]
                if let predicate = p["settle"] as? [String: Any] {
                    let r = settle(predicate, timeoutMs: 8000)
                    result["settle"] = ["met": r.met, "elapsedMs": r.elapsedMs]
                }
                return okay(result)
            } catch {
                return err("act_failed", "odoc: \(error)")
            }
        }
        guard let point = FinderItems.clickPoint(item, in: win) else {
            return err("element_stale",
                       "\(name) is scrolled out of view — scroll to it first, "
                       + "or preferSemantic: true")
        }
        // Re-hit-test the computed point: it must resolve back to THIS item.
        // A point that lands on another window (or on this item's neighbour)
        // means the scene moved under us, and clicking anyway is how the wrong
        // file gets opened.
        let hit = HitTester.hitTest(s, x: point.x, y: point.y)
        guard case .windowItem(_, let hitName, _, _) = hit, hitName == name else {
            return err("element_stale",
                       "the point for \(name) resolves to \(hit) — the window "
                       + "is occluded or moved; raise it, or preferSemantic: true")
        }
        return performAct(ActionModel.click(on: hit, count: 2),
                          mechanism: "double-click", plane: "tracking",
                          sess: sess, params: p)
    }

    private func actWindow(_ p: [String: Any],
                           _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["dx", "dy", "op", "window"],
                                         "mirror.act.window") { return bad }
        guard let handle = p["window"] as? String,
              let op = p["op"] as? String else {
            return err("bad_request", "act.window needs window + op")
        }
        guard let s = pollScene(),
              let w = resolveWindow(handle, in: s) else {
            return err("element_not_found", "no window \(handle)")
        }
        switch op {
        case "raise":
            let grab = (x: (w.rect.l + w.rect.r) / 2, y: w.rect.t + 5)
            let hit = HitTester.hitTest(s, x: grab.x, y: grab.y)
            return performAct(ActionModel.click(on: hit),
                              mechanism: "raise-click", plane: "tracking",
                              sess: sess, params: p)
        case "close", "zoom", "collapse":
            let kind: HitTester.WidgetKind = op == "close" ? .close
                : op == "zoom" ? .zoom : .collapse
            guard let box = WindowChrome.widgetBox(w, kind) else {
                return err("element_not_found", "window has no \(op) widget")
            }
            let c = WindowChrome.center(box)
            return performAct(
                ActionModel.click(on: HitTester.hitTest(s, x: c.x, y: c.y)),
                mechanism: "widget", plane: "tracking", sess: sess, params: p)
        case "move":
            let dx = (p["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (p["dy"] as? NSNumber)?.intValue ?? 0
            let grab = (x: (w.rect.l + w.rect.r) / 2, y: w.rect.t + 5)
            return performAct(
                ActionModel.titlebarDrag(from: grab,
                                         to: (grab.x + dx, grab.y + dy)),
                mechanism: "drag", plane: "tracking", sess: sess, params: p)
        case "resize":
            let dx = (p["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (p["dy"] as? NSNumber)?.intValue ?? 0
            let grab = (x: w.rect.r - 7, y: w.rect.b - 7)
            return performAct(
                ActionModel.growDrag(from: grab,
                                     to: (grab.x + dx, grab.y + dy)),
                mechanism: "drag", plane: "tracking", sess: sess, params: p)
        default:
            return err("bad_request", "unknown op \(op)")
        }
    }

    private func actScroll(_ p: [String: Any],
                           _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["by", "scrollbar", "to", "window"],
                                         "mirror.act.scroll") { return bad }
        guard let handle = p["window"] as? String else {
            return err("bad_request", "act.scroll needs window")
        }
        guard let s = pollScene(),
              let w = resolveWindow(handle, in: s) else {
            return err("element_not_found", "no window \(handle)")
        }
        // A window can have BOTH a vertical and a horizontal bar. Target the
        // one the agent named (its ref from find), else default to the
        // VERTICAL bar (the common scroll axis) rather than an arbitrary first.
        let liveBars = w.controls.filter(Scrollbar.isLive)
        let bar: Scene.Control
        if let ref = p["scrollbar"] as? String {
            guard let named = liveBars.first(where: { $0.ref == ref }) else {
                return err("element_not_found", "no live scrollbar with that ref")
            }
            bar = named
        } else if let vertical = liveBars.first(where: Scrollbar.isVertical) {
            bar = vertical
        } else if let any = liveBars.first {
            bar = any
        } else {
            return err("element_not_found",
                       "window has no live scrollbar (nothing to scroll?)")
        }
        let origin = (x: w.rect.l, y: w.rect.t + HitTester.titlebar)
        func global(_ pt: (x: Int, y: Int)) -> (x: Int, y: Int) {
            (pt.x + origin.x, pt.y + origin.y)
        }
        if let to = (p["to"] as? NSNumber)?.intValue {
            guard let from = Scrollbar.center(bar, .thumb),
                  let dest = Scrollbar.thumbTarget(bar, value: to) else {
                return err("act_failed", "no draggable thumb")
            }
            return performAct(
                ActionModel.thumbDrag(from: global(from), to: global(dest)),
                mechanism: "thumb-drag", plane: "tracking",
                sess: sess, params: p)
        }
        if let by = p["by"] as? [String: Any] {
            let lines = (by["lines"] as? NSNumber)?.intValue
            let pages = (by["pages"] as? NSNumber)?.intValue
            let n = lines ?? pages ?? 0
            guard n != 0 else { return err("bad_request", "by needs ±n") }
            let part: Scrollbar.Part = lines != nil
                ? (n > 0 ? .lineDown : .lineUp)
                : (n > 0 ? .pageDown : .pageUp)
            guard let c = Scrollbar.center(bar, part) else {
                return err("act_failed",
                           "no \(part.rawValue) region (already at the end?)")
            }
            let g = global(c)
            let clicks = Array(
                repeating: MirrorAction.qmpClick(x: g.x, y: g.y),
                count: min(abs(n), 8))
            return performAct(clicks, mechanism: part.rawValue,
                              plane: "tracking", sess: sess, params: p)
        }
        return err("bad_request", "act.scroll needs by: or to:")
    }

    private func appMethod(_ p: [String: Any],
                           _ sess: Session) -> [String: Any] {
        if let bad = rejectUnknownParams(p, ["includeBackground", "name", "op", "path", "psn"],
                                         "mirror.app") { return bad }
        guard let op = p["op"] as? String else {
            return err("bad_request", "app needs op")
        }
        switch op {
        case "list":
            // The one NON-mutating op on this method: pure enumeration, no
            // wire act, so it needs no plane. Polled FRESH rather than served
            // from lastScene — the call after a `launch` is precisely the one
            // that must see the new app, and an axtree poll is ~2 ms.
            guard let s = pollScene() else {
                return err("worker_unreachable", "poll failed")
            }
            let includeBackground = (p["includeBackground"] as? Bool) ?? false
            let rows = AppList.rows(s, includeBackground: includeBackground)
                .map { row -> [String: Any] in
                    var e: [String: Any] = [
                        "psn": row.psn, "name": row.name, "front": row.front,
                        "background": row.background, "windows": row.windows]
                    if let err = row.error { e["error"] = err }
                    return e
                }
            return okay(["apps": rows,
                         "includedBackground": includeBackground])
        default:
            break
        }
        // Everything below MUTATES the guest. The contract declares
        // mirror.app `plane = "semantic"`, but nothing enforced it: these ops
        // call wire.request directly instead of going through performAct
        // (which is where the plane check lives), so a session that asked for
        // NO planes could still activate and quit apps — measured 2026-07-31,
        // `planes: []` granted nothing and `op:"activate"` still performed
        // while mirror.act.key correctly refused. Gate them for real, at the
        // same point the fixed-plane methods gate, so the declaration is true.
        //
        // `list` is deliberately above this line: it is the one non-mutating
        // op on a mutating method, so it needs no plane.
        guard sess.planes.contains("semantic") else {
            return err("plane_not_granted", "app \(op) needs the semantic plane")
        }
        switch op {
        case "launch":
            guard let path = p["path"] as? String else {
                return err("bad_request", "launch needs path")
            }
            do {
                _ = try poller.wire.request("launch", ["path": path])
                var result: [String: Any] = ["performed": true,
                                             "mechanism": "launch",
                                             "availability": "metal-safe"]
                if let predicate = p["settle"] as? [String: Any] {
                    let r = settle(predicate, timeoutMs: 10000)
                    result["settle"] = ["met": r.met, "elapsedMs": r.elapsedMs]
                }
                return okay(result)
            } catch { return err("act_failed", "launch: \(error)") }
        case "activate", "quit":
            var psn = p["psn"] as? String
            if psn == nil, let name = p["name"] as? String,
               let s = lastScene ?? pollScene() {
                psn = s.apps.first { $0.name == name }?.psn
            }
            guard let psn, psn.contains(".") else {
                return err("element_not_found", "no app psn (pass name or psn)")
            }
            let parts = psn.split(separator: ".")
            let hi = Int(parts[0]) ?? 0, lo = Int(parts[1]) ?? 0
            do {
                if op == "activate" {
                    _ = try poller.wire.request(
                        "activate", ["serialHi": hi, "serialLo": lo])
                } else {
                    _ = try poller.wire.request(
                        "apple-event",
                        ["event": "quit", "serialHi": hi, "serialLo": lo])
                }
                var result: [String: Any] = ["performed": true,
                                             "mechanism": op,
                                             "availability": "metal-safe"]
                if let predicate = p["settle"] as? [String: Any] {
                    let r = settle(predicate, timeoutMs: 8000)
                    result["settle"] = ["met": r.met, "elapsedMs": r.elapsedMs]
                }
                return okay(result)
            } catch { return err("act_failed", "\(op): \(error)") }
        default:
            return err("bad_request", "unknown op \(op)")
        }
    }
}
