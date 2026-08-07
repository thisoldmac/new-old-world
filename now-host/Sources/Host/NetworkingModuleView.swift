import SwiftUI

/// The connected Mac's networking.
///
/// Renders what the guest sent and adds no facts of its own. The guest
/// groups, orders and words everything — including why a group is empty —
/// so this file is a table and a set of resting states.
struct NetworkingModuleView: View {
    @ObservedObject var model: NetworkingModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onAppear {
            /* Asked on first sight rather than on a click: two documented
               calls and a bounded walk is cheap enough that making
               someone press a button to see their own address would be
               ceremony. */
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Networking").font(.headline)
                Spacer()
                Button(model.hasRun ? "Refresh" : "Ask") { model.refresh() }
                    .disabled(model.isLoading || !model.isServed)
            }
            Text("\(machinePossessive) link, its "
                 + "address, and the network hardware it has — as that "
                 + "machine reports them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let at = model.fetchedAt {
                Text("as of \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

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
                    detail: "The PowerPC build serves it. Nothing is wrong "
                          + "with that machine.")
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
        }
    }

    private func sectionCard(_ section: NetworkingModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.headline)

            if section.rows.isEmpty {
                /* A group with no rows always carries a sentence, written
                   by the guest. The `undocumented` one is the page's
                   whole argument and must not read as a failure: it is
                   secondary text, not red, and there is no button beside
                   it suggesting a retry would help. */
                Text(section.sentence ?? "Nothing to show.")
                    .font(.callout)
                    .foregroundStyle(section.reason == "undocumented"
                                     ? .secondary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(section.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .frame(width: 150, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
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
