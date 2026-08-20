import SwiftUI

struct WebModuleView: View {
    @ObservedObject var model: WebBridgeModel
    /// Nil in a preview or a test with no Settings window to open.
    var openSettings: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                relay
                status
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Web")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Modern web pages, translated for a classic browser")
                    .font(.title2.weight(.semibold))
                Text("The browser connects to New Old World on \(MachineNaming.simpleReference). "
                     + "Requests cross the existing NOW connection; TLS, "
                     + "JavaScript, policy and page translation run here.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let openSettings {
                Button("Settings…", action: openSettings)
            }
        }
    }

    private var relay: some View {
        GroupBox("Guest Relay") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Set the classic browser's HTTP proxy to 127.0.0.1:5180.",
                      systemImage: "arrow.left.arrow.right")
                Text("The loopback listener belongs to the guest application. "
                     + "Not exposed to \(MachineNaming.possessive(nil)) LAN; uses "
                     + "the same authenticated-by-presence NOW session as the "
                     + "rest of the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Page compatibility, safety and start-automatically "
                     + "are in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var status: some View {
        GroupBox("Service") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.lifecycle.label, systemImage: statusSymbol)
                    Spacer()
                    Button("Stop") { model.stop() }
                        .disabled(!canStop)
                    Button("Start") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
                switch model.lifecycle {
                case .ready:
                    Text("Renderer ready. A connected guest relay can browse.")
                        .font(.callout)
                case .failed(let reason), .unavailable(let reason):
                    Text(reason).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if !model.recentOutput.isEmpty {
                    Text(model.recentOutput.suffix(6).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var canStop: Bool {
        switch model.lifecycle {
        case .starting, .ready: return true
        default: return false
        }
    }

    private var statusSymbol: String {
        switch model.lifecycle {
        case .ready: return "checkmark.circle.fill"
        case .starting, .stopping: return "clock"
        case .failed: return "xmark.octagon.fill"
        case .unavailable: return "questionmark.circle"
        case .stopped: return "stop.circle"
        }
    }
}
