import SwiftUI

struct WebModuleView: View {
    @ObservedObject var model: WebBridgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                helper
                listener
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
            Text("The host owns TLS, JavaScript and optional layout-model "
                 + "work. The classic Mac receives bounded plain HTTP.")
                .foregroundStyle(.secondary)
        }
    }

    private var helper: some View {
        GroupBox("Web Bridge Helper") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Helper folder", text: $model.helperRoot)
                    .onSubmit { model.helperPathDidChange() }
                Text("The folder must contain nowweb/__main__.py. Chromium "
                     + "and the optional model are never downloaded on a request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var listener: some View {
        GroupBox("Classic Browser Listener") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Bind address", text: $model.bindAddress)
                    Button("Use This Mac's LAN Address") {
                        model.usePrimaryLANAddress()
                    }
                }
                HStack {
                    Text("Port")
                    TextField("Port", value: $model.port, format: .number)
                        .frame(width: 90)
                    Spacer()
                }
                TextField("Allowed classic Mac address (recommended)",
                          text: $model.allowedClient)
                if model.exposesLANWithoutPeerRestriction {
                    Label("This listener will accept every peer on the selected "
                          + "interface. Enter the classic Mac's address to restrict it.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(model.proxyInstruction)
                    .font(.callout)
                    .textSelection(.enabled)
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
                TextField("AI planner executable (optional)",
                          text: $model.aiPlannerExecutable)
                Toggle("Allow private and local web destinations (unsafe)",
                       isOn: $model.allowPrivateDestinations)
                Text("Compatible Page is always the fallback. The AI planner "
                     + "may reorder original blocks, but cannot write links or text.")
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
                    Text(model.startURL)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
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

