import Foundation
import NOWAgentIntegration

/// **Whether a control this Mac shows can be served by the Mac on the wire —
/// and if not, the sentence that says so.**
///
/// The app UI already spends capability facts as enablement rather than as a
/// report (`SessionCapabilitiesProjection.faces`, the `.appUI` reason): a
/// person reads availability off the control they were already reaching for.
/// What was missing is that each page grew its own way of deciding, so a
/// control could be dark with nothing to explain it — which is
/// indistinguishable from a bug, and the person clicks it and concludes the
/// app is broken.
///
/// Three things this deliberately does NOT do.
///
/// - **It does not invent a capability system.** Requirements come off the
///   projection row that already declares them (`HostProjection.requires`)
///   and the wording for the available case off that row's
///   `availabilityNote`. A gate and a tool that disagree about what a
///   capability needs would be two answers about one machine.
/// - **It never asks who the guest is.** No ISA check, no hello name, no
///   `isPPC`. The one input is what the connected machine has said about
///   itself — its `help` table for commands, its answers for message
///   families. That is the same discipline
///   `AgentIntegrationCapabilityLedger` is built on, and for the same
///   reason: a table keyed on a guest's name goes stale the afternoon that
///   guest grows the verb, silently and in the direction nothing reports.
/// - **It does not collapse "cannot" into "not yet".** `unsettled` is
///   enabled, because unproven is not a no and the machine's own refusal is
///   a better answer than this side declining to ask. Only a machine that
///   has actually said no turns a control dark.
enum GuestCapabilityGate {
    /// What a control should do, and what to say about it.
    ///
    /// Four cases for three distinct facts plus the ordinary one, and the
    /// distinction is the whole point: a control permanently dark on a
    /// machine that would serve it fine is what flattening these produces.
    enum Decision: Equatable {
        /// The connected machine has said it serves every requirement.
        case allowed

        /// Connected, but nothing has established this yet. **Enabled**, with
        /// a sentence available for whoever wants to show one: the click is
        /// what settles the question, and the machine answers in its own
        /// words if it cannot.
        case unsettled(String)

        /// The connected machine answered that it does not serve this.
        /// **Disabled**, carrying that machine's own refusal.
        case unsupported(String)

        /// There is no machine on the wire. **Disabled**, and it is a
        /// different sentence from the one above — a control dark because
        /// nothing is connected must not read as a machine that cannot.
        case noGuest(String)

        /// The action means nothing for this ITEM, whichever Mac is
        /// attached — launching a system extension, fronting a faceless
        /// background process. **Disabled**, and it is deliberately not one
        /// of the three above: those are facts about the machine and this is
        /// a fact about the thing selected, and a person told the wrong one
        /// goes looking in the wrong place. See `GuestItemApplicability`.
        case inapplicable(String)

        /// Whether the control accepts a click.
        var isEnabled: Bool {
            switch self {
            case .allowed, .unsettled: return true
            case .unsupported, .noGuest, .inapplicable: return false
            }
        }

        /// Why the control is in this state, or nil when there is nothing
        /// worth saying. **A disabled case always has one** — a greyed
        /// control with no explanation is the failure this type exists to
        /// prevent, so this is not optional in the cases that matter.
        var explanation: String? {
            switch self {
            case .allowed: return nil
            case .unsettled(let text),
                 .unsupported(let text),
                 .noGuest(let text),
                 .inapplicable(let text):
                return text
            }
        }

        /// True when the reason should be shown in place rather than only on
        /// hover. A dark control has to explain itself where the eye already
        /// is; an enabled one that merely has not been proven yet does not
        /// get to nag, and its sentence lives in the tooltip.
        var deservesAVisibleReason: Bool {
            switch self {
            case .unsupported, .noGuest, .inapplicable: return true
            case .allowed, .unsettled: return false
            }
        }
    }

    /// Decide for one projection row, which is how a view should ask:
    /// `GuestCapabilityGate.decide(StreamScreenProjection.self, in: evidence)`.
    ///
    /// The row supplies the requirements and the available-case wording, so a
    /// view names a capability rather than restating one.
    static func decide<Row: HostProjection>(
        _ row: Row.Type,
        in evidence: GuestCapabilityEvidence
    ) -> Decision {
        decide(requiring: Row.requires, in: evidence)
    }

    /// The same decision for a requirement list stated directly — for a
    /// control that is not (yet) a projection row, such as a single
    /// diagnostic verb.
    static func decide(requiring requirements: [String],
                       in evidence: GuestCapabilityEvidence) -> Decision {
        guard evidence.isConnected else {
            return .noGuest(
                "No \(MachineNaming.commonNoun) is connected. "
                + "\(MachineNaming.startingSentence(MachineNaming.simpleReference)) "
                + "connects to \(MachineNaming.thisMac); once connected, "
                + "whether it serves this is its own answer.")
        }

        var unsettled: [String] = []
        var refused: [(name: String, code: String?, message: String?)] = []
        for requirement in requirements {
            switch evidence.standing(of: requirement) {
            case .served:
                continue
            case .unsettled:
                unsettled.append(requirement)
            case .notServed(let code, let message):
                refused.append((requirement, code, message))
            }
        }

        /* Refusal wins over unproven, the same precedence the capability
           ledger's `state(of:)` uses: one requirement the machine has said no
           to settles the conjunction, whatever is unknown about the rest. */
        if let first = refused.first {
            return .unsupported(unsupportedSentence(
                first.name, code: first.code, message: first.message,
                peerLabel: evidence.peerLabel,
                others: refused.dropFirst().map(\.name)))
        }
        if !unsettled.isEmpty {
            return .unsettled(
                "Nothing has established whether \(evidence.peerLabel) serves "
                + unsettled.joined(separator: ", ")
                + ". Trying it asks — and it answers in its own words if it "
                + "cannot.")
        }
        return .allowed
    }

    /// The machine's own refusal, quoted rather than reworded.
    ///
    /// Its words and not ours, for the reason the Diagnostics page states in
    /// its own idiom: a refusal explained by this side is this side
    /// explaining a machine it did not ask. The closing sentence is the one
    /// thing added, because without it a dark control still reads as damage.
    private static func unsupportedSentence(
        _ name: String, code: String?, message: String?,
        peerLabel: String, others: [String]
    ) -> String {
        var sentence = "\(peerLabel) does not serve \(name)"
        if !others.isEmpty {
            sentence += " (nor " + others.joined(separator: ", ") + ")"
        }
        if let message, !message.isEmpty {
            sentence += " — it answered “\(message)”"
            if let code, !code.isEmpty {
                sentence += " (\(code))"
            }
        } else if let code, !code.isEmpty {
            sentence += " — it answered “\(code)”"
        } else {
            sentence += ": it is absent from that machine's own command table"
        }
        return sentence + ". NOW's two guests differ in completeness; "
            + "this is one of those differences."
    }
}

/// One capability's standing with the connected machine. Three states, and
/// the third is why this is not a `Bool` — the same distinction
/// `AgentIntegrationCapabilityState` draws for the agent surface, from the
/// same two sources.
enum GuestCapabilityStanding: Equatable {
    case served
    /// Nobody has asked this machine yet. Not a synonym for `notServed`.
    case unsettled
    /// The machine said no, in its own words when it gave any.
    case notServed(code: String?, message: String?)
}

/// One settled answer about one capability, as this side heard it.
struct GuestCapabilityObservation: Equatable {
    var served: Bool
    /// The machine's own refusal code, when it refused.
    var code: String?
    var message: String?
}

/// **What the connected machine has said about itself**, in the shape a gate
/// decides over.
///
/// A value rather than a live object on purpose: a decision is a pure
/// function of what was heard, so it can be tested without a wire, a
/// listener, or a Mac.
struct GuestCapabilityEvidence: Equatable {
    var isConnected: Bool
    /// What to call the machine in a sentence a person reads.
    var peerLabel: String
    /// The machine's own command table, from `help`. **Nil means it has not
    /// answered `help` yet**, which is a different fact from a table that
    /// came back without the verb — the first leaves a command unsettled and
    /// the second settles it as absent.
    var commandNames: Set<String>?
    /// Settled answers per capability name, keyed as the contract names it.
    var observations: [String: GuestCapabilityObservation]

    init(isConnected: Bool,
         peerLabel: String,
         commandNames: Set<String>? = nil,
         observations: [String: GuestCapabilityObservation] = [:]) {
        self.isConnected = isConnected
        self.peerLabel = peerLabel
        self.commandNames = commandNames
        self.observations = observations
    }

    /// Every capability name that is a MESSAGE FAMILY rather than a command.
    ///
    /// Taken from the capability ledger's own declaration rather than guessed
    /// from the spelling, because the distinction decides which source can
    /// settle a requirement: `help` lists commands and cannot list families —
    /// that gap is how `ps` shipped wire-only — so falling a family through to
    /// the command table would resolve it "absent" against every machine that
    /// exists, permanently and silently. One declaration, read here and by the
    /// agent surface, is what keeps the two from drifting.
    static let messageFamilies: Set<String> = Set(
        AgentIntegrationCapabilityLedger.familyPolicy.map(\.family))

    /// What is known about one requirement.
    func standing(of requirement: String) -> GuestCapabilityStanding {
        if let observation = observations[requirement] {
            if observation.served { return .served }
            /* A typed "I do not implement that" is an answer. Any other
               failure — a Toolbox error, a busy lane, a malformed reply —
               says nothing about the capability, so it leaves the question
               open rather than turning a working control dark. */
            guard let code = observation.code,
                  AgentIntegrationCapabilityNames.isRefusal(code)
            else { return .unsettled }
            return .notServed(code: observation.code,
                              message: observation.message)
        }
        // A family is settled only by having asked; `help` cannot see one.
        if Self.messageFamilies.contains(requirement) { return .unsettled }
        guard let commandNames else { return .unsettled }
        return commandNames.contains(requirement)
            ? .served
            : .notServed(code: nil, message: nil)
    }
}

/// **Where the app UI's capability observations accumulate, per machine.**
///
/// `GuestListener.familyObservations` already records the families whose
/// requests go through its wrapped completion paths, and this is deliberately
/// not a second copy of those: it is the place for the answers that path
/// cannot see. The live-stream bracket is the case in hand — `stream.start`
/// takes an id no pending map holds, so a guest that refuses it does so into
/// `lastGuestError` and nothing writes it down. A page that watched a machine
/// refuse a capability and then offered the control again next time is a page
/// that never learned anything.
///
/// Keyed per machine, for the reason the listener keys its own record that
/// way: an observation is a claim about ONE Mac, and a flat store would let
/// one machine's refusal grey out another's control.
@MainActor
final class GuestCapabilityRecord: ObservableObject {
    /// The app's one record. A shared default rather than a wiring change in
    /// `App.swift`: every page that gates a control wants the same answers
    /// about the same machines, and a per-page store would have each of them
    /// learn the same refusal separately. Injectable, so a test gets its own.
    static let shared = GuestCapabilityRecord()

    /// Bumped on every write so an `ObservableObject` view redraws; the
    /// observations themselves are read through `evidence(...)`.
    @Published private(set) var revision = 0

    private var byGuest: [GuestKey: [String: GuestCapabilityObservation]] = [:]

    init() {}

    /// Records that a machine served a capability.
    func noteServed(_ capability: String, by key: GuestKey?) {
        note(capability, for: key,
             .init(served: true, code: nil, message: nil))
    }

    /// Records a machine's refusal, in its own words.
    ///
    /// A timeout or a dropped connection is deliberately NOT a refusal and
    /// callers must not pass one: silence proves nothing about what a machine
    /// implements, and writing it down as a no would let one wedged MacTCP
    /// stack read as a permanently missing feature. `standing(of:)` filters
    /// non-refusal codes as a second line, but the caller knows first.
    func noteRefusal(_ capability: String, by key: GuestKey?,
                     code: String?, message: String?) {
        note(capability, for: key,
             .init(served: false, code: code, message: message))
    }

    private func note(_ capability: String, for key: GuestKey?,
                      _ observation: GuestCapabilityObservation) {
        guard let key else { return }
        byGuest[key, default: [:]][capability] = observation
        revision += 1
    }

    /// A machine leaving the roster takes its answers with it.
    func forget(_ key: GuestKey) {
        guard byGuest.removeValue(forKey: key) != nil else { return }
        revision += 1
    }

    func observations(for key: GuestKey?) -> [String: GuestCapabilityObservation] {
        key.flatMap { byGuest[$0] } ?? [:]
    }

    /// The evidence for the machine a page is looking at: this record's
    /// answers over the listener's own, plus a command table when the caller
    /// has one.
    ///
    /// The listener's observations are the base layer and this record's win a
    /// tie, because this record only ever holds something the listener's
    /// wrapped paths could not see.
    func evidence(for connection: GuestConnectionState,
                  listener: GuestListener,
                  commandNames: Set<String>? = nil) -> GuestCapabilityEvidence {
        var observations: [String: GuestCapabilityObservation] = [:]
        let connected = connection.key != nil
        if connected {
            for (family, seen) in listener.familyObservations {
                observations[family] = .init(served: seen.served,
                                             code: seen.code,
                                             message: seen.message)
            }
            for (capability, seen) in self.observations(for: connection.key) {
                observations[capability] = seen
            }
        }
        return GuestCapabilityEvidence(
            isConnected: connected,
            peerLabel: connection.peerLabel,
            commandNames: commandNames,
            observations: observations)
    }
}
