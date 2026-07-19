import SwiftUI

struct SettingsModuleView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    var onStart: () -> Void
    var onStop: () -> Void

    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connection")
                    .font(.largeTitle.weight(.semibold))
                Text("The classic Mac dials in; this side only listens.")
                    .foregroundStyle(.secondary)
            }
            Divider()

            Form {
                HStack(spacing: 12) {
                    TextField("Port", text: $portText)
                        .frame(width: 90)
                        .disabled(isListening)
                        .onSubmit(applyPort)
                    if isListening {
                        Button("Stop Listening") { onStop() }
                    } else {
                        Button("Start Listening") {
                            applyPort()
                            onStart()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Toggle("Listen when the app starts",
                       isOn: $settings.listenAtLaunch)
                    .toggleStyle(.checkbox)
            }

            statusLine
            if let last = listener.lastDisconnect {
                Text(last)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { portText = String(settings.listenPort) }
    }

    private var isListening: Bool {
        switch listener.state {
        case .listening, .connected: return true
        case .idle, .failed: return false
        }
    }

    private func applyPort() {
        if let port = UInt16(portText), port > 0 {
            settings.listenPort = port
        } else {
            portText = String(settings.listenPort)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch listener.state {
        case .idle:
            Label("Not listening", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .listening(let port):
            Label("Listening on port \(String(port)) — no Mac connected",
                  systemImage: "circle.dotted")
                .foregroundStyle(.orange)
        case .connected(let name):
            Label("Connected: \(name)", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
