import SwiftUI

/// The connected Mac's networking, as a control panel rather than a list.
///
/// Renders what the guest sent and adds no facts of its own. The guest
/// groups, orders and words everything — including why a group is empty —
/// so the hierarchy a person reads here (the link, then the addressing,
/// then the hardware, then what cannot be asked) is the guest's own order
/// preserved, not a taxonomy invented on this side. That distinction is
/// the reason this page can gain a fifth group without a host change.
///
/// What this file DOES add is shape: a verdict at the top, a state beside
/// every group's name, and rows in one aligned grid instead of four. All
/// of it derives from the guest's own state TOKEN — never from its prose.
///
/// **No control here can act, so none is drawn.** `net` reads; the
/// contract has no verb that sets an address, renews a lease or brings a
/// port up. A switch that does nothing is worse than an empty section, so
/// the page says once, at the foot, where controls will go when they
/// exist — rather than four times, once per group, in the shape of things
/// that look clickable.
struct NetworkingModuleView: View {
    @ObservedObject var model: NetworkingModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .onAppear {
            /* Asked on first sight rather than on a click: two documented
               calls and a bounded walk is cheap enough that making
               someone press a button to see their own address would be
               ceremony.

               Asked ONCE, and never on a timer. No guest pushes a network
               state change, so there is no moment to subscribe to — and a
               poll would spend the guest's cooperative time re-answering a
               question nobody asked twice. The button is how this page
               gets a newer answer, on purpose. */
            if !model.hasRun { model.refresh() }
        }
    }

    /// The machine this page is about — its own name once it has sent
    /// one — as the owner of what the page shows, at the head of a
    /// sentence.
    private var machinePossessive: String {
        MachineNaming.startingSentence(
            MachineNaming.possessive(model.connection))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Networking").font(.headline)
                if model.hasRun, model.isServed, model.refusal == nil {
                    healthChip
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button(model.hasRun ? "Refresh" : "Ask") { model.refresh() }
                    .disabled(model.isLoading || !model.isServed)
            }
            Text("\(machinePossessive) link, its "
                 + "address, and the network hardware it has — as that "
                 + "machine reports them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// The page's verdict, in the one place a person looks first.
    ///
    /// Counts, not adjectives: "3 of 4 groups answered" is checkable
    /// against the cards below it, where "Healthy" would not be.
    private var healthChip: some View {
        let health = model.health
        return chip(text: healthText(health),
                    tint: health == .silent ? .orange : .secondary,
                    filled: health == .reporting)
    }

    private func healthText(_ health: NetworkingModel.Health) -> String {
        let total = model.sections.count
        switch health {
        case .unknown:   return "nothing to show"
        case .reporting: return "all \(total) groups answered"
        case .partial:   return "\(model.reportedCount) of \(total) answered"
        case .silent:    return "no group answered"
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if !model.isServed {
            /* Not an error. A 68K guest does not serve this verb, and
               neither does a build from before it existed - nothing was
               denied. */
            /* "This Mac" here meant the machine being driven, which is
               the one machine on this page that "this Mac" cannot mean. */
            resting("\(MachineNaming.title(model.connection)) does not "
                    + "answer `net`.",
                    detail: "Served by the PowerPC build only.")
        } else if let refusal = model.refusal {
            /* The machine's own words, not ours. */
            resting("\(MachineNaming.title(model.connection)) declined.",
                    detail: refusal, isProblem: true)
        } else if model.isLoading && model.sections.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking…").foregroundStyle(.secondary)
            }
        } else if model.sections.isEmpty {
            resting("Nothing asked yet.",
                    detail: "Press Ask to read "
                          + "\(MachineNaming.possessive(model.connection)) "
                          + "networking.")
        } else {
            ForEach(model.sections) { section in
                sectionCard(section)
            }
            readingFooter
        }
    }

    private func sectionCard(_ section: NetworkingModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                stateChip(section.state)
            }

            if section.rows.isEmpty {
                /* A group with no rows always carries a sentence, written
                   by the guest. The `undocumented` one is the page's
                   whole argument and must not read as a failure: it is
                   secondary text, not red, and there is no button beside
                   it suggesting a retry would help. */
                Text(section.sentence ?? "Nothing to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                /* One grid, so every label column in a card lines up on
                   its own longest label instead of on a width this file
                   guessed. The old fixed 150pt column truncated a long
                   label and stranded a short one in whitespace. */
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(section.rows) { row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Text(row.value)
                                /* Addresses, masks and byte counts read
                                   down a column; proportional digits make
                                   them ragged. This is typography and
                                   asserts nothing about the value. */
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14)))
    }

    /// When the page was read, and where its controls will be when there
    /// are any.
    ///
    /// One statement at the foot, not a placeholder inside every card:
    /// four empty control rails would be more of this page than its
    /// contents, and each would have to guess which control that group is
    /// going to get — a guess this side has no business making before the
    /// contract does.
    private var readingFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let at = model.fetchedAt {
                Text("Read at \(at.formatted(date: .omitted, time: .standard))"
                     + ". Refresh to re-read.")
            }
            Text("Read-only: `net` reports, it does not set. Controls "
                 + "appear in the group they change once the contract "
                 + "carries a verb for it.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - Small parts

    private func stateChip(_ state: NetworkingModel.Section.State) -> some View {
        chip(text: state.label,
             tint: state.isProblem ? .orange : .secondary,
             filled: state == .reported)
    }

    /// One chip shape for the page.
    ///
    /// `filled` is the only difference an answered group gets: colour is
    /// reserved for the single state that is the machine's doing, so a
    /// green tick beside three groups and a grey one beside the fourth
    /// cannot read as three passes and a failure.
    private func chip(text: String, tint: Color, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(filled ? Color.accentColor : tint.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(tint == .orange ? Color.orange : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .fixedSize()
    }

    private func resting(_ title: String, detail: String,
                         isProblem: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isProblem ? Color.orange : .primary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
