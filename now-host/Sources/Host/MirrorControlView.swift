import SwiftUI

/// One product surface: NOW's own data-driven Mirror window, plus the host's
/// policy over the four named planes. The guest Workshop reports these same
/// resident facts read-only; it never becomes a second policy authority.
struct MirrorControlView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var mirrorWindow: NOWMirrorWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    productCard
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
