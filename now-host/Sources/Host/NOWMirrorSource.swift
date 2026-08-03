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
            let decoded = try JSONDecoder().decode(
                MirrorKit.Scene.self, from: delivery.document)
            scene = decoded
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

    // MARK: - The dispatch

    func note(_ message: String) {
        guard !message.isEmpty else { return }
        status = message
    }

    func perform(_ actions: [MirrorAction], label: String) {
        guard !actions.isEmpty else { return }
        /* Availability is asked BEFORE anything is sent, and asked of the
           vocabulary rather than re-derived here. A driver that carried
           its own opinion would make the two disagree, and only one of
           them is what a GUI greys out. */
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
                let outcome = await self.send(action)
                if let outcome {
                    self.status = "\(label) — \(outcome)"
                    return                       // stop at the first refusal
                }
            }
            self.status = label
            self.poll()                          // show the effect now
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
