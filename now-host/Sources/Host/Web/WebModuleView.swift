import SwiftUI

struct WebModuleView: View {
    @ObservedObject var model: WebBridgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                relay
                rendering
                status
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Web")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modern web pages, translated for a classic browser")
                .font(.title2.weight(.semibold))
            Text("The browser connects to New Old World on \(MachineNaming.simpleReference). "
                 + "Requests cross the existing NOW connection; this Mac "
                 + "owns TLS, JavaScript, policy, and page translation.")
                .foregroundStyle(.secondary)
        }
    }

    private var relay: some View {
        GroupBox("Guest Relay") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Set the classic browser's HTTP proxy to 127.0.0.1:5180.",
                      systemImage: "arrow.left.arrow.right")
                Text("The loopback listener belongs to the guest application. "
                     + "It is not exposed to \(MachineNaming.possessive(nil)) LAN, and it uses "
                     + "the same authenticated-by-presence NOW session as the "
                     + "rest of the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var rendering: some View {
        GroupBox("Page Compatibility") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Browser", selection: $model.profile) {
                    ForEach(WebBrowserProfile.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Default view", selection: $model.lens) {
                    ForEach(WebRenderingLens.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Fetch engine", selection: $model.engine) {
                    ForEach(WebFetchEngine.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Toggle("Use known-site handlers", isOn: $model.handlersEnabled)
                TextField("AI model folder or planner executable (optional)",
                          text: $model.aiPlannerExecutable)
                Toggle("Allow private and local web destinations (unsafe)",
                       isOn: $model.allowPrivateDestinations)
                Text("A model folder uses the optional MLX adapter. Compatible "
                     + "Page is always the fallback; AI may reorder original "
                     + "blocks, but cannot write links or text.")
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
                Toggle("Start automatically", isOn: $model.startsAutomatically)
                switch model.lifecycle {
                case .ready:
                    Text("Renderer ready. A connected guest relay can browse now.")
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
