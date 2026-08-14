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

    init(context: HostModuleContext) throws {
        guard let controller = context.continuity else {
            throw ContinuityHostModuleError.missingServices
        }
        self.controller = controller
        self.connectedMachineName = context.connectedMachineName
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
    let connectedMachineName: () -> String

    private var connected: Bool {
        controller.hasConnectedTarget
    }

    var body: some View {
        HStack(spacing: 0) {
            ContinuityDisplayLayoutView(
                layout: controller.layout,
                edge: controller.edge,
                guestName: connectedMachineName(),
                mirrorRunning: controller.edgeModeActive)
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
}
