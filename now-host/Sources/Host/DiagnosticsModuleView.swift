import SwiftUI

/// The Diagnostics page: the three measurements the guests can make of
/// themselves, run and read from this Mac.
///
/// **Three cards rather than a rail with one detail pane**, and the reason is
/// the availability question rather than taste. The three are served by
/// different guests, so at any moment one or two of them are simply not
/// answerable by the machine on the wire — and a rail hides that behind a
/// selection, where a card can say it in place. Each card carries what the
/// diagnostic measures, what it costs before anyone spends it, and either a
/// button or the sentence explaining why there is none.
///
/// **A card for a verb this Mac does not serve shows no button.** A disabled
/// control with no explanation is the thing this page must not be: it reads
/// as broken. The card says which Mac model answers it instead, so the
/// absence reads as what it is.
struct DiagnosticsModuleView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isConnected {
                cards
            } else {
                disconnected
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Diagnostics")
                .font(.headline)
            Text("What \(model.connection.peerLabel) can measure about "
                    + "itself. Which of these it serves is its own answer, "
                    + "read from its command table.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: the three cards

    /// Written out rather than looped, because each button is a distinct
    /// affordance the projection rows name as their app-UI evidence — one row
    /// per diagnostic, since availability is per row. A `ForEach` would name
    /// none of them.
    @ViewBuilder
    private var cards: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let state = model.state(id: "vprobe") {
                    card(state) { model.run(.vprobe) }
                }
                if let state = model.state(id: "shotdiag") {
                    card(state) { model.run(.shotdiag) }
                }
                if let state = model.state(id: "putstat") {
                    card(state) { model.run(.putstat) }
                }
            }
            .padding(12)
        }
    }

    private func card(_ state: DiagnosticState,
                      run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(state.diagnostic.title)
                            .font(.title3.weight(.semibold))
                        Text(state.diagnostic.verb)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(state.diagnostic.measures)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                action(state, run: run)
            }
            Label(state.diagnostic.cost, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let caveat = state.diagnostic.caveat {
                /* Always shown, run or not. It is the sentence that stops a
                   red row on this card being read as a broken Screenshots
                   page, and a caveat that appears only after the misleading
                   result has arrived is a footnote nobody read in time. */
                Label(caveat, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            body(state)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// The button, or the sentence that replaces it.
    @ViewBuilder
    private func action(_ state: DiagnosticState,
                        run: @escaping () -> Void) -> some View {
        switch state.serving {
        case .notServed:
            EmptyView()
        case .served, .unknown:
            HStack(spacing: 6) {
                if state.isRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    run()
                } label: {
                    Label(state.hasRun ? "Run Again" : "Run",
                          systemImage: "play.fill")
                }
                .disabled(!model.isConnected || state.isRunning)
            }
        }
    }

    @ViewBuilder
    private func body(_ state: DiagnosticState) -> some View {
        switch state.serving {
        case .notServed:
            /* Not an error, and it must not look like one. The verb is
               absent from this machine's own command table — which is a fact
               about which NOW guest is on the wire, not about whether that
               Mac is well — so the line names the sibling that answers it and
               stops there. */
            Label(notServedSentence(state.diagnostic),
                  systemImage: "minus.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown where !state.hasRun:
            Label("This Mac has not listed its commands yet, so whether it "
                    + "serves this is not established. Running it asks — and "
                    + "it answers in its own words if it cannot.",
                  systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if let refusal = state.refusal {
                /* The guest's own sentence, verbatim. It is the machine's
                   account of why it could not measure — a busy probe, a disk
                   that said no — and rewording it here would be this side
                   explaining a machine it did not ask. */
                Label(refusal, systemImage: "hand.raised.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
                /* The other silence. A machine that answered `ok` and sent
                   no rows has told us nothing, and until this line existed
                   the card drew an empty space for it — indistinguishable
                   from a card of zeroes, which is a real measurement. The
                   two facts now look different because they are. */
                Label("This Mac answered but sent no measurements. That is "
                        + "not a reading of zero — it is no reading at all.",
                      systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notServedSentence(_ diagnostic: GuestDiagnostic) -> String {
        let elsewhere: String
        switch diagnostic.probe {
        case .vprobe:
            /* Both guests serve it, so a machine without it is neither
               model as this host knows them — an older build, most likely.
               Nothing here guesses which. */
            elsewhere = "Both NOW guests normally serve it, so this build "
                + "predates it."
        case .shotdiag:
            elsewhere = "The 68K guest serves it; the Carbon guest does not."
        case .putstat:
            elsewhere = "The Carbon guest serves it; the 68K guest does not."
        }
        return "Not available on this Mac: \(diagnostic.verb) is not in its "
            + "command table. Nothing is wrong with the machine — "
            + elsewhere
    }

    /// `putstat` read as an answer: the last transfer, or the sentence that
    /// replaces it, and always the counters that prove the probe answered.
    ///
    /// **A Mac that has received nothing says so in words.** Eleven zeroes is
    /// the visual shape of a feature that failed to load, and this card's own
    /// subtitle already predicts the state — so the page states it instead of
    /// making a person infer it from a table. The live counters stay on
    /// screen underneath because they are the evidence: they came back
    /// non-zero from the same response, which is what tells the reader the
    /// probe worked. The probe not answering at all looks nothing like this
    /// (see `DiagnosticState.answeredWithNothing`).
    @ViewBuilder
    private func transfer(_ reading: TransferDiagnosticsReading) -> some View {
        if reading.hasReceivedNothing {
            VStack(alignment: .leading, spacing: 8) {
                Label("No file has been received by this Mac since New Old "
                        + "World started there, so there is no transfer to "
                        + "describe. Nothing is wrong: these counters "
                        + "describe the LAST received file, and there has "
                        + "not been one yet. Send it a file and this fills "
                        + "in.",
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

    private func rows(_ rows: [DiagnosticRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .frame(width: 180, alignment: .leading)
                    Text(row.value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var disconnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Mac Connected")
                .font(.title3.weight(.semibold))
            Text("The other Mac dials this one. Once it connects, the "
                    + "diagnostics it serves can be run and read here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
