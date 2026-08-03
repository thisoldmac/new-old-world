import Foundation
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration

/// **Mirror's live view, driven by NOW's own wire.**
///
/// The one object that makes `LiveMirrorView` — Mirror's gesture routing,
/// menu tracking, drag modes and double-click timing — run against a
/// Macintosh NOW is connected to. It conforms to `MirrorSceneSource` and
/// owns three things: a poll, a dispatch, and a sentence for a person.
///
/// ## Why this is not the archived port
///
/// `archive/mirror-port-2026-08-01` had the same shape and could not
/// click. Three things were missing under it, all fixed before this file
/// was written and all of them measurable:
///
/// - controls reached the consumer in **global** coordinates where the IR
///   is content-relative, so a click resolved to a neighbour;
/// - `windows[].rect` was the content region where the IR wants the box,
///   so everything was one title bar out;
/// - `Scene.Window` dropped the guest's `ref`, so no window act could be
///   addressed at all.
///
/// A fourth was not a defect but a mismatch: `ActionModel` resolved a
/// scroll arrow to a QMP press, which no PowerBook has. `ActionPlanes`
/// is why this class reports `.residentActPlane` and gets a Control
/// Manager part instead.
///
/// ## The poll is sequential, and that is not a detail
///
/// The contract allows ONE bulk transfer at a time and the guest enforces
/// it, so a free-running timer would spend its failures on "a transfer is
/// already in progress" — noise that reads exactly like a broken guest.
/// The next request is armed when the last one lands.
@MainActor
final class NOWMirrorSource: ObservableObject, MirrorSceneSource {

    @Published private(set) var scene: MirrorKit.Scene?
    @Published private(set) var status: String = "not started"

    /// NOW addresses elements by reference and has no positional click
    /// verb — `contract/asyncapi.yaml` states that omission deliberately.
    /// Both halves matter: the first is what makes this mirror drivable on
    /// metal, the second is what makes a click on bare desktop a named
    /// refusal instead of a silence.
    nonisolated var planes: ActionPlanes { .residentActPlane }

    private let listener: GuestListener
    private let act: AgentIntegrationActControl
    private let interval: TimeInterval
    private var running = false
    private var pending = false

    /// Icons, per container, and the layout they were read for.
    ///
    /// **Why the host fetches these at all.** NOW's scene walk reads the
    /// Toolbox's own structures - windows, controls, menus - and a Finder
    /// icon is none of those. It is a file the Finder draws, and the
    /// Finder is the only thing that knows where. So they come from the
    /// Finder, by AppleScript, and are merged into the scene here.
    ///
    /// Cached against `FinderItems.layoutKey`, which changes when a
    /// window moves, resizes or SCROLLS - three Apple events per
    /// container is cheap (0.3s for 33 items, measured) but not cheap
    /// enough to spend on every frame of a mirror.
    private var icons: [String: [MirrorKit.Scene.DesktopItem]] = [:]
    private var iconLayout: String = ""
    private var fetchingIcons = false

    /// The IR major this host can read. Checked against the envelope
    /// BEFORE the body is parsed, which is the order `NOWSceneCodec`
    /// exists to enforce — a decoder that parses first has already
    /// trusted a document it has not agreed to.
    private static let readableIRMajor = 1

    init(listener: GuestListener,
         act: AgentIntegrationActControl,
         interval: TimeInterval = 0.75) {
        self.listener = listener
        self.act = act
        self.interval = interval
    }

    // MARK: - The poll

    func start() {
        guard !running else { return }
        running = true
        status = "asking for a scene…"
        poll()
    }

    func stop() {
        running = false
        status = "stopped"
    }

    private func poll() {
        guard running, !pending else { return }
        /* The lane is shared with streams, captures and file transfers.
           Asking while one holds it earns a refusal that says nothing
           about the Macintosh, so we wait a beat instead of spending a
           request on it. */
        guard !listener.isScenePending else { return rearm() }
        pending = true
        listener.requestScene { [weak self] result in
            guard let self else { return }
            self.pending = false
            switch result {
            case .success(let delivery):
                self.accept(delivery)
            case .failure(let failure):
                /* The last scene STANDS. A poll that failed is a gap in
                   knowledge, not evidence the windows went away, and
                   blanking the mirror on one is how a momentary busy lane
                   looks like a crash. */
                self.status = failure.refusedByGuest
                    ? "the Mac declined: \(failure.message)"
                    : failure.message
            }
            self.rearm()
        }
    }

    private func accept(_ delivery: GuestListener.SceneDelivery) {
        guard delivery.irVersion == Self.readableIRMajor else {
            status = "this Mac speaks scene IR v\(delivery.irVersion); "
                + "this build reads v\(Self.readableIRMajor)"
            return
        }
        do {
            var decoded = try JSONDecoder().decode(
                MirrorKit.Scene.self, from: delivery.document)
            decoded = withIcons(decoded)
            scene = decoded
            refreshIconsIfStale(decoded)
            status = "\(decoded.windows.count) windows · walk "
                + "\(delivery.walkMs.map { "\($0)ms" } ?? "?") · transfer "
                + "\(delivery.transferMs)ms"
        } catch {
            /* Named rather than swallowed: this is the seam that has cost
               this project the most, and a mirror that silently keeps
               drawing a stale scene while the producer emits something
               unreadable is the failure wearing its best clothes. */
            status = "the scene did not decode as IR v1: \(error)"
        }
    }

    private func rearm() {
        guard running else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds:
                UInt64(self.interval * 1_000_000_000))
            self.poll()
        }
    }

    // MARK: - Icons

    /// The scene as the guest described it, plus the icons the Finder
    /// knows about. Absence stays absence: a container never fetched
    /// carries no `items` key rather than an empty one, because "no
    /// icons here" and "nobody looked" are different facts.
    private func withIcons(_ scene: MirrorKit.Scene) -> MirrorKit.Scene {
        var out = scene
        if let desktop = icons[Self.desktopKey] { out.desktopItems = desktop }
        out.windows = out.windows.map { win in
            guard FinderItems.isFolderWindow(win),
                  let items = icons[win.title] else { return win }
            var w = win
            w.items = items
            return w
        }
        return out
    }

    private static let desktopKey = "\u{0}desktop"

    private func refreshIconsIfStale(_ scene: MirrorKit.Scene) {
        let folders = scene.windows.filter(FinderItems.isFolderWindow)
        let key = folders.map(FinderItems.layoutKey).joined(separator: "|")
        guard key != iconLayout, !fetchingIcons else { return }
        fetchingIcons = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var fresh: [String: [MirrorKit.Scene.DesktopItem]] = [:]
            if let d = await self.readIcons(container: "desktop") {
                fresh[Self.desktopKey] = d
            }
            for win in folders {
                let quoted = win.title.replacingOccurrences(of: "\"",
                                                            with: "\\\"")
                if let items = await self.readIcons(
                    container: "window \"\(quoted)\"") {
                    fresh[win.title] = items
                }
            }
            self.icons = fresh
            self.iconLayout = key
            self.fetchingIcons = false
        }
    }

    /// Three vectorised Apple events, not three per icon. Asking for
    /// `name of every item` costs one event; asking each item its name
    /// costs one each, and on a cooperatively-scheduled Mac that is the
    /// difference between a third of a second and a stall a person sees.
    private func readIcons(container: String)
        async -> [MirrorKit.Scene.DesktopItem]? {
        let source = """
        tell application "Finder"
        set ns to name of every item of \(container)
        set ps to position of every item of \(container)
        set ks to kind of every item of \(container)
        end tell
        set out to ""
        repeat with i from 1 to (count ns)
        set p to item i of ps
        set out to out & (item i of ns) & tab & (item 1 of p) & tab & \
        (item 2 of p) & tab & (item i of ks) & return
        end repeat
        return out
        """
        guard let text = await runReadingOutput(
            "script", ["source": .text(source)]) else {
            return nil
        }
        return Self.parseIcons(text)
    }

    /// OSADoScript renders its result in SOURCE form, so a text result
    /// arrives wrapped in quotes and its lines are separated by CR -
    /// classic AppleScript's terminator, and the reason `linefeed` is not
    /// used to build it (that identifier does not exist in OS 9's
    /// AppleScript and fails the whole script with osaErr -1753).
    static func parseIcons(_ raw: String) -> [MirrorKit.Scene.DesktopItem] {
        var text = raw
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        var out: [MirrorKit.Scene.DesktopItem] = []
        for line in text.components(separatedBy: CharacterSet.newlines)
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, let x = Int(f[1]), let y = Int(f[2]) else {
                continue
            }
            let kind = f[3].lowercased()
            var item = MirrorKit.Scene.DesktopItem(
                name: f[0],
                kind: kind.contains("folder") ? "folder"
                    : kind.contains("disk") ? "disk"
                    : kind.contains("application") ? "application" : "file",
                type: nil, creator: nil,
                x: x, y: y, placed: true,
                alias: kind.contains("alias"), invisible: false)
            item.name = f[0]
            out.append(item)
        }
        return out
    }

    // MARK: - The dispatch

    func note(_ message: String) {
        guard !message.isEmpty else { return }
        status = message
    }

    /// **The object-first entry point.** A person acted on a THING; this
    /// decides what that means and sends it.
    ///
    /// It overrides the protocol's default rather than using it, for one
    /// reason: the default expresses a plan in the action vocabulary, and
    /// no action case can name a file. `finderSelect` and `finderOpen`
    /// are the whole argument for objects, and they are served here.
    func perform(_ interaction: Interaction) {
        let plan = InteractionPolicy.plan(for: interaction, planes: planes)
        switch plan {
        case .nothing(let why):
            /* Not a failure, and not silence either. A click on something
               inert still has to LOOK like it was seen, or a person
               concludes the mirror is dead. */
            status = why
        case .unsupported(let why):
            status = "\(InteractionBridge.label(for: interaction)): \(why)"
        default:
            let label = InteractionBridge.label(for: interaction)
            status = label + "…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let complaint = await self.serve(plan) {
                    self.status = "\(label) — \(complaint)"
                } else {
                    self.status = label
                }
                self.poll()                  // show the effect now
            }
        }
    }

    /// Kept for the action vocabulary, which the agent-shaped half of
    /// MirrorKit still speaks. Nothing in NOW's own path uses it.
    func perform(_ actions: [MirrorAction], label: String) {
        guard !actions.isEmpty else { return }
        for action in actions {
            let verdict = ActionModel.availability(action, planes: planes)
            guard verdict == .available else {
                status = "\(label): \(sentence(for: verdict))"
                return
            }
        }
        status = label + "…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            for action in actions {
                if let outcome = await self.send(action) {
                    self.status = "\(label) — \(outcome)"
                    return
                }
            }
            self.status = label
            self.poll()
        }
    }

    // MARK: - Serving a plan

    /// Returns nil when it went, or a sentence for a person when it did
    /// not. Every branch answers one or the other; none stays quiet.
    private func serve(_ plan: InteractionPlan) async -> String? {
        switch plan {
        case .controlPart(let ref, let part, _):
            return reading(await act.controlAct(.init(element: ref,
                                                      part: part)))

        case .windowAct(let ref, let what):
            return reading(await act.windowAct(Self.request(ref, what)))

        case .menuCommand(let menuID, let index, let left):
            return reading(await act.menuAct(
                .init(menu: menuID, item: index,
                      titleLeft: left, process: nil)))

        case .keystroke(let code, let char, let mods):
            return reading(await act.key(
                .init(code: code, char: char, mods: mods)))

        case .setText(let ref, let text):
            return reading(await act.setElementText(element: ref, text: text))

        case .typeText(let text):
            /* NOW has no `type` verb: text reaches the guest as the
               keystrokes it is made of, which is also what a real
               keyboard would have sent. */
            for ch in text.unicodeScalars {
                let code = ActionModel.keycodes[
                    Character(String(ch).lowercased())] ?? 0
                if let complaint = reading(await act.key(
                    .init(code: code, char: Int(ch.value), mods: 0))) {
                    return complaint
                }
            }
            return nil

        case .activateApp(let psn):
            return await activate(psn)

        case .finderSelect(let item, let container):
            return await finder(
                "select \(reference(item, in: container))")
        case .finderOpen(let item, let container):
            return await finder(
                "open \(reference(item, in: container))")
        case .finderDeselect:
            return await finder("select {}")

        case .nothing, .unsupported:
            return nil                       // handled before we get here
        }
    }

    /// **How an icon is reached without a positional click.**
    ///
    /// The Finder addresses its own items by name, and NOW can carry an
    /// AppleScript, so an object with a name is actionable on a guest
    /// whose contract has no click-at-a-point verb at all. This is the
    /// case the object model exists for.
    private func reference(
        _ item: String,
        in container: InteractionPlan.FinderContainer) -> String {
        let escaped = item.replacingOccurrences(of: "\"", with: "\\\"")
        switch container {
        case .desktop:
            return "item \"\(escaped)\" of desktop"
        case .window(let title):
            let w = title.replacingOccurrences(of: "\"", with: "\\\"")
            /* `item "X" of window "T"` and NOT `target of window "T"`.
               Measured on OS 9.1's Finder, 2026-08-02: the target form
               fails with osaErr -1753 on both `window` and `Finder
               window`, while resolving the item inside the window
               directly answers with its full path. Naming the WINDOW
               rather than a path is also what stays true when the same
               folder is open twice. */
            return "item \"\(escaped)\" of window \"\(w)\""
        }
    }

    private func finder(_ phrase: String) async -> String? {
        let source = "tell application \"Finder\" to \(phrase)"
        return await run("script", ["source": .text(source)])
    }

    private func activate(_ psn: String) async -> String? {
        let parts = psn.split(separator: ".")
        guard parts.count == 2, let hi = Int(parts[0]), let lo = Int(parts[1])
        else { return "that process reference is not a PSN" }
        /* NUMBERS. As strings these crossed as "0"-parsing zeros and
           `activate` fronted process 0.0 - see CommandArg. */
        return await run("activate", ["serialHi": .number(hi),
                                      "serialLo": .number(lo)])
    }

    /// Runs a verb and returns one labelled row from its own reply, or
    /// nil when the guest refused. Used for `script`, whose ANSWER is the
    /// point rather than its dispatch.
    private func runReadingOutput(_ verb: String,
                                  _ args: [String: CommandArg],
                                  row: String = "output") async -> String? {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, typed: args) { result in
                guard result.ok else {
                    return continuation.resume(returning: nil)
                }
                var value: String?
                for cells in result.output?[verb] ?? [] where cells.first == row {
                    value = cells.count > 1 ? cells.last : ""
                }
                continuation.resume(returning: value)
            }
        }
    }

    /// The verbs with no typed projection on this host yet. Reads the
    /// guest's own reply rather than assuming a send is a success.
    private func run(_ verb: String,
                     _ args: [String: CommandArg]) async -> String? {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, typed: args) { result in
                if result.ok { return continuation.resume(returning: nil) }
                let error = result.error
                continuation.resume(returning:
                    "\(error?.code ?? "error"): \(error?.message ?? "")")
            }
        }
    }

    /// Sends one act. Returns nil when it was dispatched, or a sentence
    /// for a person when it was not.
    private func send(_ action: MirrorAction) async -> String? {
        switch action {
        case .controlPart(let ref, let part, _):
            return reading(await act.controlAct(
                .init(element: ref, part: part)))

        case .axdo(let ref, _, _, let text):
            if let text {
                return reading(await act.setElementText(element: ref,
                                                        text: text))
            }
            /* A plain control click is part 10, the Control Manager's
               button part - the same number `ctlact` names first in its
               own refusal text. */
            return reading(await act.controlAct(.init(element: ref,
                                                      part: 10)))

        case .windowAct(let ref, let what):
            return reading(await act.windowAct(Self.request(ref, what)))

        case .menuInvoke(let menuID, let itemIndex, let titleLeft):
            return reading(await act.menuAct(
                .init(menu: menuID, item: itemIndex,
                      titleLeft: titleLeft, process: nil)))

        case .key(let code, let char, let mods):
            return reading(await act.key(
                .init(code: code, char: char, mods: mods)))

        default:
            /* Everything left is an act this driver declared it cannot
               serve, so `availability` refused it above and we never
               arrive. Stated anyway: a default that quietly returned nil
               would report a click as dispatched if that guard ever
               moved. */
            return "no lane on this host carries \(action)"
        }
    }

    /// Internal and static so it can be tested without a machine: this
    /// is the whole translation from Mirror's vocabulary to NOW's window
    /// act, and it is exactly the kind of per-action key rule that
    /// `AgentIntegrationWindowActRequest.geometryKeys` refuses when it is
    /// got wrong.
    static func request(_ ref: String,
                        _ what: MirrorAction.WindowAct)
        -> AgentIntegrationWindowActRequest {
        switch what {
        case .close:
            return .init(window: ref, action: .close)
        case .zoom:
            /* The zoom box takes no geometry: the standard state is the
               application's to compute, and a host that supplied one
               would be deciding what the window is FOR. */
            return .init(window: ref, action: .zoom)
        case .move(let left, let top):
            return .init(window: ref, action: .move, left: left, top: top)
        case .resize(let width, let height):
            return .init(window: ref, action: .resize,
                         width: width, height: height)
        }
    }

    /// The guest's own answer, or nil when it dispatched. Never a
    /// paraphrase: a refusal is the most useful thing this surface
    /// produces, because the alternative is a person clicking and
    /// getting silence.
    private func reading<Value>(
        _ result: AgentIntegrationProjectedResult<Value>) -> String? {
        switch result {
        case .completed:
            return nil
        case .refused(let failure):
            return "\(failure.code): \(failure.message)"
        case .unavailable(let why):
            return "\(why)"
        }
    }

    private func sentence(for verdict: ActionAvailability) -> String {
        switch verdict {
        case .available:
            return "available"
        case .emulatorOnly(let reason), .unsupported(let reason):
            return reason
        }
    }
}
