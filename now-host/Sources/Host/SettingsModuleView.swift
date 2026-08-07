import SwiftUI

/// This Mac's side of the link: the port it offers, and the health of the
/// session running over it.
///
/// **A section, not a page.** This used to be the whole "Connection" pane,
/// pinned in the footer beside a separate "Connections" pane that listed the
/// machines on that same link. Two sidebar rows for one subject, and neither
/// stood up alone — the link pane had to say what a connection was for, and
/// the roster pane had to restate the port and the listening state to explain
/// why it was empty. They are one page now (`ConnectionsModuleView`), and
/// this is the half about this side.
///
/// The file keeps its name deliberately: `SessionHealthProjection` declares
/// that the app UI reaches session health through `healthBlock(health)` in
/// `SettingsModuleView.swift`, and `HostFaceParityTests` reads this source to
/// check it. Renaming the file would break that declaration silently in one
/// direction and loudly in the other; the declaration moves when somebody
/// moves it on purpose, in the same commit.
struct ConnectionLinkSection: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    var onStart: () -> Void
    var onStop: () -> Void

    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(
                "The link",
                caption: "\(MachineNaming.startingSentence(MachineNaming.simpleReference)) "
                    + "dials in; \(MachineNaming.thisMac) only listens.")

            /* The port and its switch on one line, not in a Form. A Form
               draws a labelled settings sheet, and this is no longer a
               settings page — it is the first fact on a page whose second
               fact is who dialled into that port. */
            HStack(spacing: 12) {
                Text("Port")
                    .foregroundStyle(.secondary)
                TextField("Port", text: $portText)
                    .labelsHidden()
                    .frame(width: 80)
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
                Toggle("Listen when the app starts",
                       isOn: $settings.listenAtLaunch)
                    .toggleStyle(.checkbox)
                    .padding(.leading, 6)
            }

            /* No status line here. The page's header carries one sentence
               for the state of the link AND how many machines are on it —
               which is the whole reason the two panes folded together. A
               second dot down here would be the same fact drawn twice, and
               the two were already worded differently. */

            if let health = listener.health {
                healthBlock(health)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
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

    /// How the paired session is actually behaving — the one thing on this
    /// page that is about the link rather than about either machine.
    private func healthBlock(_ health: GuestListener.SessionHealth)
        -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Health")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16,
                 verticalSpacing: 3) {
                GridRow {
                    Text("Machine").foregroundStyle(.secondary)
                    Text(guestDescription(health))
                }
                GridRow {
                    Text("Connected").foregroundStyle(.secondary)
                    Text(health.connectedAt,
                         format: .dateTime.hour().minute().second())
                }
                GridRow {
                    Text("Last traffic").foregroundStyle(.secondary)
                    Text(health.lastTraffic, style: .relative)
                        + Text(" ago")
                }
                GridRow {
                    Text("Frames / pings").foregroundStyle(.secondary)
                    Text("\(health.framesReceived) / \(health.pingsAnswered)")
                }
            }
            .font(.callout)
        }
        .padding(.top, 4)
    }

    private func guestDescription(_ health: GuestListener.SessionHealth)
        -> String {
        var text = health.guestName
        if let version = health.guestVersion {
            text += "  ·  v\(version)"
        }
        /* Beside the version, not instead of it: the version says which
           release this claims to be and the build says whether it is the
           one just deployed. Absent when the guest reports none — NOW-68K
           does not — rather than shown empty or backfilled. */
        if let build = health.guestBuild, !build.isEmpty {
            text += "  ·  build \(build)"
        }
        if let os = health.guestOS {
            text += "  ·  OS \(os)"
        }
        return text
    }
}

/// What the listener has been doing, last line first.
///
/// Last on the page because it is the record rather than the state: a person
/// arrives here to see whether the link is up and who is on it, and reaches
/// the log only when one of those answers is surprising.
struct ConnectionListenerLog: View {
    @ObservedObject var listener: GuestListener

    var body: some View {
        if !listener.log.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHead("Log", caption: "What the listener on "
                    + "\(MachineNaming.thisMac) has done, newest first.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(listener.log.reversed()) { entry in
                            Text("\(entry.at, format: .dateTime.hour().minute().second())  \(entry.text)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }
}

/// One heading vocabulary for the whole page, so the two halves that were
/// separate panes do not arrive wearing their old title styles.
struct SectionHead: View {
    let text: String
    let caption: String?

    init(_ text: String, caption: String? = nil) {
        self.text = text
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
