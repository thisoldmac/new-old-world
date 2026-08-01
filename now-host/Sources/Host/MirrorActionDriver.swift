import Foundation
import MirrorKit
import NOWAgentIntegration

/// **The seam between a gesture on a rendered scene and the act lane.**
///
/// `MirrorKit` produces `MirrorAction`s and reaches no machine — that is what
/// `NoSecondWireTests` keeps true, and this file is not a way around it. It
/// lives HERE, in the host, for the same reason `MirrorSceneAdapter` does:
/// the rendering package owns the vocabulary and the geometry, and the host
/// owns the one wire.
///
/// ## What it will and will not carry
///
/// `ActionModel.availability` already answers "does NOW's contract declare a
/// command for this act, and can a rendered scene address it". This driver
/// does not re-answer that question and must not: it asks, and refuses
/// anything that is not `available` **with the vocabulary's own sentence**.
/// A driver that carried an act `availability` calls unavailable would make
/// the two disagree, and only one of them is the thing a GUI grays out.
///
/// So the routing is short and the refusals are long, which is the right way
/// round for a surface whose failure mode is a person clicking something and
/// getting silence.
///
/// ## The three outcomes, and why `unavailable` is not a failure
///
/// - **`.menuInvoke` → `menuact`.** The one act that crosses whole today.
///   `menu`, `item` and `titleLeft` all come off the scene the person is
///   looking at, and `titleLeft` is the identity check.
/// - **`.axdo` → `ctlact` / `textset`, once the control carries a
///   reference.** The act lane exists and takes an opaque
///   `now-element-…`; a scene's `Scene.Control.ref` is where one would
///   arrive. Until it does, this refuses with the reason rather than
///   sending a reference the guest would reject — and the refusal names
///   which half is missing.
/// - **`.key` → `key`, when `mods == 0`.** A plain keystroke posts through
///   the guest's input plane. A MODIFIED one is refused, here and at
///   `ActionModel.availability`, because CarbonLib has no `PPostEvent` and
///   the guest cannot say what was held down while a key was posted.
/// - **Everything else → the vocabulary's own refusal**, forwarded. This
///   driver does not paper over an unavailable act with a click at a
///   coordinate, which is the shape the papering-over would take.
///
/// ## What it deliberately does NOT do
///
/// It does not turn `.activate` into `bringToFront`. They look like the same
/// act and are not the same call: `bringToFront` takes an opaque process
/// reference minted by `process.list` and re-validated against a live PSN,
/// and a scene carries a `"hi.lo"` string that no observation on this host
/// minted. Feeding one to the other would be resolving a target out of a
/// listing this side did not take — a stale observation wearing the clothes
/// of a live one, which is the argument every reference in this project
/// rests on. The contract declares an `activate` COMMAND that takes the PSN
/// directly, and there is no host lane for it; that is a gap to close, not a
/// substitution to make.
@MainActor
struct MirrorActionDriver {
    /// What became of one gesture.
    enum Outcome: Equatable {
        /// The act reached the machine and it answered. The payload is the
        /// receipt's own sentence, for a page to show.
        case dispatched(String)
        /// The machine was asked and said no, in its own words.
        case refused(String)
        /// Nothing was asked. The sentence says which half is missing, and
        /// it is the VOCABULARY's sentence wherever there is one.
        case unavailable(String)
        /// The gesture meant nothing to send — a disabled control, a
        /// separator, the desktop backdrop. Not a refusal and not an error:
        /// `ActionModel` answers `[]` and a page shows nothing.
        case inert
    }

    let adapter: AgentIntegrationHostAdapter

    /// The observation that mints the reference a window act is addressed by.
    ///
    /// Optional for the same reason the model's driver is: a driver without
    /// one refuses a window op with a sentence naming the missing half rather
    /// than reaching for "the frontmost window". The stub clients in the test
    /// tree get exactly that behaviour by default, which is the behaviour a
    /// pane in front of a machine that cannot be observed must have.
    var windows: MirrorWindowResolver?

    init(adapter: AgentIntegrationHostAdapter,
         windows: MirrorWindowResolver? = nil) {
        self.adapter = adapter
        self.windows = windows
    }

    /// Drive one gesture's action sequence, in order, stopping at the first
    /// thing that did not dispatch.
    ///
    /// In ORDER and stopping, because the sequence is a sequence: a
    /// background-window click activates before it clicks, and running the
    /// click after the activation was refused would put the second act on
    /// whichever application happened to be in front — which is the
    /// target-free act this whole plane refuses, arrived at by accident
    /// rather than by argument.
    func drive(_ actions: [MirrorAction]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for action in actions {
            let outcome = await drive(action)
            outcomes.append(outcome)
            if case .dispatched = outcome { continue }
            if case .inert = outcome { continue }
            break
        }
        return outcomes.isEmpty ? [.inert] : outcomes
    }

    func drive(_ action: MirrorAction) async -> Outcome {
        /* The vocabulary is asked FIRST, and its answer is final for
           everything it does not call `available`. Two places deciding what
           can be sent is one place to disagree, and the GUI grays from the
           other one. */
        switch ActionModel.availability(action) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .needsObservation(let command, let reason):
            /* The act lane EXISTS for these; what is missing is a reference
               to put in one. Said as this host's own sentence on top of the
               vocabulary's, because a reader of "a scene carries none" needs
               to know the other half is built and waiting. */
            return .unavailable(
                "\(reason) The host lane for \(command) is built; what is "
                    + "missing is a reference on the rendered control.")
        case .available:
            break
        }

        switch action {
        case .menuInvoke(let menuID, let itemIndex, let titleLeft):
            return report(await adapter.menuAct(.init(
                menu: menuID, item: itemIndex, titleLeft: titleLeft)),
                describing: "menu \(menuID) item \(itemIndex)")

        case .axdo(let ref, _, _, let text):
            /* Reachable only once `availability` stops saying
               `needsObservation` — i.e. once a scene carries references. The
               reference is re-checked here anyway: `availability` is a
               function of the ACT, not of this particular target, so it
               cannot have looked at this ref. */
            guard AgentIntegrationActPolicy.isValidElementReference(ref)
            else {
                return .unavailable(
                    "This control carries no observation reference, so "
                        + "there is nothing for ctlact to address. It can be "
                        + "drawn and not clicked, which is a fact about the "
                        + "two planes rather than a defect in either.")
            }
            if let text {
                return report(
                    await adapter.setElementText(element: ref, text: text),
                    describing: "text of \(ref)")
            }
            /* Part 10 — `kControlButtonPart`, the part a press on a plain
               control lands in. A ranged control's parts are a different
               question and a different gesture: the hit tester answers a
               scroll bar with `.scrollbar`, never with an `axdo`, so this
               branch is only ever reached for a control whose whole body is
               one part. */
            return report(
                await adapter.controlAct(.init(element: ref, part: 10)),
                describing: "control \(ref)")

        case .activate:
            /* `availability` calls this available — NOW's contract does
               declare `activate` — and this host has no lane for it. Two
               true statements, and the honest answer names which is which
               rather than quietly reaching for `bringToFront`, whose
               reference vocabulary is not this one's. See the header. */
            return .unavailable(
                "NOW's contract declares the activate command and this host "
                    + "carries no lane for it. The scene's process serial is "
                    + "not the opaque reference bring-to-front takes, so "
                    + "there is nothing to substitute.")

        case .windowAct(let target, let op):
            /* Two calls, in this order, and the first one is allowed to end
               it. The reference is minted by the machine that owns the
               window, so a resolution that names no window means the act is
               not sent — never that it is sent at a neighbour. */
            guard let windows else {
                return .unavailable(
                    "A window act is addressed by a reference only an "
                        + "observation of that Mac can mint, and this window "
                        + "has no observation lane behind it. The act plane "
                        + "is built; what is missing is the walk that names "
                        + "the window.")
            }
            switch await windows.reference(for: target) {
            case .unresolved(let reason):
                return .unavailable(reason)
            case .reference(let reference):
                return report(
                    await adapter.windowAct(Self.request(reference, op)),
                    describing: "\(Self.name(op)) \(target.title.isEmpty ? "the window" : "\"\(target.title)\"")")
            }

        case .finderSelect(let item, let container),
             .finderOpen(let item, let container):
            /* **The one act in this vocabulary NOW declares and this host
               cannot carry**, and the sentence says which half that is.
               `availability` already answered `available(command: "script")`
               — correctly: the contract declares `script`, the PowerPC guest
               serves it, and the act names an item and a container with no
               coordinate anywhere, which is exactly what the Finder's own
               `select item "X" of window "Y"` takes (the route ruled on
               2026-07-31, docs/input-plane-decisions.md §2).

               What does not exist is a `script` lane on this side: the local
               protocol carries the five acts and no script op. Substituting
               something that does exist would be the defect, not the fix —
               `reveal` resolves a bare name by a whole-volume catalog search
               and could select an item of the same name somewhere else
               entirely, and a scene's desktop item carries no path to make
               that exact. So this refuses and names both halves. */
            let what: String
            switch container {
            case .desktop: what = "on the desktop"
            case .window(let title): what = "in \"\(title)\""
            }
            let verb: String
            if case .finderOpen = action { verb = "open" } else {
                verb = "select"
            }
            return .unavailable(
                "NOW's contract declares the script command, which is how "
                    + "\"\(item)\" \(what) would be \(verb)ed — by name, "
                    + "through the Finder's own terminology — and this host "
                    + "carries no lane for it. Nothing was sent, and nothing "
                    + "was sent at a coordinate instead: NOW has no "
                    + "positional click on purpose.")

        case .key(let name, let code, let char, let mods):
            /* Reachable only when `availability` says `mods == 0` — see
               `ActionModel.availability(.key)`. Re-checked here for the
               same reason `.axdo`'s reference is: `availability` is a
               function of the ACT and cannot have looked at this one's
               `mods` twice, so a caller that reached this case some other
               way gets the same refusal rather than a request the guest
               would answer `unsupported` to. */
            guard mods == 0 else {
                return .unavailable(
                    "A modified keystroke cannot be sent — see "
                        + "ActionModel.availability(.key).")
            }
            return report(await adapter.key(.init(
                name: name, code: code, char: char, mods: mods)),
                describing: name.map { "key \($0)" } ?? "key code \(code)")

        case .type, .click, .drag, .qmpClick, .qmpDoubleClick, .thumbDrag:
            /* Unreachable: `availability` refuses all six above. `.key` left
               this list when the key lane landed, and `.menuDrag` left the
               vocabulary entirely with the wrong-constant menu geometry.
               Spelled
               out rather than defaulted so that an act promoted to
               `available` without a route here fails to compile instead of
               falling into a silent nothing. */
            return .unavailable(
                "This act reports itself sendable and has no route on the "
                    + "act lane. That disagreement is a bug in one of the "
                    + "two, and it is not for this side to guess which.")
        }
    }

    // MARK: -

    /// The vocabulary's four window ops onto the contract's request, with
    /// exactly the geometry each takes. `zoom` and `close` carry none, and
    /// the request type refuses a call that sends any — so this mapping is
    /// total by construction rather than by care.
    private static func request(_ reference: String, _ op: MirrorKit.WindowOp)
        -> AgentIntegrationWindowActRequest {
        switch op {
        case .move(let left, let top):
            return .init(window: reference, action: .move,
                         left: left, top: top)
        case .resize(let width, let height):
            return .init(window: reference, action: .resize,
                         width: width, height: height)
        case .zoom:
            return .init(window: reference, action: .zoom)
        case .close:
            return .init(window: reference, action: .close)
        }
    }

    private static func name(_ op: MirrorKit.WindowOp) -> String {
        switch op {
        case .move: return "move"
        case .resize: return "resize"
        case .zoom: return "zoom"
        case .close: return "close"
        }
    }

    private func report<Receipt: Codable & Equatable & Sendable>(
        _ result: AgentIntegrationProjectedResult<Receipt>,
        describing what: String
    ) -> Outcome {
        switch result {
        case .completed:
            /* DISPATCHED, and the word is chosen the way every other word on
               this plane is: the event was handed to the application. A
               driver that said "clicked" or "selected" would be the one
               place in the stack that claimed more than the machine did. */
            return .dispatched(
                "\(what): the event was dispatched to the application. "
                    + "Whether it acted on it is a question for the next "
                    + "scene.")
        case .refused(let failure):
            return .refused(failure.message)
        case .unavailable(let unavailable):
            return .unavailable(unavailable.message)
        }
    }
}
