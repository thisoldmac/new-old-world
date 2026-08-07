import AppKit
import SwiftUI

/// The Diagnostics page: the three measurements the guests can make of
/// themselves, run and read from this Mac.
///
/// **A list on the left, one diagnostic's detail on the right** — the same
/// shape as Hardware next door, because these are the same gesture: pick a
/// measurement, spend it, read what came back. The page held three stacked
/// cards before, and each card carried a description, a cost, a caveat and a
/// table of rows; three of those at once is a page where the measurement a
/// person came for is somewhere below the fold, under prose they have already
/// read twice.
///
/// **Every diagnostic is listed, including the ones the machine on the wire
/// cannot run — and they stay selectable.** That is the difference this page
/// exists to draw. The three verbs are served by different guests, so at any
/// moment one or two of them are simply not answerable here, and a row that
/// refused selection could never say why it was grey. So the row is drawn
/// dimmed and marked, selecting it is normal, and what the machine's refusal
/// disables is the **Run button** — beside the sentence saying which machine
/// cannot and why. A greyed control with no explanation is indistinguishable
/// from a bug.
///
/// **"Cannot be run here" and "has not been run yet" are different facts** and
/// the page never lets one wear the other's clothes: availability is the row's
/// badge and the button's state, and whether a reading exists is what the
/// detail pane shows underneath. Both come off `DiagnosticsModel`, whose
/// answer is `GuestCapabilityGate`'s — the same one every other page gets
/// about the same machine, never this page's private reading.
struct DiagnosticsModuleView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isConnected {
                HSplitView {
                    probeList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                    detail
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            } else {
                disconnected
            }
        }
    }

    // MARK: header

    /// The machine every sentence on this page is about. It is never this
    /// one: the page reads what the driven machine measures about itself,
    /// and the copy here used to say "this Mac" for all of it.
    private var machine: String { model.machine }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Diagnostics")
                .font(.headline)
            Text("What \(machine) can measure about "
                    + "itself. Which of these it serves is its own answer, "
                    + "read from its command table.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: the list

    private var probeList: some View {
        List(selection: $model.selection) {
            ForEach(model.states) { state in
                row(state).tag(state.id)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ state: DiagnosticState) -> some View {
        let availability = model.availability(for: state)
        return HStack(spacing: 8) {
            badge(state, availability)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.diagnostic.title)
                Text(subtitle(state, availability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        /* Dimmed rather than `.disabled`. A disabled row cannot be selected,
           and a row that cannot be selected can never show the sentence
           explaining itself — which is the whole reason it is still on the
           list. The Run button is what the refusal disables. */
        .opacity(availability.isRunnable ? 1 : 0.55)
        .help(availability.reason ?? state.diagnostic.title)
    }

    /// The row's one-glance state. Availability first, because a verb this
    /// machine does not have has no result state worth drawing.
    @ViewBuilder
    private func badge(_ state: DiagnosticState,
                       _ availability: DiagnosticAvailability) -> some View {
        if state.isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else if !availability.isRunnable {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .semibold))
        } else if state.refusal != nil {
            Image(systemName: "hand.raised.circle")
                .foregroundStyle(.orange)
                .font(.system(size: 11, weight: .semibold))
        } else if state.answeredWithNothing {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .font(.system(size: 11, weight: .semibold))
        } else if !state.rows.isEmpty {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11, weight: .semibold))
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    /// The caption under a row's title. **"Not served here" and "not run yet"
    /// are never interchangeable** — the first is about the machine and the
    /// second is about what anyone has spent.
    private func subtitle(_ state: DiagnosticState,
                          _ availability: DiagnosticAvailability) -> String {
        if state.isRunning { return "measuring…" }
        if !availability.isRunnable { return "not served here" }
        if state.refusal != nil { return "refused" }
        if state.answeredWithNothing { return "answered with nothing" }
        if !state.rows.isEmpty {
            let n = state.rows.count
            return "\(n) \(n == 1 ? "row" : "rows")"
        }
        return "not run yet"
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if let state = model.selectedState {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(state)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        about(state)
                        reason(state)
                        results(state)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        } else {
            emptyState(symbol: "sidebar.left", title: "Select a diagnostic",
                       message: "Pick one on the left to see what it "
                           + "measures, what it costs, and what it said.")
        }
    }

    /// Title, verb, and the Run button — **present whatever the machine
    /// serves, dark when it does not.**
    ///
    /// Dark rather than absent: a control that is simply not drawn cannot
    /// tell anyone why, and its disappearance moves everything under it every
    /// time a machine connects or leaves. The sentence lives directly below
    /// (`reason`), where the eye already is.
    private func detailHeader(_ state: DiagnosticState) -> some View {
        let availability = model.availability(for: state)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.diagnostic.title).font(.headline)
                Text(state.diagnostic.verb)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if state.isRunning {
                ProgressView().controlSize(.small)
            }
            if !state.rows.isEmpty {
                Button {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(model.copyText(for: state),
                                    forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copies the rows as text, in \(machine)'s own wording.")
            }
            Button {
                run(state)
            } label: {
                Label(state.hasRun ? "Run Again" : "Run",
                      systemImage: "play.fill")
            }
            .disabled(!availability.isRunnable || !model.isConnected
                      || state.isRunning)
            .help(availability.reason
                  ?? "Runs \(state.diagnostic.verb) on \(machine).")
        }
        .padding(12)
    }

    /// The three verbs written out, rather than `model.run(state.diagnostic
    /// .probe)` reaching the same code in one line.
    ///
    /// Each of these literals is a projection row's declared app-UI evidence
    /// (`GuestDiagnosticsProjection`, `faces[.appUI].symbol`), and
    /// `HostFaceParityTests` reads this file to check the affordance it names
    /// is really here. A dispatch through the value would name none of them,
    /// and the row's claim to have an app-UI face would stop being provable —
    /// which is the whole point of the claim.
    private func run(_ state: DiagnosticState) {
        switch state.diagnostic.probe {
        case .vprobe: model.run(.vprobe)
        case .shotdiag: model.run(.shotdiag)
        case .putstat: model.run(.putstat)
        }
    }

    private func about(_ state: DiagnosticState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.diagnostic.measures(model.connection))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(state.diagnostic.cost, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let caveat = state.diagnostic.caveat {
                /* Always shown, run or not. It is the sentence that stops a
                   red row here being read as a broken Screenshots page, and a
                   caveat that appears only after the misleading result has
                   arrived is a footnote nobody read in time. */
                Label(caveat, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why the Run button is dark, when it is. Nothing at all when it is not:
    /// an enabled control does not get to explain itself.
    @ViewBuilder
    private func reason(_ state: DiagnosticState) -> some View {
        let availability = model.availability(for: state)
        if availability.deservesAVisibleReason, let text = availability.reason {
            Label(text, systemImage: "minus.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: what came back

    @ViewBuilder
    private func results(_ state: DiagnosticState) -> some View {
        if let refusal = state.refusal {
            /* The guest's own sentence, verbatim. It is the machine's account
               of why it could not measure — a busy probe, a disk that said
               no — and rewording it here would be this side explaining a
               machine it did not ask. */
            Label(refusal, systemImage: "hand.raised.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let reading = state.transferReading {
            transfer(reading)
        } else if !state.rows.isEmpty {
            rows(state.rows)
        } else if state.isRunning {
            Text("Measuring…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if state.answeredWithNothing {
            /* The other silence. A machine that answered `ok` and sent no
               rows has told us nothing, and until this line existed the page
               drew an empty space for it — indistinguishable from a table of
               zeroes, which is a real measurement. */
            Label("\(MachineNaming.startingSentence(machine)) answered but "
                    + "sent no measurements. That is not a reading of zero — "
                    + "it is no reading at all.",
                  systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.availability(for: state).isRunnable {
            /* Runnable and never run. Said in words, because an empty space
               under a description is the one place a reader cannot tell
               "nothing came back" from "nothing was asked". */
            VStack(alignment: .leading, spacing: 6) {
                Label("Not run yet. Running it spends what the line above "
                        + "says it costs, on \(machine).",
                      systemImage: "play.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                /* And whether it CAN be run is a separate open question
                   here: nothing has listed this machine's commands. The
                   button stays live — unproven is not a no — but the reader
                   is told the run is also the asking. */
                if case .unproven = model.availability(for: state),
                   state.serving == .unknown {
                    Label("\(MachineNaming.startingSentence(machine)) has "
                            + "not listed its commands yet, so whether it "
                            + "serves this is not established. Running it "
                            + "asks — and it answers in its own words if it "
                            + "cannot.",
                          systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// `putstat` read as an answer: the last transfer, or the sentence that
    /// replaces it, and always the counters that prove the probe answered.
    ///
    /// **A Mac that has received nothing says so in words.** Eleven zeroes is
    /// the visual shape of a feature that failed to load, and this page's own
    /// description already predicts the state — so it states it instead of
    /// making a person infer it from a table. The live counters stay on
    /// screen underneath because they are the evidence: they came back
    /// non-zero from the same response, which is what tells the reader the
    /// probe worked. The probe not answering at all looks nothing like this
    /// (see `DiagnosticState.answeredWithNothing`).
    @ViewBuilder
    private func transfer(_ reading: TransferDiagnosticsReading) -> some View {
        if reading.hasReceivedNothing {
            VStack(alignment: .leading, spacing: 8) {
                Label("No file has been received by \(machine) since New "
                        + "Old World started there, so there is no "
                        + "transfer to describe. Nothing is wrong: these "
                        + "counters describe the LAST received file, and "
                        + "there has not been one yet. Send it a file and "
                        + "this fills in.",
                      systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !reading.live.isEmpty {
                    Text("Live on the connection right now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    rows(reading.live)
                }
            }
        } else {
            rows(reading.transfer + reading.live)
        }
    }

    /// The measurement itself: labels and values as the machine wrote them.
    ///
    /// **The values scroll sideways inside this box, never the page.** These
    /// are hex dumps and byte samples, and a value wider than the pane must
    /// not either wrap into an unreadable ribbon or push the whole detail
    /// side out from under the window. Selectable, because the reason anyone
    /// runs these is to paste a number somewhere else.
    private func rows(_ rows: [DiagnosticRow]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .frame(width: 180, alignment: .leading)
                        Text(row.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }

    /// The project's plain empty-state: a glyph, a title, a sentence. Kept
    /// local so it works on macOS 13 (ContentUnavailableView is 14+).
    private func emptyState(symbol: String, title: String,
                            message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var disconnected: some View {
        emptyState(
            symbol: "cable.connector.slash",
            title: "No \(MachineNaming.properNoun) Connected",
            message: "The \(MachineNaming.commonNoun) dials "
                + "\(MachineNaming.thisMac). Once it connects, the "
                + "diagnostics it serves can be run and read here.")
    }
}
