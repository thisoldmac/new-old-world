import SwiftUI

/// One product surface: NOW's own data-driven Mirror window, plus the host's
/// policy over the four named planes. The guest Workshop reports these same
/// resident facts read-only; it never becomes a second policy authority.
struct MirrorControlView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var mirrorWindow: NOWMirrorWindow
    @ObservedObject var timeline: MirrorActTimeline
    @ObservedObject var cycles: MirrorCycleTimeline

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    productCard
                    actsCard
                    cyclesCard
                    lifecycleCard
                    planesCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onAppear { model.refreshLifecycle() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Mirror").font(.headline)
                Spacer()
                if model.isLifecycleChecking {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") { model.refreshLifecycle() }
                    .disabled(model.isLifecycleChecking
                              || !model.connection.canCapture)
            }
            Text("A native, data-driven view of the connected classic Mac. "
                 + "State comes from that Mac; keyboard and mouse actions "
                 + "mutate it through NOW's interaction plane.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var productCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mirror this Mac").font(.headline)
                    Text(mirrorWindow.isOpen
                         ? "The native Mirror window is open."
                         : "Open one native Mirror window over NOW's wire.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(mirrorWindow.isOpen ? "Close Mirror" : "Open Mirror") {
                    if mirrorWindow.isOpen {
                        mirrorWindow.close()
                    } else {
                        mirrorWindow.show(
                            title: "Mirror — \(model.connection.peerLabel)")
                    }
                }
                .disabled(!mirrorWindow.isOpen && !model.connection.canCapture)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// **What the lane is doing, and where the last acts spent their time.**
    ///
    /// The 2026-08-04 PowerBook drive could not tell an act that was
    /// working slowly from one queued behind an act that was going to
    /// time out. Both look like a click that did nothing. The four clocks
    /// answer it, so they belong on screen and not only in a log file
    /// nobody opens mid-drive.
    private var actsCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Acts").font(.headline)
                Spacer()
                Text(timeline.depth == 0
                     ? "lane idle"
                     : timeline.depth == 1
                        ? "1 in flight"
                        : "1 in flight, \(timeline.depth - 1) waiting")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(timeline.depth > 1 ? .primary : .secondary)
            }
            Text("One act reaches the Mac at a time, and it holds the lane "
                 + "until the Mac confirms it or it times out. A gesture "
                 + "that waited is not a slow Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if timeline.records.isEmpty {
                Text("No acts yet this session.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(timeline.records.reversed().prefix(8).enumerated()),
                        id: \.offset) { _, clocks in
                    Divider()
                    actRow(clocks)
                }
            }
        }
    }

    private func actRow(_ clocks: MirrorActClocks) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(clocks.label.isEmpty ? clocks.operationID : clocks.label)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(clocks.outcome.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(clocks.narrative)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// **What one look at the Mac costs.** Kept apart from acts because
    /// an act confirms from a later scene: this period is charged to
    /// every gesture on the machine, and shortening it is a different
    /// repair from anything in the act path.
    private var cyclesCard: some View {
        card {
            Text("Scene cycles").font(.headline)
            Text("Structure alone and a full walk are different amounts of "
                 + "work on the Mac. They are listed separately because an "
                 + "average of the two describes no machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let walks = ["structure", "structure+semantics",
                         "structure+interaction", "full"]
            let latest = walks.compactMap { cycles.latest(walk: $0) }
            if latest.isEmpty {
                Text("No scene has arrived yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(latest.enumerated()), id: \.offset) { _, cycle in
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(cycle.walk).font(.callout)
                            Spacer()
                            Text(cycle.outcome).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(cycle.baselineLine)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var lifecycleCard: some View {
        card {
            Text("NOW Extension").font(.headline)
            if let facts = model.wireFacts {
                LabeledContent("Lifecycle") {
                    Text(lifecycleLabel(facts.resident.lifecycle))
                }
                LabeledContent("Resident") {
                    if let major = facts.resident.residentMajor {
                        Text("\(major).\(facts.resident.residentMinor ?? 0)")
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Plane bits") {
                    Text("cap \(facts.resident.capabilities ?? 0), "
                         + "requested \(facts.resident.requested ?? 0), "
                         + "active \(facts.resident.active ?? 0)")
                }
                if let build = facts.resident.buildFingerprint {
                    LabeledContent("Build") {
                        Text(build).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let reason = facts.resident.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = model.lifecycleError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Refresh to read the resident lifecycle from this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var planesCard: some View {
        card {
            Text("Planes").font(.headline)
            Text("Structure is required while the Mirror is open. The other "
                 + "planes are independent host policy switches; turning one "
                 + "off cannot change another owner's claim.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.planeFacts) { plane in
                Divider()
                planeRow(plane)
            }
        }
    }

    private func planeRow(_ plane: MirrorWirePlane) -> some View {
        let state = model.presentation(for: plane)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if plane.id == .structure {
                    Toggle(isOn: .constant(true)) {
                        Text("Structure (required)")
                    }
                    .disabled(true)
                } else {
                    Toggle(isOn: Binding(
                        get: { model.policyEnabled(plane.id) },
                        set: { model.setPolicy($0, for: plane.id) })) {
                        Text(plane.id.title)
                    }
                    .disabled(!model.canToggle(plane))
                }
                Spacer()
                Text(state.label).font(.callout.weight(.medium))
            }
            Text(plane.purpose + " · format \(plane.format) · generation "
                 + "\(plane.generation)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let explanation = state.explanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lifecycleLabel(_ lifecycle: MirrorExtensionLifecycle) -> String {
        switch lifecycle {
        case .absent: return "Absent"
        case .needsRestart: return "Installed — restart required"
        case .wrongVersion: return "Wrong version"
        case .active: return "Active"
        case .degraded: return "Degraded"
        }
    }

    private func card<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
