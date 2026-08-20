import AppKit
import SwiftUI
import NOWAgentIntegration

/// The selected machine is the page; the roster of machines is a collapsible
/// right sidebar beside it. Selection inspects; the explicit drive control
/// and sidebar guest menu move the host's active request plane. Remembered
/// rows remain inspectable and removable but cannot be driven.
///
/// **The roster is management, not navigation.** Collapsing it hides the
/// machines this host knows about and offers no switching affordance while
/// collapsed, deliberately: switching which machine the host drives belongs
/// to the app-level guest picker, which is reachable from every page. What
/// the roster owns is the machines that are *disconnected* — adding one that
/// has not dialled in yet, forgetting one for good — and that is work a
/// person does occasionally rather than while reading a machine's facts.
///
/// The split itself is `RightSidebarSplitView`, the same AppKit component
/// Files uses for This Mac: one implementation of a collapsible right
/// sidebar in this app, with the hover-peek rail and the native divider,
/// rather than a second one that behaves nearly the same.
struct ConnectionsModuleView: View {
    @ObservedObject var model: ConnectionsModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var listener: GuestListener
    @ObservedObject var onboarding: OnboardingPortal
    @ObservedObject var localNetworkAccess: LocalNetworkAccessController
    var onStart: () -> Void
    var onStop: () -> Void
    @State private var selectedID: String?
    @State private var adding = false
    @State private var connectedBeforeAdding: Set<String> = []
    @State private var pendingRemoval: ConnectionRow?
    @State private var renamingRow: ConnectionRow?
    /// The machine whose settings download is open. Its port, not the
    /// host's default, is what the generated prefs and the page will say.
    @State private var settingUp: ConnectionRow?
    /* Persisted like Files' collapse and NOT like its divider: which of
       the two panes a person wants to see survives a launch, where the
       exact pixel the divider sat at does not. */
    @State private var detailFraction =
        RightSidebarSplitController.defaultLeadingFraction

    /// The roster's one noun, read by its rail, its hover tag and its own
    /// toggle.
    static let rosterTitle = "Machines"

    var body: some View {
        RightSidebarSplitView(
            isTrailingCollapsed: model.rosterCollapsed,
            onTrailingCollapseChanged: { model.rosterCollapsed = $0 },
            leadingFraction: $detailFraction,
            trailingTitle: ConnectionsModuleView.rosterTitle,
            leading: detail,
            trailing: connectionList)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { repairSelection() }
        .onChange(of: model.snapshot) { snapshot in
            if adding,
               let arrived = snapshot.connected.first(where: {
                   !connectedBeforeAdding.contains($0.id)
               }) {
                adding = false
                selectedID = arrived.id
            } else {
                repairSelection()
            }
        }
        .onChange(of: listener.activeKey) { _ in
            guard !adding else { return }
            selectedID = model.snapshot.driving?.id
        }
        .sheet(item: $settingUp) { row in
            OnboardingSheet(portal: onboarding,
                            wirePort: row.listenPort ?? settings.listenPort,
                            machineName: row.displayName)
                .onAppear {
                    onboarding.start(
                        wirePort: row.listenPort ?? settings.listenPort)
                }
        }
        .alert(removalTitle, isPresented: removalIsPresented) {
            Button("Remove", role: .destructive, action: confirmRemoval)
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(removalMessage)
        }
        .sheet(item: $renamingRow) { row in
            DisplayNameEditor(row: row, model: model) {
                renamingRow = nil
            }
        }
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ConnectionsModuleView.rosterTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                /* Mirrors `FilesRightSidebar`'s `titleAccessory`: the
                   trailing pane owns the control that puts it away.
                   `isCollapsed: false` is hardcoded for the same reason —
                   this row only exists while the pane is expanded; the
                   hover rail is the re-expand path. */
                RightSidebarToggle(
                    isCollapsed: false,
                    title: ConnectionsModuleView.rosterTitle) {
                        model.rosterCollapsed.toggle()
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            List(selection: selection) {
                Section("Active") {
                    if model.snapshot.connected.isEmpty {
                        Text("No active connections")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.connected) { row in
                            ConnectionListRow(row: row)
                                .tag(row.id)
                                .contextMenu { connectionMenu(for: row) }
                        }
                    }
                }
                if !model.snapshot.known.isEmpty {
                    Section("Remembered") {
                        ForEach(model.snapshot.known) { row in
                            ConnectionListRow(row: row)
                                .foregroundStyle(.secondary)
                                .tag(row.id)
                                .contextMenu { connectionMenu(for: row) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 4) {
                Button(action: beginAdding) {
                    Image(systemName: "plus")
                }
                .help("Add a guest")
                Button { requestRemoval() } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedRow == nil)
                .help("Remove the selected guest")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
        /* The same `.sidebar` material the collapsed rail is made of, so
           collapsing the roster changes its width rather than its
           substance. */
        .background(SidebarVibrancyBackground())
    }

    /// One machine, top to bottom: what it is, what it can be given, the
    /// link it arrived over, this Mac's permission to reach it, and last
    /// the record of what the listener did.
    ///
    /// The machine leads because the roster now sits beside this pane
    /// rather than above it — a person clicks a row and looks here. The
    /// link card follows rather than opens, and the listener log has one
    /// call site: it was written twice, filtered and unfiltered, and the
    /// two copies were one edit apart from drifting.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let row = selectedRow {
                        ConnectionCard(row: row, model: model) {
                            beginRenaming(row)
                        }
                        .contextMenu { connectionMenu(for: row) }
                        GuestUpdateSection(row: row, model: model)
                    } else {
                        addInstructions
                    }
                    ConnectionLinkSection(
                        settings: settings, listener: listener,
                        onboarding: onboarding,
                        onStart: onStart, onStop: onStop,
                        focusPort: adding,
                        selectedGuest: selectedRow?.key)
                    LocalNetworkAccessSection(
                        controller: localNetworkAccess,
                        targetHost: listener.activeContinuityTarget?.host)
                    ConnectionListenerLog(listener: listener,
                                          sessionIDs: selectedSessionIDs)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Nil is "every session", which is what the page shows when no machine
    /// is selected — the distinction the log's own filter is built on.
    private var selectedSessionIDs: Set<String>? {
        guard let row = selectedRow else { return nil }
        return Set([row.liveSessionID, row.lastSessionID].compactMap { $0 })
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connections")
                    .font(.largeTitle.weight(.semibold))
                Label(detailHeadline, systemImage: indicator.symbol)
                    .foregroundStyle(indicator.tint)
                    .font(.callout)
                if let problem = model.renameProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var detailHeadline: String {
        if adding {
            return "Listen for an unattached guest"
        }
        guard let row = selectedRow else { return model.snapshot.headline }
        switch row.presence {
        case .driving:
            return "\(row.displayName) — attached to all modules"
        case .connected: return "\(row.displayName) — connected"
        case .known:
            return "\(row.displayName) — remembered, not connected"
        }
    }

    /// The same dot vocabulary the sidebar footer and the modules use, so
    /// one glance means the same thing wherever it lands.
    private var indicator: (symbol: String, tint: Color) {
        if let row = selectedRow {
            switch row.presence {
            case .driving: return ("circle.fill", .green)
            case .connected: return ("circle.fill", .secondary)
            case .known: return ("circle", .secondary)
            }
        }
        switch model.snapshot.state {
        case .failed: return ("exclamationmark.triangle", .red)
        case .idle: return ("circle", .secondary)
        case .listening:
            return model.snapshot.isIdle
                ? ("circle.dotted", .orange) : ("circle.fill", .green)
        case .connected:
            return model.snapshot.isIdle
                ? ("circle.dotted", .orange) : ("circle.fill", .green)
        }
    }

    private var addInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a Guest")
                .font(.title3.weight(.semibold))
            Text("Set a port and start listening, then point NOW on the "
                 + "old machine at \(MachineNaming.thisMac). Appears under "
                 + "Active after the handshake.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var selection: Binding<String?> {
        Binding {
            selectedID
        } set: { id in
            adding = false
            selectedID = id
        }
    }

    private var selectedRow: ConnectionRow? {
        guard let selectedID else { return nil }
        return model.snapshot.rows.first { $0.id == selectedID }
    }

    private func repairSelection() {
        guard !adding else { return }
        if selectedRow != nil { return }
        selectedID = model.snapshot.driving?.id ?? model.snapshot.rows.first?.id
    }

    private func beginAdding() {
        connectedBeforeAdding = Set(model.snapshot.connected.map(\.id))
        selectedID = nil
        adding = true
    }

    private func requestRemoval(_ row: ConnectionRow? = nil) {
        pendingRemoval = row ?? selectedRow
    }

    private func beginRenaming(_ row: ConnectionRow) {
        selectedID = row.id
        adding = false
        model.clearRenameProblem()
        renamingRow = row
    }

    @ViewBuilder
    private func connectionMenu(for row: ConnectionRow) -> some View {
        Button("Rename…") { beginRenaming(row) }
        /* Settings for THIS machine, on the port THIS machine dials — the
           download is the only thing that can actually move a guest onto a
           new port, so it has to be reachable per machine rather than only
           from the page's one "add a machine" button. */
        Button("Download Settings for \(row.displayName)…") {
            settingUp = row
        }
        Button("Delete", role: .destructive) { requestRemoval(row) }
        Divider()
        switch listener.state {
        case .idle, .failed:
            Button("Start Listening", action: onStart)
        case .listening, .connected:
            Button("Stop Listening", action: onStop)
        }
    }

    private func confirmRemoval() {
        guard let row = pendingRemoval else { return }
        pendingRemoval = nil
        guard model.remove(row) else { return }
        if row.presence == .known {
            selectedID = nil
            repairSelection()
        }
    }

    private var removalIsPresented: Binding<Bool> {
        Binding {
            pendingRemoval != nil
        } set: { shown in
            if !shown { pendingRemoval = nil }
        }
    }

    private var removalTitle: String {
        guard let row = pendingRemoval else { return "Remove Guest?" }
        return "Remove \(row.displayName)?"
    }

    private var removalMessage: String {
        guard let row = pendingRemoval else { return "" }
        if row.isConnected {
            return "Disconnects \(row.name) and discards its machine ID. "
                + "Reconnecting issues a new temporary ID. "
                + "Cannot be undone."
        }
        return "Discards \(row.name) and its machine ID. "
            + "Cannot be undone."
    }
}

private struct GuestUpdateSection: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel
    @State private var confirmation: UpdateProvider.Component?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Updates")
                .font(.title3.weight(.semibold))
            Text("Replaces only validated artifacts from the update "
                 + "catalog.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GuestUpdateRow(row: row, component: .application,
                           model: model, onInstall: confirm)
            Divider()
            GuestUpdateRow(row: row, component: .extensionComponent,
                           model: model, onInstall: confirm)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .alert(confirmationTitle, isPresented: confirmationPresented) {
            Button("Replace", role: .destructive, action: installConfirmed)
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func confirm(_ component: UpdateProvider.Component) {
        confirmation = component
    }

    private var confirmationPresented: Binding<Bool> {
        Binding {
            confirmation != nil
        } set: { shown in
            if !shown { confirmation = nil }
        }
    }

    private var confirmationTitle: String {
        confirmation == .extensionComponent
            ? "Replace NOW Extension?" : "Replace the Guest App?"
    }

    private var confirmationMessage: String {
        if confirmation == .extensionComponent {
            return "The current Extension moves to the Trash. The new one "
                + "takes effect after the guest Mac restarts."
        }
        return "The running guest app moves to the Trash and the new copy "
            + "takes its place. Quit and relaunch it after installation "
            + "finishes."
    }

    private func installConfirmed() {
        guard let component = confirmation else { return }
        confirmation = nil
        model.installUpdate(for: row, component: component)
    }
}

private struct GuestUpdateRow: View {
    let row: ConnectionRow
    let component: UpdateProvider.Component
    @ObservedObject var model: ConnectionsModel
    let onInstall: (UpdateProvider.Component) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isPending {
                    Button("Cancel") {
                        model.cancelUpdate(for: row, component: component)
                    }
                } else if case .replacement = availability {
                    Button(buttonTitle) { onInstall(component) }
                        .disabled(row.presence != .driving)
                }
            }
            if isPending {
                transferProgress
            }
            if let notice = model.updateNotice(for: row,
                                               component: component) {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if row.presence == .connected,
                      case .replacement = availability {
                Text("Drive this Mac before installing its update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Determinate once bytes have moved on the wire (the same
    /// `captureProgress` bus Screenshots reads); indeterminate before that
    /// and during the guest's own install step, which has no wire signal
    /// — the same "writing" phase H3's ROM dump progress bar also has no
    /// signal for.
    @ViewBuilder
    private var transferProgress: some View {
        if let progress = model.updateProgress, progress.expected > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                Text("\(progress.received / 1024) KB of "
                     + "\(progress.expected / 1024) KB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }

    private var availability: UpdateProvider.Availability {
        model.updateAvailability(for: row, component: component)
    }

    private var isPending: Bool {
        model.updateIsPending(for: row, component: component)
    }

    private var title: String {
        component == .application ? "Guest application" : "NOW Extension"
    }

    private var buttonTitle: String {
        component == .application ? "Replace Guest App…"
                                  : "Replace NOW Extension…"
    }

    private var status: String {
        switch availability {
        case .unavailable:
            return "No validated artifact is installed on this host."
        case .unknown(let offer):
            return "Host has \(offer.version) build "
                + "\(offer.build.prefix(12)); the guest reported no "
                + "comparable identity."
        case .current(let offer):
            return "Matches host \(offer.version) build "
                + String(offer.build.prefix(12)) + "."
        case .hostOlder(let offer):
            return "Guest is newer than host artifact \(offer.version); "
                + "downgrade is not offered."
        case .replacement(let offer):
            return "Different build available: \(offer.version) build "
                + String(offer.build.prefix(12)) + "."
        }
    }

    private var statusColor: Color {
        if case .replacement = availability { return .orange }
        return .secondary
    }
}

private struct LocalNetworkAccessSection: View {
    @ObservedObject var controller: LocalNetworkAccessController
    let targetHost: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Network Access")
                .font(.title3.weight(.semibold))
            Text(controller.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Request Access") {
                    controller.request()
                    guard let targetHost else { return }
                    controller.verifyDirectAccess(to: targetHost)
                }
                Button("Open Settings…", action: openSettings)
            }
            Text("Request Access repeats the macOS prompt and checks the "
                 + "connected Mac when available. If access was denied "
                 + "earlier, enable NOW Continuity in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ConnectionListRow: View {
    let row: ConnectionRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.presence == .known
                  ? "desktopcomputer" : "desktopcomputer.and.macbook")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                Text(row.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if row.presence == .driving {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .help("Attached to the host modules")
            }
        }
    }
}

/// One connected machine: its three identities, what it is, and the two
/// things a person can do to it.
private struct ConnectionCard: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel
    let onRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.displayName)
                    .font(.title3.weight(.semibold))
                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this machine")
                if row.presence == .driving {
                    Badge(text: "Driving", tint: .accentColor)
                }
                if row.idIsAutoAssigned {
                    Badge(text: "Automatic ID", tint: .secondary,
                          help: "Machine id assigned by the host. "
                              + "Independent of the display name.")
                }
                if !row.idIsAnchored {
                    Badge(text: "Id is a guess", tint: .orange,
                          help: "Connected from a shared address "
                              + "(loopback). Machine id is not reliable "
                              + "across reconnections; use the session id "
                              + "for exact addressing.")
                }
                if model.isAwaitingRelaunch(for: row, component: .application)
                    || model.isAwaitingRelaunch(for: row,
                                                component: .extensionComponent) {
                    Badge(text: "Needs relaunch", tint: .orange,
                          help: "Update installed; this session still "
                              + "reports the old build. Requires a relaunch "
                              + "of the guest app, or a restart of the "
                              + "guest Mac for an extension update.")
                }
                Spacer(minLength: 8)
                controls
            }

            Text(row.address)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if row.name != row.displayName {
                Text("Reported as \(row.name)")
                    .foregroundStyle(.secondary)
            }

            identities

            facts

            addressing
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(row.presence == .driving
                          ? Color.accentColor.opacity(0.5) : .clear))
    }

    @ViewBuilder
    private var controls: some View {
        if row.presence != .known {
            HStack(spacing: 8) {
                if row.presence == .connected {
                    Button("Drive This One") { model.drive(row) }
                        .help("Routes all commands, modules and captures "
                              + "to this machine. Others stay connected.")
                }
            }
        }
    }

    /// The three identities, side by side and labelled, because the whole
    /// point is that they are not interchangeable.
    private var identities: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14,
             verticalSpacing: 4) {
            GridRow {
                /* Not "this Mac": on the one page that lists several
                   machines, that phrase means the Mac the app is running
                   on, which is the one machine this label cannot mean. */
                FieldLabel("Machine id", help:
                    "Persistent identifier. Stable across reconnections.")
                Copyable(row.machineID)
            }
            if let session = row.liveSessionID {
                GridRow {
                    FieldLabel("Session id", help:
                        "Scoped to this connection. Invalidated on "
                        + "reconnect.")
                    Copyable(session)
                }
            }
            GridRow {
                FieldLabel("Address", help:
                    "Source address of this connection. Identifies the "
                    + "socket, not the machine.")
                Text(row.address).font(.callout.monospaced())
            }
            GridRow {
                FieldLabel("Port", help:
                    "Inbound port for this machine. Assign a unique port "
                    + "when emulated \(MachineNaming.commonNoun)s share one "
                    + "address. Changes open the socket immediately; the "
                    + "machine must be repointed to match.")
                VStack(alignment: .leading, spacing: 3) {
                    PortField(row: row, model: model)
                    /* A port something else is holding and a Mac that is
                       switched off produce the same empty row, and only one
                       of them is the person's to fix. The listener keeps the
                       reason; saying it here is the difference between an
                       hour of looking at the wrong machine and a sentence. */
                    if let why = model.portIsNotOpen(row) {
                        Label("This port is not open: \(why)",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var facts: some View {
        HStack(spacing: 14) {
            Fact(row.presence == .known ? "Last seen" : "Connected",
                 value: row.since
                .formatted(date: .omitted, time: .standard))
            if let version = row.version {
                Fact("Version", value: version)
            }
            if let build = row.build {
                Fact("Build", value: build)
            }
            if let os = row.operatingSystem {
                Fact("OS", value: os)
            }
            if row.name != row.displayName {
                Fact("Reported name", value: row.name)
            }
            Fact("Agent access", value: Self.access(row.agentAccess))
        }
        .font(.callout)
    }

    /// Nil is "this build never said", which is not consent and is not a
    /// refusal — the wire keeps silence and "no" apart on purpose, so the
    /// page does too.
    private static func access(_ access: AgentIntegrationGuestAccess?)
        -> String {
        switch access {
        case .none: return "not stated"
        case .disabled: return "refused"
        case .readOnly: return "read-only"
        case .fullAccess: return "full"
        case .unrecognized(let raw): return "unrecognised (\(raw))"
        }
    }

    /// What an agent is told when it names this machine — the host's own
    /// answer, read back to the person whose Mac it is.
    private var addressing: some View {
        VStack(alignment: .leading, spacing: 4) {
            AddressingLine(prefix: "By machine id",
                           addressing: row.byMachineID)
            if let session = row.bySessionID {
                AddressingLine(prefix: "By session id", addressing: session)
            }
        }
        .padding(.top, 2)
    }
}

/// **One machine's port**, editable in place.
///
/// In the identity grid rather than behind a sheet because it belongs to
/// the same set of facts as the address it sits under, and because the
/// question it answers — "which socket is this Mac's" — is one a person
/// asks while looking at two rows side by side.
///
/// Empty means the host's default port, and the placeholder says which
/// number that is. That is the state every existing desk is in, so it has
/// to read as a normal answer rather than as something missing.
private struct PortField: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel
    @State private var text: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(model.defaultPortText, text: $text)
                .font(.callout.monospaced())
                .frame(width: 90)
                .focused($editing)
                .onSubmit(commit)
            if editing || text != Self.text(row) {
                Button("Set", action: commit)
                    .font(.callout)
            }
        }
        .onAppear { text = Self.text(row) }
        /* The row is a value and is rebuilt on every refresh, so a change
           made elsewhere — another machine taking this port, a reconnection
           — has to reach the field. Not while it is focused: overwriting
           what somebody is halfway through typing is worse than being one
           refresh stale. */
        .onChange(of: row.listenPort) { _ in
            if !editing { text = Self.text(row) }
        }
    }

    private static func text(_ row: ConnectionRow) -> String {
        row.listenPort.map(String.init) ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setListenPort(row, to: nil)
        } else if let port = UInt16(trimmed), port > 0 {
            model.setListenPort(row, to: port)
        } else {
            model.reportPortProblem("Enter a port between 1 and 65535.")
            return
        }
        editing = false
    }
}

private struct DisplayNameEditor: View {
    let row: ConnectionRow
    @ObservedObject var model: ConnectionsModel
    let dismiss: () -> Void
    @State private var proposed: String

    init(row: ConnectionRow, model: ConnectionsModel,
         dismiss: @escaping () -> Void) {
        self.row = row
        self.model = model
        self.dismiss = dismiss
        _proposed = State(initialValue: row.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Machine")
                .font(.headline)
            TextField("Machine name", text: $proposed)
                .frame(width: 320)
                .onSubmit(commit)
            if let problem = model.renameProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Rename", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(proposed.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func commit() {
        if model.renameDisplayName(row, to: proposed) { dismiss() }
    }
}

/// One addressing outcome, in the host's own words.
///
/// The sentence is quoted rather than paraphrased: it is exactly what the
/// agent on the other side was handed, and a person comparing the two must
/// not have to translate.
private struct AddressingLine: View {
    let prefix: String
    let addressing: ConnectionAddressing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text("\(prefix): \(summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(addressing.message ?? "Answered by this host.")
    }

    private var summary: String {
        switch addressing.outcome {
        case .answered: return "answered"
        case .notAddressed:
            return "refused — \(MachineNaming.thisMac) is driving another "
                + MachineNaming.commonNoun
        case .notConnected: return "refused — not connected"
        case .sessionEnded: return "refused — that session has ended"
        case .noGuestConnected:
            return "refused — no \(MachineNaming.commonNoun) is connected"
        case .unrecognised(let code): return "refused — \(code)"
        }
    }

    private var symbol: String {
        addressing.outcome == .answered
            ? "checkmark.circle" : "minus.circle"
    }

    private var tint: Color {
        addressing.outcome == .answered ? .green : .secondary
    }
}

private struct Badge: View {
    let text: String
    let tint: Color
    var help: String? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(help ?? text)
    }
}

private struct FieldLabel: View {
    let text: String
    let help: String

    init(_ text: String, help: String) {
        self.text = text
        self.help = help
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

/// A handle a person will have to type somewhere else, so it can be taken
/// rather than transcribed.
private struct Copyable: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
