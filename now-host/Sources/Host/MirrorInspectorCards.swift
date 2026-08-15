import SwiftUI
import MirrorKit

/// **The Mirror's readouts, one card per subject and each independently
/// placeable.**
///
/// They were four private computed properties of `MirrorControlView`,
/// which meant the only arrangement they could ever have was that one
/// column in that order. That is not a neutral fact about code shape: it
/// is why every layout candidate rendered the same stack, and why the
/// question "should the planes be somewhere else from the clocks" could
/// not be asked without rewriting the view that answers it.
///
/// So each is a view. `MirrorControlView` still composes all four; a
/// candidate that puts the clocks in a drawer and the planes in a sheet
/// composes the same four differently, and the two cannot drift because
/// there is one of each.
///
/// `MirrorCard` is the shared container: the rounded quaternary block the
/// inspector has always drawn, named once.
struct MirrorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

/// How many acts the lane is holding, in a sentence. Pure and shared
/// because the drawer's header and the card's corner say the same thing
/// and a second phrasing is a second place to be wrong.
enum MirrorLaneDepth {
    static func sentence(_ depth: Int) -> String {
        switch depth {
        case 0: return "lane idle"
        case 1: return "1 in flight"
        default: return "1 in flight, \(depth - 1) waiting"
        }
    }
}

/// **What one look at the Mac costs.** Kept apart from acts because
/// an act confirms from a later scene: this period is charged to
/// every gesture on the machine, and shortening it is a different
/// repair from anything in the act path.
struct MirrorCyclesCard: View {
    @ObservedObject var cycles: MirrorCycleTimeline

    var body: some View {
        MirrorCard {
            Text("Scene cycles").font(.headline)
            Text("Structure alone and a full walk are different amounts of "
                 + "work on the Mac. They are listed separately because an "
                 + "average of the two describes no machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let latest = MirrorCycleWalks.all.compactMap { cycles.latest(walk: $0) }
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
}

/// The four walk kinds, in the order a person compares them. Named once
/// rather than spelled inline: they are also the strings
/// `MirrorCycleClocks.walk` produces, and a list that drifts from that
/// silently shows three rows where there are four.
enum MirrorCycleWalks {
    static let all = ["structure", "structure+semantics",
                      "structure+interaction", "full"]
}

/// The resident component's own report about itself.
struct MirrorLifecycleCard: View {
    @ObservedObject var model: MirrorControlModel

    var body: some View {
        MirrorCard {
            Text("NOW Extension").font(.headline)
            if let facts = model.wireFacts {
                LabeledContent("Lifecycle") {
                    Text(Self.lifecycleLabel(facts.resident.lifecycle))
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
                /* Stated as a fact beside the resident's, not left to be
                   inferred from five planes all reading the same refusal.
                   It is the one line on this page that answers "is the
                   problem at the other end", and it costs a row. */
                LabeledContent("Consent") {
                    Text(facts.policy.enabled
                         ? "That Mac allows mirroring"
                         : "That Mac is not allowing mirroring")
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

    static func lifecycleLabel(_ lifecycle: MirrorExtensionLifecycle) -> String {
        switch lifecycle {
        case .absent: return "Absent"
        case .needsRestart: return "Installed — restart required"
        case .wrongVersion: return "Wrong version"
        case .active: return "Active"
        case .degraded: return "Degraded"
        }
    }
}

/// **The planes: a state to read and a switch to set, in ONE row.**
///
/// The two halves could legitimately live apart — a plane's STATE is a
/// diagnostic a person reads while something is wrong, and the host's
/// policy over it is a setting a person changes once per machine — and a
/// draft of this module put the switches in a settings sheet and left the
/// states here. That draft was rejected, and the reason generalises:
/// separated, "on, and the Mac is not sending it" becomes a correlation a
/// person has to perform across two surfaces. Together it is one row that
/// explains itself.
///
/// It is also why this module has **no settings sheet at all**. Plane
/// policy is the only thing in the Mirror that a person sets rather than
/// watches, and it is here.
struct MirrorPlanesCard: View {
    @ObservedObject var model: MirrorControlModel

    var body: some View {
        MirrorCard {
            Text("Planes").font(.headline)
            /* Both keys named in one paragraph, in the order a person
               hits them: the Mac has to allow mirroring at all before any
               switch here means anything. They used to be told apart only
               by a per-row state word, which said WHICH plane was refused
               and never said the Mac had refused all of them. */
            Text("Structure is required while the Mirror is running. The other "
                 + "planes are independent host policy switches; turning one "
                 + "off cannot change another owner's claim. These switches "
                 + "are this Mac's half: the classic Mac decides separately "
                 + "whether it may be mirrored at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.planeFacts.isEmpty {
                Text("No Mac has reported its planes yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !model.guestAllowsMirroring {
                Text("That Mac is not allowing mirroring right now, so "
                     + "nothing below is being captured whatever it says.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
}

/// **What the last scene did and did not report.**
///
/// Restored from the pre-embed Mirror page, where it was a footer under
/// the picture. It went missing in the embed and nothing replaced it,
/// which matters more here than it would in most products: **a sparse
/// scene is normal.** A window drawn as empty chrome is the expected
/// picture when the guest reports no QuickDraw content, and without this
/// line a person has no way to tell that from a rendering failure.
///
/// The counts come with the scene's own coverage claims rather than with
/// a presence flag per shelf — the flags the old footer read (`windowsPresent`
/// and friends) were replaced by `meta.coverage`, which says *who* claimed
/// a scope and *why* it is partial. A count with no claim beside it is the
/// same ambiguity in a newer costume, so both are drawn.
struct MirrorSceneFactsCard: View {
    @ObservedObject var source: NOWMirrorSource

    var body: some View {
        MirrorCard {
            Text("Last scene").font(.headline)
            if let scene = source.scene {
                LabeledContent("Screen") {
                    Text("\(scene.screen.w) × \(scene.screen.h)")
                }
                LabeledContent("Windows") { Text("\(scene.windows.count)") }
                LabeledContent("Programs") { Text("\(scene.apps.count)") }
                LabeledContent("Menu bar") { Text(Self.menubar(scene)) }
                LabeledContent("Scene IR") { Text("v\(scene.version)") }
                LabeledContent("Sequence") { Text("\(scene.seq)") }
                if let claims = scene.meta.coverage, !claims.isEmpty {
                    Divider()
                    Text("Coverage").font(.caption.weight(.medium))
                    ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                        Text(Self.claimLine(claim))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !scene.meta.errors.isEmpty {
                    Divider()
                    Text("\(scene.meta.errors.count) noted by the Mac")
                        .font(.caption.weight(.medium))
                    ForEach(Array(scene.meta.errors.enumerated()),
                            id: \.offset) { _, error in
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("No scene has arrived yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static func claimLine(_ claim: MirrorKit.Scene.CoverageClaim) -> String {
        var line = "\(claim.scope): \(claim.status.rawValue)"
        if let owner = claim.owner { line += " · \(owner)" }
        if let reason = claim.reason { line += " — \(reason)" }
        return line
    }

    static func menubar(_ scene: MirrorKit.Scene) -> String {
        guard let bar = scene.menubar else { return "not reported" }
        return bar.menus.count == 1 ? "1 menu" : "\(bar.menus.count) menus"
    }
}
