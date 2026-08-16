import SwiftUI

private enum ContinuityHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "The Continuity module needs the app-level pointer controller."
    }
}

/// Screen-edge Continuity as its own module. The controller stays
/// app-owned — arming, the UDP lane, and keyboard forwarding all outlive
/// any page — so this runtime is deliberately thin: it names the
/// controller for the page and ends edge mode when the module shuts down,
/// and nothing else. The Mirror module keeps borrowing the same
/// controller as an in-picture input driver; the two consumers are made
/// exclusive inside the controller itself, not here.
@MainActor
final class ContinuityHostModuleRuntime: HostModuleRuntime {
    let controller: MirrorContinuityController
    let connectedMachineName: () -> String
    /// Page-scoped, unlike the controller: the stills are worth exactly as
    /// long as somebody is looking at the arrangement.
    let previews: ContinuityDisplayPreviewStore

    init(context: HostModuleContext) throws {
        guard let controller = context.continuity else {
            throw ContinuityHostModuleError.missingServices
        }
        self.controller = controller
        self.connectedMachineName = context.connectedMachineName
        self.previews = ContinuityDisplayPreviewStore(
            guestSource: ContinuityGuestListenerCapture(
                listener: context.listener))
    }

    func shutDown() {
        controller.endEdgeMode(reason: "the app is shutting down")
    }
}

@MainActor
enum ContinuityHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "continuity",
            title: "Continuity",
            symbol: "cursorarrow.motionlines",
            summary: "Place \(MachineNaming.simpleReference) beside this "
                + "Mac and pass the pointer and keyboard across their "
                + "shared edge",
            tier: .experimental),
        makeRuntime: { try ContinuityHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? ContinuityHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Continuity runtime has the wrong type."))
            }
            return AnyView(ContinuityModuleView(
                controller: runtime.controller,
                previews: runtime.previews,
                connectedMachineName: runtime.connectedMachineName))
        })
}

/// The page: the display arrangement on top because it is the mental
/// model of the whole feature, the controls beside it. Everything here
/// observes the one app-owned controller; enabling the feature is the
/// controller's `beginEdgeMode`, so quitting the page or the app tears
/// down through one funnel.
struct ContinuityModuleView: View {
    @ObservedObject var controller: MirrorContinuityController
    @ObservedObject var previews: ContinuityDisplayPreviewStore
    let connectedMachineName: () -> String

    private var connected: Bool {
        controller.hasConnectedTarget
    }

    var body: some View {
        HStack(spacing: 0) {
            ContinuityDisplayLayoutView(
                layout: controller.layout,
                edge: controller.edge,
                previews: previews,
                guestName: connectedMachineName(),
                continuityRunning: controller.edgeModeActive,
                guestConnected: connected,
                hasRememberedGuest: controller.hasRememberedGuest)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
            Divider()
            controls
                .frame(width: 280)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pointer").font(.headline)
                Spacer()
                Toggle("Continuity", isOn: Binding(
                    get: { controller.edgeModeActive },
                    set: { wanted in
                        if wanted {
                            controller.beginEdgeMode()
                        } else {
                            controller.endEdgeMode(
                                reason: "Continuity turned off")
                        }
                    }))
                    .toggleStyle(.switch)
                    .disabled(!connected)
                    .help("Pass the pointer to "
                          + "\(connectedMachineName()) when it crosses "
                          + "the shared edge in the arrangement.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            MirrorScrollBox {
                VStack(alignment: .leading, spacing: 14) {
                    ContinuityPointerCard(controller: controller,
                                          edge: controller.edge,
                                          connected: connected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }
}

/// The relocated pointer card: update rate, reconnection, keyboard,
/// the return chord, and the product-tier option catalog. It was a card
/// inside the Mirror inspector while Continuity was a Mirror mode;
/// the wording no longer needs to explain which mode it applies to.
private struct ContinuityPointerCard: View {
    @ObservedObject var controller: MirrorContinuityController
    /// Observed separately from the controller: the failure reason that
    /// decides whether the Accessibility row appears lives on the edge
    /// controller, and a `@Published` change there does not republish
    /// through `controller`.
    @ObservedObject var edge: ContinuityEdgeController
    var connected: Bool

    var body: some View {
        GroupBox("Pointer") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The guest pointer is acquired only after the host "
                     + "pointer crosses the shared edge in the display "
                     + "layout. Guest mouse input returns control here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update rate")
                    Picker("Update rate", selection: $controller.requestedHz) {
                        Text("15 Hz").tag(15)
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!controller.edgeModeActive)
                }
                Toggle("Reconnect after interruption",
                       isOn: $controller.autoReconnect)
                    .disabled(!connected)
                Stepper(value: $controller.reconnectDelay,
                        in: 0.1...5.0, step: 0.1) {
                    Text("Reconnect delay: "
                         + String(format: "%.1fs", controller.reconnectDelay))
                }
                .disabled(!controller.autoReconnect || !connected)
                Stepper(value: Binding(
                    get: { edge.edgeGeometry.entryInsetPixels },
                    set: { controller.setEdgeEntryInset($0) }),
                        in: ContinuityEdgeGeometry.entryInsetRange, step: 2) {
                    Text("Entry inset: "
                         + "\(Int(edge.edgeGeometry.entryInsetPixels)) px")
                }
                .help("How far inside the guest boundary a crossing "
                      + "re-enters — the click-wiggle guard that keeps an "
                      + "ordinary click from tipping straight back across "
                      + "the edge it just crossed.")
                Stepper(value: Binding(
                    get: { edge.edgeGeometry.deadzoneDepth },
                    set: { controller.setEdgeDeadzoneDepth($0) }),
                        in: ContinuityEdgeGeometry.deadzoneDepthRange,
                        step: 8) {
                    Text("File-drag deadzone: "
                         + "\(Int(edge.edgeGeometry.deadzoneDepth)) px")
                }
                .help("How far the file-drag catch surface widens for the "
                      + "length of a guest→host handoff. Zero means the "
                      + "cursor must return to the very physical edge "
                      + "before this Mac tries to take over the drag.")
                Toggle("Send keyboard input to guest",
                       isOn: $controller.keyboardForwardingEnabled)
                    .disabled(!controller.edgeModeActive)
                Picker("Return all controls",
                       selection: $controller.escapeShortcut) {
                    ForEach(ContinuityEscapeShortcut.allCases) { shortcut in
                        Text(shortcut.label).tag(shortcut)
                    }
                }
                .disabled(!controller.edgeModeActive)
                Text("The return shortcut is always handled by this Mac "
                     + "and is never sent to the guest. Keyboard delivery "
                     + "covers Event Manager applications and modifiers; "
                     + "it does not synthesize GetKeys or physical ADB state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ContinuityOptionCatalog.options(in: .product)) {
                    option in
                    Toggle(option.label, isOn: Binding(
                        get: { controller[keyPath: option.keyPath] },
                        set: { controller[keyPath: option.keyPath] = $0 }))
                        .help(option.detail)
                        .disabled(!controller.edgeModeActive)
                }
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if edge.captureFailureReason == .missingPermission {
                    accessibilityRow
                }
                Text("Primary clicks and held motion follow the pointer "
                     + "into the guest. Guest mouse input immediately "
                     + "returns control to that Mac. Diagnostic probes "
                     + "live in Logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown only while the consuming tap is sitting out for want of
    /// Accessibility. A status string is not an affordance: the system
    /// prompt is a one-shot macOS will have already spent on any Mac that
    /// has granted-and-reset this app even once, so the button is the only
    /// half of this that can be relied on to work.
    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Accessibility permission needed",
                  systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
            Text("Turn on \(ProductIdentity.displayName) under Privacy & "
                 + "Security › Accessibility, then come back to this app — "
                 + "capture picks itself up. Without it the pointer still "
                 + "crosses, but host clicks also reach apps on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !edge.runningCopy.isInApplicationsFolder {
                runningCopyNote
            }
            Button("Open Accessibility Settings…") {
                controller.openAccessibilitySettings()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The case where the button above is not merely insufficient but
    /// actively misleading: the person opens the pane, sees this app's
    /// toggle already ON, and concludes the app is broken. Both halves are
    /// telling the truth — macOS grants Accessibility to a COPY, and the
    /// granted copy is not the one running.
    ///
    /// So this names the path we are actually running from and nothing
    /// else. It does not go looking for the other copy, does not detect
    /// App Translocation, and does not claim to know where the grant went;
    /// each of those would be a guess dressed as a diagnosis. The path is
    /// a fact, and it is the fact that ends the confusion.
    private var runningCopyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This copy is running from \(edge.runningCopy.path)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS grants Accessibility to a particular copy of an "
                 + "app, not to the app in general. If the Accessibility "
                 + "list already shows \(ProductIdentity.displayName) "
                 + "switched on, that grant belongs to a different copy. "
                 + "Move this one into your Applications folder and open "
                 + "it from there, then grant it once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
