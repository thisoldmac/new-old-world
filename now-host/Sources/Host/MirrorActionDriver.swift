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
/// - **Everything else → the vocabulary's own refusal**, forwarded. A
///   keystroke is a declared, planned gap (`docs/mcp-coverage.md`, W3) and
///   `key` cannot carry a modifier at all because CarbonLib has no
///   `PPostEvent`. This driver does not paper over that with a click at a
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

        case .key, .type, .click, .drag, .qmpClick, .qmpDoubleClick,
             .thumbDrag:
            /* Unreachable: `availability` refuses all seven above. Spelled
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
