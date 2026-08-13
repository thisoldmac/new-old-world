import SwiftUI
import MirrorKitUI

/// **The Mirror's chrome: what a person reaches FOR, above the picture.**
///
/// One strip, and the grouping is by how often a control is wanted rather
/// than by "these all belong to the Mirror" — which is the arrangement
/// that made the first embedded version read as a dump. **Start/Stop and
/// Detach are actions**: frequent, one click, always visible. **Zoom is a
/// view setting**: adjusted while looking, so it sits here too but as a
/// picker rather than a button. Everything else lives behind one of the
/// two drawers, both closed by default: the acts under the picture, where
/// a table has the width to be one, and the planes and the resident's
/// lifecycle in the trailing column, where labelled facts belong. A
/// person driving a Macintosh is reading neither.
///
/// **The two drawers are opened differently and that is deliberate.** The
/// inspector has no handle of its own, so it gets the toolbar toggle; the
/// event drawer draws its own header strip whether it is open or shut, so
/// a second control here would be one affordance too many. A drawer with
/// a visible handle does not also need a button somewhere else.
struct MirrorToolbarView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var source: NOWMirrorSource
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
            HStack(spacing: 4) {
                ForEach(MirrorSurfaceMode.allCases) { mode in
                    Button(mode.label) { source.surfaceMode = mode }
                        .buttonStyle(ContinuityChoiceButtonStyle(
                            selected: source.surfaceMode == mode))
                }
            }
            .frame(width: 170)
            .help("Mirror shows and drives the remote screen. Continuity "
                  + "arranges it beside this Mac and passes the pointer "
                  + "through their shared edge.")
            if !presentation.isDetached && source.surfaceMode == .mirror {
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
            .disabled(source.surfaceMode == .continuity)
            .help(presentation.isDetached
                  ? "Bring the Mirror back into this page."
                  : "Put the Mirror in a window of its own. It keeps "
                    + "running either way.")
            Toggle(isOn: $presentation.inspectorShown) {
                Image(systemName: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .help("Show the planes, the resident's lifecycle and what the "
                  + "last scene reported. The acts are the Events drawer "
                  + "under the picture.")
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

/// **The Mirror's inspector: labelled FACTS, beside the picture.**
///
/// Everything here was a card stacked under the Mirror in the first
/// embedded version, which is what made it read as two things piled on
/// each other rather than as one module. None of it is wanted while
/// driving; all of it is wanted when something is wrong. So it is a
/// trailing column behind a toggle, closed by default.
///
/// **The acts left.** They are a time-ordered stream and a stream is a
/// table — glyph, label, duration, outcome — which a 260-point column
/// cannot hold without truncating the label, the one part a person is
/// actually reading. They are the event drawer under the picture now
/// (`MirrorEventStreamView`). What stayed is what this shape fits: named
/// values with their names beside them.
///
/// The cycles stayed even though they are also measurements, and the
/// reason is not sentiment. The drawer lists cycles in TIME order; this
/// card lists **the latest of each walk kind**, which is the only
/// like-for-like comparison the data supports (rule 2 of
/// `docs/mirror-measurement-method.md`). Two different questions about
/// one record.
///
/// **The plane switches stayed too, and that is the deliberate half.** A
/// plane's state is a diagnostic and the host's policy over it is a
/// setting, so they could have been split — a sheet for the switches, a
/// readout here. They are one row instead, because separated they make
/// "on, and the Mac is not sending it" a correlation a person has to
/// perform themselves, which is the same defect as every other one this
/// arc has removed. The guest Workshop reports these same resident facts
/// read-only; it never becomes a second policy authority.
struct MirrorControlView: View {
    @ObservedObject var model: MirrorControlModel
    @ObservedObject var run: MirrorRunControl
    @ObservedObject var presentation: MirrorPresentation
    @ObservedObject var source: NOWMirrorSource
    @ObservedObject var cycles: MirrorCycleTimeline

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MirrorScrollBox {
                VStack(alignment: .leading, spacing: 14) {
                    MirrorLifecycleCard(model: model)
                    ContinuityControlCard(source: source,
                                          mirrorRunning: source.running)
                    MirrorPlanesCard(model: model)
                    hostFinderCard
                    MirrorSceneFactsCard(source: source)
                    assetPackCard
                    MirrorCyclesCard(cycles: cycles)
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
            Button("Rebuild State") { source.rebuildGuestState() }
                .disabled(!source.running)
                .help("Discard cached Finder and application state, then read the guest again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var hostFinderCard: some View {
        GroupBox("Finder") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Emulate Finder Window Interiors (Experimental)",
                       isOn: Binding(
                    get: { source.emulateFinderWindows },
                    set: { source.emulateFinderWindows = $0 }
                ))
                Text("Experimental: the guest owns which Finder windows exist and their chrome; this Mac renders and operates their interiors from semantic file data. Some Finder behaviors remain incomplete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Emulate Desktop", isOn: Binding(
                    get: { source.emulateDesktop },
                    set: { source.emulateDesktop = $0 }
                ))
                Text("Off uses the guest's desktop roster and exact icon positions. On lays out the Desktop Folder and mounted volumes locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle("Sync window opens and closes", isOn: Binding(
                    get: { source.syncEmulatedFinderLifecycle },
                    set: { source.syncEmulatedFinderLifecycle = $0 }
                ))
                .disabled(!source.emulateFinderWindows)
                Toggle("Sync window position and size", isOn: Binding(
                    get: { source.syncEmulatedFinderGeometry },
                    set: { source.syncEmulatedFinderGeometry = $0 }
                ))
                .disabled(!source.emulateFinderWindows)
                Toggle("Sync Finder view type", isOn: Binding(
                    get: { source.syncEmulatedFinderView },
                    set: { source.syncEmulatedFinderView = $0 }
                ))
                .disabled(!source.emulateFinderWindows)
                Text("Development controls. Host actions appear immediately; enabled properties reconcile with later guest observations. View type remains host-only unless its sync is enabled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(source.hostFinderStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Refresh") { source.refreshHostFinder() }
                        .disabled((!source.emulateFinderWindows
                                   && !source.emulateDesktop)
                                  || !model.connection.canCapture)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assetPackCard: some View {
        GroupBox("Asset Packs") {
            VStack(alignment: .leading, spacing: 7) {
                if AssetPack.isEnvironmentManaged {
                    LabeledContent("Selected", value: AssetPack.summaryLine)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Set by \(AssetPack.environmentKey).")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if AssetPack.availablePacks.isEmpty {
                    LabeledContent("Selected",
                                   value: AssetPack.bannerText
                                        ?? AssetPack.summaryLine)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Selected", selection: Binding(
                        get: { AssetPack.selectedPackID ?? "" },
                        set: { AssetPack.selectPack(id: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("Newest valid pack").tag("")
                        ForEach(AssetPack.availablePacks) { pack in
                            Text(pack.id).tag(pack.id)
                        }
                    }
                    Text("A changed pack is loaded on next launch.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContinuityControlCard: View {
    @ObservedObject var source: NOWMirrorSource
    @ObservedObject var controller: MirrorContinuityController
    var mirrorRunning: Bool

    init(source: NOWMirrorSource, mirrorRunning: Bool) {
        self.source = source
        self.controller = source.continuity
        self.mirrorRunning = mirrorRunning
    }

    var body: some View {
        GroupBox(source.surfaceMode == .mirror
                 ? "Mirror Cursor" : "Continuity Pointer") {
            VStack(alignment: .leading, spacing: 8) {
                if source.surfaceMode == .mirror {
                    Toggle("Mirror Cursor",
                           isOn: $source.mirrorCursorEnabled)
                        .disabled(!mirrorRunning)
                    Text("Moves the guest cursor while the pointer is over "
                         + "the rendered Mirror. It is a Mirror feature, "
                         + "not screen-edge Continuity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The guest pointer is acquired only after the host "
                         + "pointer crosses the shared edge in the display "
                         + "layout. Guest mouse input returns control here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update rate")
                    Picker("Update rate", selection: $controller.requestedHz) {
                        Text("15 Hz").tag(15)
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                }
                Toggle("Reconnect after interruption",
                       isOn: $controller.autoReconnect)
                    .disabled(!mirrorRunning)
                if source.surfaceMode == .continuity {
                    Toggle("Send keyboard input to guest",
                           isOn: $controller.keyboardForwardingEnabled)
                        .disabled(!controller.isEnabled || !mirrorRunning)
                    Picker("Return all controls", selection: $controller.escapeShortcut) {
                        ForEach(ContinuityEscapeShortcut.allCases) { shortcut in
                            Text(shortcut.label).tag(shortcut)
                        }
                    }
                    .disabled(!controller.isEnabled || !mirrorRunning)
                    Text("The return shortcut is always handled by this Mac "
                         + "and is never sent to the guest. Keyboard delivery "
                         + "covers Event Manager applications and modifiers; "
                         + "it does not synthesize GetKeys or physical ADB state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Fast Pump (experimental)",
                       isOn: $controller.fastPump)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Toggle("Pin held point (experimental)",
                       isOn: $controller.pinHeldPoint)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Toggle("Virtual GetMouse (experimental)",
                       isOn: $controller.virtualGetMouse)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Toggle("Settle synthetic device (diagnostic)",
                       isOn: $controller.settleSyntheticDevice)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Toggle("Widen double-click window while connected",
                       isOn: $controller.wideDoubleTime)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Toggle("Hide guest cursor during drag (experimental)",
                       isOn: $controller.hideGuestCursorWhileDragging)
                    .disabled(!controller.isEnabled || !mirrorRunning)
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Primary clicks and held motion follow the pointer into "
                     + "the guest. Guest mouse input immediately returns control "
                     + "to that Mac. Fast Pump asks the guest to yield every "
                     + "tick. The held-point experiments test ADB contention "
                     + "without modifying the physical device; cursor hiding "
                     + "isolates the guest sprite during a drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
