import Combine
import Foundation
import NOWAgentIntegration

/// One diagnostic as this side needs to know it: the verb, what it answers,
/// what it costs, and the one thing a reader must not conclude from it.
///
/// The `probe` is the contract's own name and the wire value
/// (`AgentIntegrationDiagnosticProbe`), so nothing here is a second spelling
/// of a verb. Everything else is written for the person at this Mac — about
/// the OTHER one. Every sentence below measures the machine being driven, so
/// the ones that name a machine take it from `MachineNaming` rather than
/// spelling it: this page said "this Mac" in five places while meaning the
/// far end, which is the one error a reader has no way to detect.
struct GuestDiagnostic: Identifiable, Equatable, Sendable {
    let probe: AgentIntegrationDiagnosticProbe
    let title: String
    /// What the machine measures, in a sentence — composed around whatever
    /// that machine is called right now.
    ///
    /// A function rather than a stored sentence because all three of these
    /// name the machine, and its name arrives at hello: a sentence frozen at
    /// startup can only ever say the generic phrase, which is how "this Mac"
    /// got written here in the first place. It takes the connection rather
    /// than a phrase so that `MachineNaming` — not this file — decides what
    /// the machine is called.
    let measures: @Sendable (_ connection: GuestConnectionState) -> String
    /// What it costs that machine, said before anyone spends it.
    let cost: String
    /// A conclusion this answer does NOT support. Present on exactly one of
    /// the three today, and it earns its place — see `vprobe` below.
    let caveat: String?

    var verb: String { probe.rawValue }
    var id: String { probe.rawValue }

    /// Identity is the verb. Everything else here is prose ABOUT that verb —
    /// including a closure, which has no equality of its own — so two values
    /// carrying the same probe are the same diagnostic.
    static func == (lhs: GuestDiagnostic, rhs: GuestDiagnostic) -> Bool {
        lhs.probe == rhs.probe
    }
}

enum GuestDiagnostics {
    /// The three, in the order the page draws them: the two measurements of
    /// the screen first, since they are the expensive ones and the pair a
    /// person compares, then the free read of the transfer counters.
    static let all: [GuestDiagnostic] = [
        GuestDiagnostic(
            probe: .vprobe,
            title: "Framebuffer Read Cost",
            measures: { connection in
                "What reading \(MachineNaming.possessive(connection)) screen "
                + "memory costs, by access method: raw reads at 8, 16, 32 "
                + "and 64 bits against the CopyBits baseline, whether a "
                + "reread hits a cache, whether a partial read scales, and "
                + "whether the raw reads are pixel-faithful."
            },
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
            measures: { connection in
                "Where a capture actually read from: the framebuffer base "
                + "as \(MachineNaming.sentence(connection)) resolved it, "
                + "that base through StripAddress, whether it is in 32-bit "
                + "addressing at the moment of the walk, and row 0's first "
                + "sixteen bytes as the walk sees them beside the same row "
                + "as CopyBits copies it. Identical samples mean the base "
                + "is right and the fault is downstream; different ones "
                + "name the byte."
            },
            cost: "It stages one real capture and throws it away, so it "
                + "costs what a screenshot costs and wants a still screen. "
                + "No image is produced and nothing is transferred.",
            caveat: nil),
        GuestDiagnostic(
            probe: .putstat,
            title: "Transfer Diagnostics",
            measures: { connection in
                "Where the last file \(MachineNaming.sentence(connection)) "
                + "RECEIVED spent its time: bytes, chunk and write counts, "
                + "the milliseconds inside FSWrite against the whole "
                + "receive path, what a resume started from, and the "
                + "receive backlog. Measured there because that is the only "
                + "place the disk can be told apart from the wire."
            },
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

/// **What the page may offer for one diagnostic, and what it owes the reader
/// when the answer is no.**
///
/// The list on the left shows every diagnostic whether or not the machine on
/// the wire can run it, so each row has to carry which of three facts it is
/// in — and they are three, not two:
///
/// - `supported` — that machine has said it serves the verb.
/// - `unproven` — nobody has asked yet. **Runnable.** Unproven is not a no,
///   and the click is what settles it.
/// - `unsupported` — that machine said no. **Not runnable**, and it carries
///   the sentence saying so.
///
/// Whether the diagnostic has ever been RUN is a fourth, orthogonal fact
/// (`DiagnosticState.hasRun`) and lives apart on purpose: "cannot be run
/// here" and "has not been run yet" are the two things a grey row is read as,
/// and a page that cannot tell them apart tells the reader the wrong one.
enum DiagnosticAvailability: Equatable {
    case supported
    case unproven(String)
    case unsupported(String)

    /// Whether the Run button accepts a click.
    var isRunnable: Bool {
        switch self {
        case .supported, .unproven: return true
        case .unsupported: return false
        }
    }

    /// The sentence behind this answer. Nil only for `supported`, where
    /// there is nothing to explain.
    var reason: String? {
        switch self {
        case .supported: return nil
        case .unproven(let text), .unsupported(let text): return text
        }
    }

    /// Whether that sentence has to be on screen rather than in a tooltip.
    /// A dark button must explain itself where the eye already is; an
    /// enabled one that merely has not been proven does not get to nag.
    var deservesAVisibleReason: Bool {
        if case .unsupported = self { return true }
        return false
    }
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
/// **Eight of them describe the last file the driven machine RECEIVED; three
/// do not.**
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
/// one means "nothing has been received", the other means "that machine told
/// us nothing".
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
/// machine for its command table once per connection and says, per row,
/// whether that machine serves the verb. A row for a verb the driven machine
/// does not have does not offer a button that would do nothing, and does not
/// suggest anything is broken: the other Mac model answers it, and that is
/// what the row says.
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

    /// Which diagnostic the detail side is showing.
    ///
    /// **Every diagnostic is selectable, including the ones the machine
    /// cannot run.** That is the whole reason the list can afford to show
    /// them: a row that refuses selection is a row that can never say WHY it
    /// is grey, and "cannot be selected" is exactly how a person reads a
    /// broken app. What a machine's refusal disables is the Run button, and
    /// the reason travels with it (`availability(for:)`).
    ///
    /// It starts on the first row rather than nil, because an empty detail
    /// pane on a page with three fixed rows is a step a person has to take
    /// before the page says anything at all.
    @Published var selection: String? = GuestDiagnostics.all.first?.id

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

    /// The row the detail side is showing. Falls back to the first rather
    /// than to nothing: `selection` can only name a diagnostic this page has,
    /// and a nil detail pane would be a state the page has no copy for.
    var selectedState: DiagnosticState? {
        selection.flatMap { state(id: $0) } ?? states.first
    }

    /// The machine this page's sentences are about — never the one they are
    /// read on.
    var machine: String { MachineNaming.sentence(connection) }

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

    /// **The three-way answer the list and the detail pane both read**, with
    /// the sentence a disabled row owes its reader.
    ///
    /// One decision, asked once, so the greyed row on the left and the dark
    /// button on the right cannot disagree — and it is the gate's decision,
    /// the same one every other page gets about the same machine, never this
    /// page's private reading of `serving`.
    ///
    /// The one case where this page can say more than the gate is a verb
    /// absent from the machine's own command table: `notServedSentence` names
    /// the sibling guest that DOES answer it, which the gate has no way to
    /// know. That sentence wins there; everywhere else the gate's own words
    /// stand, including a machine that refused the verb by name and the case
    /// of nothing being connected at all.
    func availability(for state: DiagnosticState) -> DiagnosticAvailability {
        if state.serving == .notServed {
            return .unsupported(notServedSentence(state.diagnostic))
        }
        switch gate(for: state.diagnostic) {
        case .allowed:
            return .supported
        case .unsettled(let why):
            return .unproven(why)
        case .unsupported(let why), .noGuest(let why), .inapplicable(let why):
            return .unsupported(why)
        }
    }

    /// Why a verb absent from the machine's command table is not a fault.
    ///
    /// Not an error, and it must not look like one: the verb missing is a
    /// fact about WHICH NOW guest is on the wire, not about whether that Mac
    /// is well — so the sentence names the sibling that answers it and stops
    /// there. It lives on the model rather than in the view because it is the
    /// reason a control is dark, and a reason a test cannot read is a reason
    /// that can silently go missing.
    func notServedSentence(_ diagnostic: GuestDiagnostic) -> String {
        let elsewhere: String
        switch diagnostic.probe {
        case .vprobe:
            /* Both guests serve it, so a machine without it is neither model
               as this host knows them — an older build, most likely. Nothing
               here guesses which. */
            elsewhere = "Both NOW guests normally serve it, so this build "
                + "predates it."
        case .shotdiag:
            elsewhere = "The 68K guest serves it; the Carbon guest does not."
        case .putstat:
            elsewhere = "The Carbon guest serves it; the 68K guest does not."
        }
        return "Not available on \(machine): \(diagnostic.verb) is not in "
            + "its command table. Nothing is wrong with the machine — "
            + elsewhere
    }

    /// The selected reading as plain text, for the Copy button.
    ///
    /// Tab-separated in the guest's own order and wording, because these are
    /// measurements a person pastes into a note or a message beside a build
    /// stamp — reformatting them here would make the pasted number differ
    /// from the one on screen.
    func copyText(for state: DiagnosticState) -> String {
        state.rows.map { "\($0.label)\t\($0.value)" }
            .joined(separator: "\n")
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
              /* The same answer the button reads, so a run cannot reach the
                 wire through a path the UI says is closed — including the
                 case the button alone would miss, a machine that refused the
                 verb by name after `help` had listed it. */
              availability(for: states[idx]).isRunnable,
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
        listener.runScheduledCommand(
            verb, purpose: .command("diagnostics \(verb)"),
            workClass: .humanInteractive) { [weak self] result in
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
                       that machine does not serve it — rather than as a
                       failure,
                       which is the difference between "not here" and
                       "broken". */
                    self.states[idx].serving = .notServed
                    self.states[idx].refusal = nil
                    /* Written down where the gate can read it, in the
                       machine's own words. Without this the card would say
                       "not available" underneath a Run button that
                       still worked: `help` had listed the verb, so the gate
                       would go on answering `allowed` while the machine had
                       already refused it by name. */
                    self.capabilities.noteRefusal(
                        verb, by: self.connection.key,
                        code: code, message: result.error?.message)
                    return
                }
                self.states[idx].serving = .served
                /* The page names the machine directly above this line, so the
                   fallback says "it" — spelling the machine out again here
                   is where "this Mac" got written about the far end. */
                self.states[idx].refusal = result.error?.message
                    ?? "It declined the diagnostic and said no more."
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
    /// so a row can say what that machine serves before anyone spends a
    /// full-screen read finding out.
    ///
    /// The same request the console's completions use and the same one the
    /// capability ledger reads for the agent surface — the machine's own
    /// `help`. A machine that never answers leaves all three `unknown`,
    /// which the page states rather than guessing past.
    func askWhatThisMacServes() {
        guard isConnected, !askedForCommands else { return }
        askedForCommands = true
        /* This is enrichment, not the person's requested diagnostic. A guest
           that never answers `help` must not hold the shared admission lane
           for the generic 20-second script-safe watchdog; 1.8 seconds is the
           same sub-two-second automatic-work budget used by Mirror's Finder
           pages, after which the explicit Run is allowed to establish the
           capability directly. */
        listener.runScheduledCommand(
            "help", line: "", purpose: .command("diagnostics help"),
            workClass: .ambient, coalescingKey: "diagnostics-help",
            watchdogSeconds: 1.8) {
            [weak self] result in
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
