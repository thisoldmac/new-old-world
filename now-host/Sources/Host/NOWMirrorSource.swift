import Foundation
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration

/// The live NOW adapter uses MirrorKit's compatibility gate rather than
/// maintaining a second version constant. The duplicate used to accept only
/// v1 after MirrorKit and the guest had both moved to v2, leaving the real
/// Mirror window blank while every package-level IR test passed.
enum NOWMirrorSceneDecoder {
    static func decode(irVersion: Int,
                       document: Data) throws -> MirrorKit.Scene {
        /* Gate BEFORE JSONSerialization. An unknown major paired with garbage
           must still be an unsupported-major answer, not a parse failure. */
        try IR.requireSupportedMajor(NSNumber(value: irVersion))
        let body = try JSONSerialization.jsonObject(with: document)
        return try MirrorScene.decode(result: [
            "irVersion": irVersion,
            "scene": body,
        ])
    }

    static var readableMajors: String {
        IR.supportedMajors.sorted().map { "v\($0)" }
            .joined(separator: ", ")
    }
}

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

    /// **What the machine last DID, not what the poll last saw.**
    ///
    /// These were one string, and a poll every 0.75s overwrote the answer
    /// to a click before a person could read it - so a refusal, which is
    /// the most useful thing this surface produces, flashed and was gone.
    /// The poll line is ambient; an act's answer is an event, and events
    /// stay put.
    @Published private(set) var lastAct: String = ""
    @Published private(set) var ambient: String = "not started"

    /// What the window shows: the act while it is still worth reading,
    /// then the ambient line again.
    var status: String { lastAct.isEmpty ? ambient : lastAct }

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
    private var iconLayout: String = "<none>"
    private var fetchingIcons = false
    private var actGeneration = 0

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
        ambient = "asking for a scene…"
        poll()
    }

    func stop() {
        running = false
        ambient = "stopped"
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
                self.ambient = failure.refusedByGuest
                    ? "the Mac declined: \(failure.message)"
                    : failure.message
            }
            self.rearm()
        }
    }

    private func accept(_ delivery: GuestListener.SceneDelivery) {
        do {
            var decoded = try NOWMirrorSceneDecoder.decode(
                irVersion: delivery.irVersion, document: delivery.document)
            decoded = withIcons(decoded)
            scene = decoded
            refreshIconsIfStale(decoded)
            ambient = "\(decoded.windows.count) windows · walk "
                + "\(delivery.walkMs.map { "\($0)ms" } ?? "?") · transfer "
                + "\(delivery.transferMs)ms"
        } catch IR.CompatError.unknownMajor {
            ambient = "this Mac speaks scene IR v\(delivery.irVersion); "
                + "this build reads \(NOWMirrorSceneDecoder.readableMajors)"
        } catch {
            /* Named rather than swallowed: this is the seam that has cost
               this project the most, and a mirror that silently keeps
               drawing a stale scene while the producer emits something
               unreadable is the failure wearing its best clothes. */
            ambient = "the scene did not decode as IR "
                + "v\(delivery.irVersion): \(error)"
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
        /* The leading "desktop" is not decoration. The key used to be just
           the folder windows joined, so a machine with NO Finder window
           open produced "" - which equals the initial value of iconLayout,
           so the guard never fired and the DESKTOP's own icons were never
           fetched at all. Watched: a mirror with a bare desktop drew no
           icons, ever, while every folder window drew its own. */
        let key = (["desktop"] + folders.map(FinderItems.layoutKey))
            .joined(separator: "|")
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
        /* Two vectorised passes, not one per icon. The first names every
           item and where the Finder drew it; the second asks the FILES
           for their type and creator, which is what picks the real icon
           out of the atlas - without them every document, application
           and control panel renders as the same generic page, which is
           what the mirror did until this was measured against a
           screenshot of the machine.

           Files only, deliberately: `file type of` a folder or a disk is
           an error that fails the whole script, and their kind already
           chooses the right art.

           The two passes are two SCRIPTS, not one, because AppleScript
           fails a script whole. Fused, any error in the type pass took
           the names and positions down with it and the window rendered
           as an empty box - which is what Macintosh HD did for an entire
           drive while Control Panels beside it drew 33 items. Losing the
           right icon art is a blemish; losing the contents is not a
           mirror. */
        let items = """
        tell application "Finder"
        set ns to name of every item of \(container)
        set ps to position of every item of \(container)
        set ks to kind of every item of \(container)
        end tell
        set out to ""
        repeat with i from 1 to (count ns)
        set p to item i of ps
        set out to out & "I" & tab & (item i of ns) & tab & (item 1 of p) & \
        tab & (item 2 of p) & tab & (item i of ks) & return
        end repeat
        return out
        """
        let read = await readingOutput("script", ["source": .text(items)])
        guard let text = read.value else {
            note("could not read the items of \(container)"
                 + " - \(read.error ?? "no reason given")")
            return nil
        }

        let types = """
        tell application "Finder"
        set fn to name of every file of \(container)
        set ft to file type of every file of \(container)
        set fc to creator type of every file of \(container)
        end tell
        set out to ""
        repeat with i from 1 to (count fn)
        set out to out & "F" & tab & (item i of fn) & tab & (item i of ft) & \
        tab & (item i of fc) & tab & "" & return
        end repeat
        return out
        """
        let art = await readingOutput("script", ["source": .text(types)])
        if art.value == nil {
            note("\(container): items read, but not their icon art"
                 + " - \(art.error ?? "no reason given")")
        }
        /* Unquote BEFORE joining. Each script answers in SOURCE form, so
           each blob carries its own surrounding quotes; concatenating
           them raw would leave a `""` inside one line and eat the row on
           either side of it. */
        return Self.parseIcons(Self.unquote(text) + "\r"
                               + Self.unquote(art.value ?? ""))
    }

    /// OSADoScript's SOURCE-form wrapper, removed once.
    static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else {
            return raw
        }
        return String(raw.dropFirst().dropLast())
    }

    /// OSADoScript renders its result in SOURCE form, so a text result
    /// arrives wrapped in quotes and its lines are separated by CR -
    /// classic AppleScript's terminator, and the reason `linefeed` is not
    /// used to build it (that identifier does not exist in OS 9's
    /// AppleScript and fails the whole script with osaErr -1753).
    static func parseIcons(_ raw: String) -> [MirrorKit.Scene.DesktopItem] {
        let text = unquote(raw)
        var items: [MirrorKit.Scene.DesktopItem] = []
        var types: [String: (String, String)] = [:]

        for line in text.components(separatedBy: CharacterSet.newlines)
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { continue }
            switch f[0] {
            case "I":
                guard let x = Int(f[2]), let y = Int(f[3]) else { continue }
                let kind = f[4].lowercased()
                items.append(.init(
                    name: f[1],
                    kind: kind.contains("folder") ? "folder"
                        : kind.contains("disk") ? "disk"
                        : kind.contains("application") ? "application" : "file",
                    type: nil, creator: nil,
                    x: x, y: y, placed: true,
                    alias: kind.contains("alias"), invisible: false))
            case "F":
                /* An OSType is four characters. The Finder answers with
                   the type as text, and a file whose type is unset comes
                   back empty rather than absent - which is a real
                   answer, and the atlas treats it as one. */
                types[f[1]] = (f[2], f[3])
            default:
                continue
            }
        }
        return items.map { item in
            guard let pair = types[item.name] else { return item }
            var out = item
            out.type = pair.0.isEmpty ? nil : String(pair.0.prefix(4))
            out.creator = pair.1.isEmpty ? nil : String(pair.1.prefix(4))
            return out
        }
    }

    // MARK: - The dispatch

    func note(_ message: String) {
        /* Notes are the things that happened INSTEAD of an act, so they
           belong in the act log beside the acts - a drag that was never
           sent is exactly as important as one that was refused. */
        ActLog.note(action: "(note)", outcome: message, ms: 0)
        report(message)
    }

    /// Say it, and keep saying it for long enough to be read. Four
    /// seconds is about how long a person takes to look down after a
    /// click that did not do what they expected.
    private func report(_ message: String) {
        guard !message.isEmpty else { return }
        lastAct = message
        actGeneration += 1
        let mine = actGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.actGeneration == mine else { return }
            self.lastAct = ""
        }
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
            ActLog.note(action: InteractionBridge.label(for: interaction),
                        outcome: "NOT DISPATCHED (nothing): \(why)", ms: 0)
            report(why)
        case .unsupported(let why):
            ActLog.note(action: InteractionBridge.label(for: interaction),
                        outcome: "NOT DISPATCHED (unsupported): \(why)", ms: 0)
            report("\(InteractionBridge.label(for: interaction)): \(why)")
        default:
            let label = InteractionBridge.label(for: interaction)
            report(label + "…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let started = Date()
                let complaint = await self.serve(plan)
                ActLog.note(action: "\(label)  plan=\(plan)",
                            outcome: complaint ?? "dispatched",
                            ms: Int(Date().timeIntervalSince(started) * 1000))
                if let complaint {
                    self.report("\(label) — \(complaint)")
                } else {
                    self.report(label + " ✓")
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
                report("\(label): \(sentence(for: verdict))")
                return
            }
        }
        report(label + "…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for action in actions {
                if let outcome = await self.send(action) {
                    self.report("\(label) — \(outcome)")
                    return
                }
            }
            self.report(label + " ✓")
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
        await readingOutput(verb, args, row: row).value
    }

    /// The same call, keeping the guest's refusal instead of discarding
    /// it. `runReadingOutput` answering `nil` cost a whole drive: the
    /// Macintosh HD window rendered as an empty box for an hour and the
    /// mirror had nothing to say about why, because "the script failed"
    /// and "nobody asked" were the same value.
    private func readingOutput(_ verb: String,
                               _ args: [String: CommandArg],
                               row: String = "output")
        async -> (value: String?, error: String?) {
        await withCheckedContinuation { continuation in
            listener.runCommand(verb, typed: args) { result in
                guard result.ok else {
                    let e = result.error
                    return continuation.resume(returning: (
                        nil,
                        "\(e?.code ?? "error"): \(e?.message ?? "no reason")"))
                }
                var value: String?
                for cells in result.output?[verb] ?? [] where cells.first == row {
                    value = cells.count > 1 ? cells.last : ""
                }
                continuation.resume(returning: (value, nil))
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
    /// Every act, and what became of it, on one line in a file.
    ///
    /// Written because a whole day of driving could not tell DISPATCHED
    /// from FAILED. A title-bar drag that did nothing, a popup that
    /// "did not answer in time", a Hide that looked like it worked and
    /// had not, a keystroke that vanished after Tab, and two window acts
    /// that reported `outcome-unknown` while plainly working - each of
    /// those was resolved by guessing or by a screendump, and several
    /// wrong calls came straight out of the gap. The mirror's status
    /// line shows one act and then scrolls away; this keeps them.
    ///
    /// It is a DIAGNOSTIC, not a test channel. Rule 1 still stands: the
    /// mirror is driven and judged by driving it. This says what the
    /// driving did, the way a screendump says what the machine drew.
    private func send(_ action: MirrorAction) async -> String? {
        let started = Date()
        let outcome = await dispatch(action)
        ActLog.note(action: "\(action)",
                    outcome: outcome ?? "dispatched",
                    ms: Int(Date().timeIntervalSince(started) * 1000))
        return outcome
    }

    private func dispatch(_ action: MirrorAction) async -> String? {
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
