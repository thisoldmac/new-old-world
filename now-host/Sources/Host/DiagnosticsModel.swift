import Combine
import Foundation
import NOWAgentIntegration

/// One diagnostic as this side needs to know it: the verb, what it answers,
/// what it costs, and the one thing a reader must not conclude from it.
///
/// The `probe` is the contract's own name and the wire value
/// (`AgentIntegrationDiagnosticProbe`), so nothing here is a second spelling
/// of a verb. Everything else is written for the person at this Mac.
struct GuestDiagnostic: Identifiable, Equatable {
    let probe: AgentIntegrationDiagnosticProbe
    let title: String
    /// What the machine measures, in a sentence.
    let measures: String
    /// What it costs that machine, said before anyone spends it.
    let cost: String
    /// A conclusion this answer does NOT support. Present on exactly one of
    /// the three today, and it earns its place — see `vprobe` below.
    let caveat: String?

    var verb: String { probe.rawValue }
    var id: String { probe.rawValue }
}

enum GuestDiagnostics {
    /// The three, in the order the page draws them: the two measurements of
    /// the screen first, since they are the expensive ones and the pair a
    /// person compares, then the free read of the transfer counters.
    static let all: [GuestDiagnostic] = [
        GuestDiagnostic(
            probe: .vprobe,
            title: "Framebuffer Read Cost",
            measures: "What reading this Mac's screen memory costs, by "
                + "access method: raw reads at 8, 16, 32 and 64 bits "
                + "against the CopyBits baseline, whether a reread hits a "
                + "cache, whether a partial read scales, and whether the "
                + "raw reads are pixel-faithful.",
            cost: "A few seconds of full-screen reads — longer on a 68030. "
                + "It wants a still screen: anything animating is measured "
                + "too.",
            /* The caveat exists because this exact reading has already
               misled someone about this exact machine. A `vprobe` run on the
               PowerBook 1400c reported `CopyBits failed`, and that failure
               does not reproduce through the capture path (plan 005,
               Metal) — they are different paths. Without this sentence a
               person reads a red row here and goes looking for a bug in
               Screenshots. */
            caveat: "A failing row here is about this probe's own read "
                + "path, not about screen capture. A CopyBits failure has "
                + "been reported by this probe on a Mac whose screenshots "
                + "cross correctly; the two use different paths. Check the "
                + "Screenshots page for whether capture works."),
        GuestDiagnostic(
            probe: .shotdiag,
            title: "Capture Read Provenance",
            measures: "Where a capture actually read from: the framebuffer "
                + "base as this Mac resolved it, that base through "
                + "StripAddress, whether it is in 32-bit addressing at the "
                + "moment of the walk, and row 0's first sixteen bytes as "
                + "the walk sees them beside the same row as CopyBits "
                + "copies it. Identical samples mean the base is right and "
                + "the fault is downstream; different ones name the byte.",
            cost: "It stages one real capture and throws it away, so it "
                + "costs what a screenshot costs and wants a still screen. "
                + "No image is produced and nothing is transferred.",
            caveat: nil),
        GuestDiagnostic(
            probe: .putstat,
            title: "Transfer Diagnostics",
            measures: "Where the last file this Mac RECEIVED spent its "
                + "time: bytes, chunk and write counts, the milliseconds "
                + "inside FSWrite against the whole receive path, what a "
                + "resume started from, and the receive backlog. Measured "
                + "there because that is the only place the disk can be "
                + "told apart from the wire.",
            cost: "Free — it reads counters. It describes the LAST "
                + "transfer, so a Mac that has received nothing since it "
                + "launched answers its own zeroes.",
            caveat: nil),
    ]
}

/// Whether the connected Mac serves one diagnostic — three states, and the
/// third is why this is not a `Bool`.
///
/// `unknown` is the honest answer before that machine has listed its
/// commands, and it is a different fact from "no": collapsing them would
/// have the page telling someone their Mac lacks a verb when all that
/// happened is that `help` has not come back yet. It is the same three-state
/// distinction the capability ledger draws for the agent surface, from the
/// same source — that machine's own `help` table.
enum DiagnosticServing: Equatable {
    case unknown
    case served
    case notServed
}

/// One diagnostic's state on this page.
struct DiagnosticState: Identifiable, Equatable {
    let diagnostic: GuestDiagnostic
    var serving: DiagnosticServing = .unknown
    var isRunning = false
    /// The guest's rows, as the guest wrote them.
    var rows: [DiagnosticRow] = []
    /// The guest's own sentence when it refused — never reworded here.
    var refusal: String?
    var ranAt: Date?

    var id: String { diagnostic.id }
    var hasRun: Bool { ranAt != nil }

    /// The machine said `ok` and sent no rows at all.
    ///
    /// The one state that genuinely means "the probe did not answer", and it
    /// is kept apart from every kind of zero on purpose: a table of zeroes is
    /// a MEASUREMENT (see `TransferDiagnosticsReading`), while this is the
    /// absence of one. Before this existed the page drew nothing here, which
    /// left the two looking alike — an empty card and a card full of zeroes
    /// both reading as "broken".
    var answeredWithNothing: Bool {
        hasRun && !isRunning && refusal == nil && rows.isEmpty
    }

    /// `putstat`'s rows read as an answer rather than a table. Nil for the
    /// other two diagnostics, and before a run.
    var transferReading: TransferDiagnosticsReading? {
        guard diagnostic.probe == .putstat, !rows.isEmpty else { return nil }
        return TransferDiagnosticsReading(rows: rows)
    }
}

/// `putstat`'s eleven rows, split by what they are actually about.
///
/// **Eight of them describe the last file this Mac RECEIVED; three do not.**
/// The guest emits them in one list (`now-guest-ppc/src/commands/commands.c
/// :: run_putstat`), but `Rcv backlog`, `Rcv peak` and `Loop passes` are read
/// from the live connection — they are true whether or not a file has ever
/// arrived. That split is the whole reason this type exists: a Mac that has
/// received nothing answers eight zeroes beside three live numbers, and
/// rendering all eleven as one table turns a working probe into what looks
/// like a failed one.
///
/// **A zero here is a measurement, never a silence.** Whether the probe
/// answered at all is a different question with a different answer —
/// `DiagnosticState.answeredWithNothing` — and the two must not be collapsed:
/// one means "nothing has been received", the other means "this Mac told us
/// nothing".
struct TransferDiagnosticsReading: Equatable {
    /// The rows describing the last received file, in the guest's order.
    let transfer: [DiagnosticRow]
    /// The rows that are true of the running connection regardless of any
    /// transfer — the evidence the probe answered when the rest are zeroes.
    let live: [DiagnosticRow]
    /// Every transfer counter is zero: nothing has been received since this
    /// Mac's NOW started.
    let hasReceivedNothing: Bool

    /// The three live labels, named rather than derived, because nothing in
    /// the wire's `[label, value]` pairs says which kind a row is. Any label
    /// this list does not name counts as a transfer counter — the
    /// conservative direction, since an unrecognised non-zero row then keeps
    /// the page from claiming nothing was received.
    static let liveLabels: Set<String> = ["Rcv backlog", "Rcv peak",
                                          "Loop passes"]

    init(rows: [DiagnosticRow]) {
        var transfer: [DiagnosticRow] = []
        var live: [DiagnosticRow] = []
        for row in rows {
            if Self.liveLabels.contains(row.label) {
                live.append(row)
            } else {
                transfer.append(row)
            }
        }
        self.transfer = transfer
        self.live = live
        hasReceivedNothing = !transfer.isEmpty
            && transfer.allSatisfy { Self.isZero($0.value) }
    }

    /// A value is zero when the digits in it are all zeroes — which covers
    /// `0`, `0 ms` and the CRC's `00000000` without this side having to know
    /// which row carries which unit. A value with no digits in it at all is
    /// NOT zero: it is something this side did not expect, and guessing it
    /// away would be the page inventing a reading.
    static func isZero(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        return !digits.isEmpty && digits.allSatisfy { $0 == "0" }
    }
}

/// One `[label, value]` pair, as the guest wrote it.
struct DiagnosticRow: Identifiable, Equatable {
    let index: Int
    let label: String
    let value: String

    var id: Int { index }
}

/// Drives the Diagnostics page: three verbs the guests serve, run and read
/// from this Mac.
///
/// **The page exists because of an asymmetry, not because of a feature.**
/// These three were reachable from the agent surface's plumbing and from
/// nothing a person could click — `putstat`'s counters were read by this host
/// internally to size a transfer, and `shotdiag`, the verb that found the
/// PowerBook 180c's addressing defect, was reachable from nothing at all.
/// A diagnostic an agent can read and a person cannot is the asymmetry the
/// parity work exists to close (plan 005, P1 #13).
///
/// **Availability comes off `help`, never off which Mac it is.** The three
/// are not served by the same guests — `vprobe` by both, `shotdiag` by the
/// 68K guest, `putstat` by the Carbon one — so the page asks the connected
/// machine for its command table once per connection and says, per card,
/// whether that machine serves the verb. A card for a verb this Mac does not
/// have does not offer a button that would do nothing, and does not suggest
/// anything is broken: the other Mac model answers it, and that is what the
/// card says.
@MainActor
final class DiagnosticsModel: ObservableObject, GuestScopedModel {
    /// One machine's readings, parked while another is driven.
    ///
    /// Parked rather than discarded for the census's reason: these are
    /// measurements of one machine, and a person who glanced at the other Mac
    /// should not have to spend another full-screen read to get them back.
    /// The served set travels with them, because it is a fact about the
    /// machine those readings came from.
    struct Snapshot {
        var states: [DiagnosticState]
        var askedForCommands: Bool
        /// That machine's own command table, parked with its readings. It is
        /// the evidence the gate decides over, and it is a fact about the
        /// machine those readings came from — carrying one Mac's table into
        /// another's cards is exactly the mistake the per-guest cache exists
        /// to prevent.
        var commandNames: Set<String>?
    }

    private let cache = GuestStateCache<Snapshot>()

    @Published var connection: GuestConnectionState = .disconnected {
        didSet { connectionChanged(from: oldValue) }
    }
    @Published private(set) var states: [DiagnosticState]

    private let listener: GuestListener
    /// What the machines on the wire have said they can do. Shared with every
    /// other page that gates a control, injectable so a test gets its own.
    let capabilities: GuestCapabilityRecord
    /// Per-verb run generation, so a late answer from a superseded run
    /// cannot land on top of a newer one.
    private var generation: [String: Int] = [:]
    /// Whether this connection's command table has been asked for. One ask
    /// per machine: a command table does not change inside a launch.
    private var askedForCommands = false
    /// The connected machine's `help` table, kept as the machine wrote it.
    ///
    /// **Nil is "it has not answered yet", never "it has no commands"** — the
    /// distinction `GuestCapabilityEvidence.commandNames` is built on. It is
    /// held here so the gate can be handed the table this page already asked
    /// for: a second `help` per card would be this side asking a machine
    /// something it has already answered.
    private var commandNames: Set<String>?

    init(listener: GuestListener,
         capabilities: GuestCapabilityRecord = .shared) {
        self.listener = listener
        self.capabilities = capabilities
        states = GuestDiagnostics.all.map { DiagnosticState(diagnostic: $0) }
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func state(id: String) -> DiagnosticState? {
        states.first { $0.id == id }
    }

    /// **Whether the machine on the wire serves one diagnostic verb**, and the
    /// sentence to show when it does not.
    ///
    /// One requirement — the verb itself — because that is genuinely all this
    /// card needs; there is no projection row per diagnostic and inventing one
    /// to have something to name would be a second answer about the same
    /// machine. The command table is the one this page already asked for, so a
    /// dark button costs no extra `help`.
    ///
    /// A machine that has not listed its commands leaves this `unsettled`,
    /// which is ENABLED: unproven is not a no, and the run is what settles it.
    func gate(for diagnostic: GuestDiagnostic) -> GuestCapabilityGate.Decision {
        GuestCapabilityGate.decide(
            requiring: [diagnostic.verb],
            in: capabilities.evidence(for: connection, listener: listener,
                                      commandNames: commandNames))
    }

    /// The sentence a dark Run button owes the reader, when the card is not
    /// already saying it in better words.
    ///
    /// Nil for `notServed`, deliberately: the card's own body writes that case
    /// (`notServedSentence`) and names the sibling guest that answers the verb,
    /// which is more than the gate can know. This covers the rest — a machine
    /// that refused the verb by name, or none attached at all — so that no
    /// greyed button on this page is ever left standing beside nothing.
    func unavailableNote(for state: DiagnosticState) -> String? {
        let decision = gate(for: state.diagnostic)
        guard decision.deservesAVisibleReason,
              state.serving != .notServed else { return nil }
        return decision.explanation
    }

    /// Run one diagnostic, replacing whatever it held.
    ///
    /// A run is allowed while `serving` is `unknown`, deliberately: unproven
    /// is not "no", and the machine's own refusal is a better answer than
    /// this side declining to ask. It is not offered once the machine has
    /// said it does not have the verb.
    func run(_ probe: AgentIntegrationDiagnosticProbe) {
        let verb = probe.rawValue
        guard isConnected,
              let idx = states.firstIndex(where: { $0.id == verb }),
              states[idx].serving != .notServed,
              !states[idx].isRunning
        else { return }
        let gen = (generation[verb] ?? 0) + 1
        generation[verb] = gen
        states[idx].rows = []
        states[idx].refusal = nil
        states[idx].isRunning = true

        /* No local watchdog here, unlike the agent path: a person watching a
           spinner can see that nothing has come back, which is the same
           reason the console's own wait is generous. */
        listener.runCommand(verb) { [weak self] result in
            guard let self,
                  self.generation[verb] == gen,
                  let idx = self.states.firstIndex(where: { $0.id == verb })
            else { return }
            self.states[idx].isRunning = false
            self.states[idx].ranAt = Date()
            guard result.ok, let rows = result.output?[verb] else {
                let code = result.error?.code ?? ""
                if AgentIntegrationCapabilityNames.isRefusal(code) {
                    /* The machine answered the availability question by
                       refusing the verb by name. Recorded as what it is —
                       this Mac does not serve it — rather than as a failure,
                       which is the difference between "not here" and
                       "broken". */
                    self.states[idx].serving = .notServed
                    self.states[idx].refusal = nil
                    /* Written down where the gate can read it, in the
                       machine's own words. Without this the card would say
                       "not available on this Mac" underneath a Run button that
                       still worked: `help` had listed the verb, so the gate
                       would go on answering `allowed` while the machine had
                       already refused it by name. */
                    self.capabilities.noteRefusal(
                        verb, by: self.connection.key,
                        code: code, message: result.error?.message)
                    return
                }
                self.states[idx].serving = .served
                self.states[idx].refusal = result.error?.message
                    ?? "This Mac declined the diagnostic and said no more."
                return
            }
            self.states[idx].serving = .served
            // It answered. The strongest evidence there is that it serves the
            // verb, and the gate should not need `help` to have said so.
            self.capabilities.noteServed(verb, by: self.connection.key)
            self.states[idx].rows = rows.enumerated().map { pair in
                DiagnosticRow(index: pair.offset,
                              label: pair.element.first ?? "",
                              value: pair.element.count > 1
                                  ? pair.element[1] : "")
            }
        }
    }

    /// Ask the connected machine which commands it has, once per connection,
    /// so a card can say what this Mac serves before anyone spends a
    /// full-screen read finding out.
    ///
    /// The same request the console's completions use and the same one the
    /// capability ledger reads for the agent surface — the machine's own
    /// `help`. A machine that never answers leaves all three `unknown`,
    /// which the page states rather than guessing past.
    func askWhatThisMacServes() {
        guard isConnected, !askedForCommands else { return }
        askedForCommands = true
        listener.runCommand("help", line: "") { [weak self] result in
            guard let self else { return }
            // The first column of `help`'s list form is the command names —
            // the one structural promise that output makes (contract,
            // `help`). Everything else in there is prose for a human.
            guard result.ok, let rows = result.output?["help"] else { return }
            let names = Set(rows.compactMap { $0.first })
            guard !names.isEmpty else { return }
            self.commandNames = names
            for i in self.states.indices {
                /* Only a POSITIVE answer moves a card off `unknown` in this
                   direction as well: a table that came back without the verb
                   is evidence the machine does not have it, which is exactly
                   what the ledger reads it as. */
                self.states[i].serving =
                    names.contains(self.states[i].diagnostic.verb)
                        ? .served : .notServed
            }
        }
    }

    // MARK: - Guest scope

    private func connectionChanged(from old: GuestConnectionState) {
        guard connection != old else { return }
        if case .switched(let restored) = cache.focus(connection.key,
                                                      parking: snapshot()) {
            generation = [:]
            let fresh = restored
                ?? Snapshot(
                    states: GuestDiagnostics.all.map {
                        DiagnosticState(diagnostic: $0)
                    },
                    askedForCommands: false,
                    commandNames: nil)
            // A run in flight belonged to the machine we left; the listener
            // has already failed whatever request was outstanding.
            states = fresh.states.map { state in
                var state = state
                state.isRunning = false
                return state
            }
            askedForCommands = fresh.askedForCommands
            commandNames = fresh.commandNames
            askWhatThisMacServes()
            return
        }
        if case .connected = connection {
            askWhatThisMacServes()
            return
        }
        // The link dropped: nothing is still running. Readings already taken
        // stay on screen — they are what that Mac said.
        for i in states.indices where states[i].isRunning {
            states[i].isRunning = false
        }
        /* The next connection gets its own `help`. The same machine dialling
           back in may be a redeployed build with a different command table,
           and a served set carried across that would be this page asserting
           something it has not asked. */
        askedForCommands = false
        commandNames = nil
    }

    /// A machine leaving the roster takes its readings with it.
    ///
    /// The other half of the census's choice, and the difference is what the
    /// state CLAIMS: a census describes hardware that changes on a timescale
    /// of screwdrivers, while these describe a running build — which verbs it
    /// has, what its last transfer did, what its screen read cost while it
    /// was up. A redeploy changes all of that, and a reading restored under a
    /// new build's name would be the wrong kind of wrong.
    func guestLeft(_ key: GuestKey) {
        cache.forget(key)
    }

    private func snapshot() -> Snapshot {
        Snapshot(states: states, askedForCommands: askedForCommands,
                 commandNames: commandNames)
    }
}
