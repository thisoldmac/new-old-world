import SwiftUI

/// One record, opened from the history card: an identity header, a facts
/// grid, and the related records — each of THOSE tappable, pivoting within
/// this same sheet with a Back button rather than stacking windows.
struct MCPEntityDetailSheet: View {
    let entity: MCPInspectedEntity
    @ObservedObject var model: MCPRecordsModel
    @Environment(\.dismiss) private var dismiss

    /// The pivot trail. The last element is what the sheet shows.
    @State private var path: [MCPInspectedEntity] = []
    @State private var detail = MCPEntityDetail()
    @State private var loading = true

    private var current: MCPInspectedEntity { path.last ?? entity }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(width: 460, height: 520)
        .task(id: current) {
            loading = true
            detail = await model.detail(for: current)
            loading = false
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !path.isEmpty {
                Button {
                    path.removeLast()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .controlSize(.small)
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(10)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                factsGrid
                if !detail.sessions.isEmpty {
                    sessionsSection
                }
                if !detail.actions.isEmpty {
                    actionsSection
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(detail.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var factsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14,
             verticalSpacing: 4) {
            ForEach(detail.facts) { fact in
                GridRow {
                    Text(fact.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(fact.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .font(.headline)
            ForEach(detail.sessions) { session in
                Button {
                    path.append(.session(session.id))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName:
                            "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.secondary)
                        Text(session.sessionKey ?? "Session \(session.id)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent actions")
                .font(.headline)
            ForEach(detail.actions) { row in
                Button {
                    path.append(.action(row.id))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.action.outcome == .answered
                            ? "checkmark.circle" : "hand.raised.circle")
                            .foregroundStyle(row.action.outcome == .answered
                                ? Color.secondary : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AgentActivityEvent.title(
                                for: row.action.capability))
                                .font(.callout)
                            Text("\(row.agentName)"
                                + (row.targetMachine.map { " · \($0)" }
                                    ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Self.clock.string(from: row.action.at))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
