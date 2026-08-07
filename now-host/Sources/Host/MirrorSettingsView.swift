import SwiftUI

/// **The things a person SETS about the Mirror, as opposed to watches.**
///
/// The whole module holds exactly one such group today — which plane this
/// host asks a given Macintosh for — and one is enough to be worth
/// separating, because a switch that changes what the other machine is
/// asked to do does not belong in the same column as a clock.
///
/// It is per-machine and says so. `MirrorPlanePolicyStore` keys on the
/// guest's slug, so the answer given for a PowerBook is not the answer
/// given for an emulator, and a sheet that did not name the machine would
/// be inviting somebody to change the wrong one's policy.
///
/// **Not here, deliberately:** zoom (a view control, adjusted while
/// looking, so it stays in the toolbar), attach/detach and start/stop
/// (actions), and the agent port / QMP socket / build-from-source fields
/// the legacy launcher carried — those are retired and gated against
/// return by `tools/mirror-gate-tests/test_legacy_mirror_retirement.py`.
struct MirrorSettingsView: View {
    @ObservedObject var model: MirrorControlModel
    /// Nil when this is rendered as a page rather than a sheet. A sheet
    /// owes a way out; a segment must not draw one.
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dismiss != nil {
                header
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    machine
                    planes
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            if let dismiss {
                Divider()
                HStack {
                    Spacer()
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        HStack {
            Text("Mirror Settings").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Which Macintosh these answers are about. First, and not decoration:
    /// every switch below is remembered against this machine's identity.
    private var machine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.connection.peerLabel)
                .font(.headline)
            Text("These answers are remembered for this Macintosh alone. "
                 + "Another Mac keeps its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to ask this Mac for")
                .font(.headline)
            Text("Structure is required while the Mirror is running. The "
                 + "others are independent; turning one off cannot change "
                 + "another owner's claim on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.planeFacts.isEmpty {
                Text("No Mac has reported its planes yet. Connect one, or "
                     + "refresh the Mirror's details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.planeFacts) { plane in
                Divider()
                row(plane)
            }
        }
    }

    private func row(_ plane: MirrorWirePlane) -> some View {
        let state = model.presentation(for: plane)
        return VStack(alignment: .leading, spacing: 3) {
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
                /* The plane's actual state beside its switch, and this is
                   the argument against putting the switches in a sheet and
                   the states in a drawer: "on, and the Mac is not sending
                   it" is one row here and a correlation a person has to
                   make themselves if the two are separated. */
                Text(state.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(plane.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = state.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
