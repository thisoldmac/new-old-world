import SwiftUI

/// This Mac's side of the link: the port it offers, the boundary that port
/// sits on, and the health of the session running over it.
///
/// **A section, not a page.** This used to be the whole "Connection" pane,
/// pinned in the footer beside a separate "Connections" pane that listed the
/// machines on that same link. Two sidebar rows for one subject, and neither
/// stood up alone — the link pane had to say what a connection was for, and
/// the roster pane had to restate the port and the listening state to explain
/// why it was empty. They are one page now (`ConnectionsModuleView`), and
/// this is the half about this side.
///
/// It lived in `SettingsModuleView.swift` until the page grew its roster
/// sidebar: a file named for a module that no longer exists, holding two
/// views belonging to a module whose own file sat beside it. The name that
/// mattered was not the file's but the declaration's —
/// `SessionHealthProjection` declares that the app UI reaches session health
/// through `healthBlock(health)` in this file and `HostFaceParityTests`
/// reads that source to check it, so the declaration moved in the same
/// commit as the file. If this file is renamed again, that entry and
/// `ConnectionsPaneTests`' source gates move with it or the parity claim
/// silently describes a file nobody has.
struct ConnectionLinkSection: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    @ObservedObject var onboarding: OnboardingPortal
    var onStart: () -> Void
    var onStop: () -> Void
    var focusPort = false
    var selectedGuest: GuestKey?

    @State private var portText: String = ""
    @State private var showingOnboarding = false
    @FocusState private var portIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHead(
                "The link",
                caption: "\(MachineNaming.startingSentence(MachineNaming.simpleReference)) "
                    + "connects in; \(MachineNaming.thisMac) only listens.")

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
                    .focused($portIsFocused)
                    .onSubmit(startListening)
                if isListening {
                    Button("Stop Listening") { onStop() }
                } else {
                    Button("Start Listening", action: startListening)
                    .buttonStyle(.borderedProminent)
                }
                Toggle("Listen when the app starts",
                       isOn: $settings.listenAtLaunch)
                    .toggleStyle(.checkbox)
                    .padding(.leading, 6)
            }

            /* The boundary belongs to the port, not to the page. It floated
               as its own row directly above this card, which read as a
               property of the whole module while it is a property of this
               one control — and put two things about the listener in two
               containers a person had to join up themselves. */
            trustedLANNotice

            HStack(spacing: 10) {
                Button("Set Up a New Mac…", action: openOnboarding)
                if let endpoint = onboarding.endpoint,
                   let url = endpoint.pageURL {
                    Text("Onboarding at \(url.absoluteString)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Stop") { onboarding.stop() }
                        .controlSize(.small)
                } else {
                    Text("Serves the PPC app, settings, extension and "
                         + "local dependencies to an old browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            /* No status line here. The page's header carries one sentence
               for the state of the link AND how many machines are on it —
               which is the whole reason the two panes folded together. A
               second dot down here would be the same fact drawn twice, and
               the two were already worded differently. */

            if let selectedGuest,
               let health = listener.health(for: selectedGuest) {
                healthBlock(health)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .onAppear {
            portText = String(settings.listenPort)
            if focusPort { portIsFocused = true }
        }
        .onChange(of: focusPort) { wanted in
            if wanted && !isListening { portIsFocused = true }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingSheet(portal: onboarding,
                            wirePort: settings.listenPort)
        }
    }

    private var trustedLANNotice: some View {
        Label {
            Text("Trusted LAN only. Connections are plaintext and have no peer authentication; do not expose this port to the internet or an untrusted network.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }

    private var isListening: Bool {
        switch listener.state {
        case .listening, .connected: return true
        case .idle, .failed: return false
        }
    }

    private func startListening() {
        guard settings.submitListenPort(portText, start: onStart) else {
            portText = String(settings.listenPort)
            return
        }
        portText = String(settings.listenPort)
    }

    private func openOnboarding() {
        if !isListening {
            guard settings.submitListenPort(portText, start: onStart) else {
                portText = String(settings.listenPort)
                return
            }
            portText = String(settings.listenPort)
        }
        onboarding.start(wirePort: settings.listenPort)
        showingOnboarding = true
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
    var sessionIDs: Set<String>? = nil

    private var entries: [GuestListener.LogEntry] {
        guard let sessionIDs else { return listener.log }
        return listener.log.filter { entry in
            entry.sessionID.map(sessionIDs.contains) ?? false
        }
    }

    var body: some View {
        let visibleEntries = entries
        if !visibleEntries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHead("Log", caption: "Listener activity on "
                    + "\(MachineNaming.thisMac), newest first.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleEntries.reversed()) { entry in
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
