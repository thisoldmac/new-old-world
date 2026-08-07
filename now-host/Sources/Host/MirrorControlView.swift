import SwiftUI

/// **The Mirror's chrome: what a person reaches FOR, above the picture.**
///
/// One strip, and the grouping is by how often a control is wanted rather
/// than by "these all belong to the Mirror" — which is the arrangement
/// that made the first embedded version read as a dump. **Start/Stop and
/// Detach are actions**: frequent, one click, always visible. **Zoom is a
/// view setting**: adjusted while looking, so it sits here too but as a
/// picker rather than a button. Everything else — the planes, the
/// resident's lifecycle, the act and cycle clocks — is diagnostics, and
/// diagnostics go in the inspector behind a toggle, because a person
/// driving a Macintosh is not reading them.
struct MirrorToolbarView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var run: MirrorRunControl
    @ObservedObject var presentation: MirrorPresentation
    /// Detaching is not `presentation.isDetached.toggle()`: the window
    /// owns its own open/closed state and sets the axis itself, so both
    /// directions go through it and there is one path rather than two
    /// that must agree.
    let setDetached: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            identity
            Spacer(minLength: 8)
            if !presentation.isDetached {
                /* A MENU rather than a segmented control. Five stops as
                   segments is 260 points of toolbar for a setting that
                   is changed occasionally — it crowded out the machine's
                   own name at a 620-point pane width, which is the width
                   the detail column actually starts at. */
                Picker("Zoom", selection: $presentation.zoom) {
                    ForEach(MirrorZoom.allCases) { stop in
                        Text(stop.label).tag(stop)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("How much of the classic Mac's screen one point here "
                      + "is worth. Every numbered stop is a power of two, so "
                      + "the pixels stay exact.")
            }
            Button(run.running ? "Stop" : "Start") {
                if run.running { run.stop() } else { run.start() }
            }
            .disabled(!run.running && !model.connection.canCapture)
            .help(run.running
                  ? "Stop asking the classic Mac for its screen. Every "
                    + "Mirror request refuses until it is started again."
                  : "Start asking the classic Mac for its screen.")
            Button(presentation.isDetached ? "Attach" : "Detach") {
                setDetached(!presentation.isDetached)
            }
            .help(presentation.isDetached
                  ? "Bring the Mirror back into this page."
                  : "Put the Mirror in a window of its own. It keeps "
                    + "running either way.")
            Toggle(isOn: $presentation.inspectorShown) {
                Image(systemName: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .help("Show the planes, the resident's lifecycle and the act "
                  + "clocks.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Which Macintosh, and whether anything is being asked of it. Both
    /// belong here rather than in a card: they are the two facts a person
    /// checks before believing anything else on the page.
    private var identity: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(run.running ? Color.green
                      : run.wantsRunning ? Color.orange : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.connection.peerLabel)
                    .font(.headline)
                    .lineLimit(1)
                Text(stateLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateLine: String {
        if run.running {
            return presentation.isDetached
                ? "Running — showing in its own window"
                : "Running"
        }
        if run.wantsRunning { return "Waiting for a Mac to come back" }
        return "Stopped"
    }
}

/// **The Mirror's inspector: what a person looks UP, beside the picture.**
///
/// Everything here was a card stacked under the Mirror in the first
/// embedded version, which is what made it read as two things piled on
/// each other rather than as one module. None of it is wanted while
/// driving; all of it is wanted when something is wrong. So it is a
/// trailing column behind a toggle, closed by default.
///
/// The host's policy over the four named planes lives here too. The guest
/// Workshop reports these same resident facts read-only; it never becomes
/// a second policy authority.
struct MirrorControlView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var run: MirrorRunControl
    @ObservedObject var presentation: MirrorPresentation
    @ObservedObject var timeline: MirrorActTimeline
    @ObservedObject var cycles: MirrorCycleTimeline

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
        HStack(alignment: .firstTextBaseline) {
            /* Deliberately terse. The old header explained what the
               Mirror IS, which was necessary when this page was a button
               that opened a window somewhere else. The page draws the
               machine now, so the explanation is redundant and the space
               is better spent on the machine. */
            Text("Details").font(.headline)
            Spacer()
            if model.isLifecycleChecking {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { model.refreshLifecycle() }
                .disabled(model.isLifecycleChecking
                          || !model.connection.canCapture)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            Text("Structure is required while the Mirror is running. The other "
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
