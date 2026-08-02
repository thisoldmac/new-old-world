import Foundation
import Combine

@MainActor
final class HostAppState: ObservableObject {
    @Published var selectedModuleID: String {
        didSet { defaults.set(selectedModuleID, forKey: Self.selectionKey) }
    }
    private(set) lazy var screenshots: ScreenshotModuleModel = {
        let model = ScreenshotModuleModel(listener: listener)
        model.announce = { [notifier] guest, format, fileURL in
            notifier.announce(guest: guest, format: format, fileURL: fileURL)
        }
        return model
    }()
    private let notifier = CaptureNotifier()
    private(set) lazy var files: FilesModuleModel = {
        listener.announceReceivedFile = { [notifier] guest, url, bytes in
            notifier.announce(fileFrom: guest, url: url, bytes: bytes)
        }
        return FilesModuleModel(
            listener: listener,
            defaults: defaults,
            artifactApprover: agentIntegration)
    }()

    /// The menu-bar "Screenshot Guest" command. Reports through the system
    /// notifier and, because that path is silent under an ad-hoc signature,
    /// also through whatever visible fallback the app installs below.
    private(set) lazy var quickCapture: QuickCaptureCommand = {
        let command = QuickCaptureCommand(screenshots: screenshots,
                                          files: files)
        command.report = { [weak self] outcome in
            guard let self else { return }
            self.notifier.announce(outcome: outcome)
            self.quickCaptureFeedback?(outcome)
        }
        return command
    }()

    /// Set by the app delegate to flash the status item. Kept as a hook so
    /// HostAppState stays free of AppKit chrome and tests stay silent.
    var quickCaptureFeedback: ((QuickCaptureOutcome) -> Void)?

    /// Starting and stopping the MCP server, set by the app delegate.
    ///
    /// Hooks rather than methods for the same reason as the flash above: the
    /// server object belongs to the delegate, which is the only thing whose
    /// lifetime matches a listening socket's, and a test or a preview that
    /// leaves these nil gets a pane with buttons that do nothing to any real
    /// socket instead of a host process with an endpoint it never wanted.
    var startMCPServer: (() -> Void)?
    var stopMCPServer: (() -> Void)?

    /// Drives the menu bar's connection glyph and status line.
    private(set) lazy var guestStatus = GuestStatusMonitor(listener: listener)
    let settings: SettingsModel
    /// Not lazy: constructing it applies the saved disk-persistence switch
    /// to HostLog before the first wire event has a line to write.
    let logs: LogsModel
    let listener: GuestListener
    let agentIntegration: AgentIntegrationHostAdapter
    /// Who has been driving this host over the local agent endpoint. Fed by
    /// the app delegate when it stands the server up; `.neverAttached` until
    /// something does, and for good on a Mac nothing ever does.
    let agentCompanions = AgentCompanionModel()
    /// What those companions have DONE — the audit stream the Agent page
    /// draws, fed from the same seam that writes the log line. Separate from
    /// the presence ledger above on purpose: that one records who and when
    /// and refuses to record what, and this is the what.
    let agentActivity = AgentActivityModel()
    let guestFiles: GuestFilesCommandService
    private let artifactApprovals: AgentIntegrationArtifactApprovalStore?
    /// The Connections page: which Macs are on the wire, which one the
    /// window and the agent surface are pointed at, and how to tell them
    /// apart.
    ///
    /// Selection routes through `selectGuest` rather than the listener
    /// directly, so a person choosing a row moves the whole window — the
    /// modules refocus with it — instead of moving the request plane out
    /// from under pages still showing the other Mac's rows.
    private(set) lazy var connections = ConnectionsModel(
        listener: listener,
        addressing: agentIntegration,
        select: { [weak self] key in self?.selectGuest(key) ?? false })
    private(set) lazy var console = ConsoleModel(listener: listener)
    /// The Mirror page. Guest-scoped like the rest — it is a claim about one
    /// machine, and everything it rests in is about WHICH Mac is connected,
    /// so it would be wrong the moment the picker moved.
    ///
    /// It takes the listener now: the page can ask the connected Mac for a
    /// scene, and the ask goes down the same wire and the same one transfer
    /// lane every other page shares.
    ///
    /// It also takes the act lane, which is what makes the drawing
    /// clickable: `MirrorActionDriver` is the seam between a gesture on a
    /// rendered scene and the acts NOW's contract declares. The page still
    /// refuses everything the vocabulary calls unsendable — the driver is a
    /// route, not a permission.
    ///
    /// The driver takes the window resolver too, and it is the same listener
    /// on purpose: a window act is addressed by a reference only an
    /// observation of that Mac can mint, so the ask goes down the control
    /// plane beside the act itself — never the transfer lane, which the
    /// stream drawing the scene is already holding.
    private(set) lazy var mirror = MirrorModuleModel(
        listener: listener,
        actions: MirrorActionDriver(
            adapter: agentIntegration,
            windows: MirrorWindowResolver(listener: listener)))
    private(set) lazy var chat = ChatModuleModel(
        agentIntegration: agentIntegration,
        guestFiles: guestFiles,
        agentActivity: agentActivity)
    private(set) lazy var census = CensusModuleModel(listener: listener)
    private(set) lazy var diagnostics = DiagnosticsModel(listener: listener)
    private(set) lazy var networking = NetworkingModel(listener: listener)
    private(set) lazy var cloudModule = CloudModuleModel(listener: listener)
    private(set) lazy var software = SoftwareModel(listener: listener)
    private(set) lazy var processes: ProcessesModel = {
        let model = ProcessesModel(listener: listener)
        // "Screenshot App" shows the Screenshots page and asks for a
        // window-cropped capture of the process. The guest owns the timing
        // (front, let it repaint, crop, deliver — process.shot), so there
        // is no delay to fake here.
        model.onScreenshotApp = { [weak self] psnHigh, psnLow in
            guard let self else { return }
            self.selectedModuleID = "screenshots"
            self.screenshots.captureProcess(psnHigh: psnHigh, psnLow: psnLow)
        }
        return model
    }()

    private let defaults: UserDefaults
    private static let selectionKey = "selectedModuleID"
    private var stateMirror: AnyCancellable?
    private var rosterMirror: AnyCancellable?
    private var knownGuests: Set<GuestKey> = []

    /// Every model that shows one machine's state. Listed once so a new
    /// module cannot be wired into the connection and forgotten by the
    /// switch — the two used to be separate assignments, and a module added
    /// to one and not the other is precisely the defect this list closes.
    private var guestScopedModels: [any GuestScopedModel] {
        [screenshots, files, census, diagnostics, processes, software,
         networking, mirror]
    }

    /// Points the whole window at another connected Mac.
    ///
    /// The listener moves the request plane; the models re-focus off the
    /// state change that follows, which is why this is two lines and not a
    /// broadcast. Returns false when the key names nobody, so a stale menu
    /// item is a no-op rather than a silent nothing.
    @discardableResult
    func selectGuest(_ key: GuestKey) -> Bool {
        listener.selectGuest(key)
    }

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        settings = SettingsModel(defaults: defaults)
        logs = LogsModel(log: .shared, defaults: defaults)
        listener = GuestListener(
            identity: .init(
                version: ProductIdentity.version,
                name: Host.current().localizedName ?? "Mac"),
            /* The one place that asks for machine handles to SURVIVE a
               relaunch. Everywhere else — tests, previews — gets the
               memory-only default and cannot write into a real desk's
               book of Macs. */
            registry: GuestRegistry(defaults: defaults))
        artifactApprovals = try? AgentIntegrationArtifactApprovalStore()
        let integration = AgentIntegrationHostAdapter(
            listener: listener,
            artifactApprovals: artifactApprovals)
        agentIntegration = integration
        guestFiles = GuestFilesCommandService(
            listener: listener,
            policy: GuestFileAccessPolicy(defaults: defaults),
            currentSessionID: {
                integration.connectedSessionID()
            })
        let stored = defaults.string(forKey: Self.selectionKey)
        /* Through the rename table, so a person whose saved selection is a
           module's OLD id lands on it rather than on the fallback. */
        selectedModuleID = stored.flatMap(registry.resolvingRenames(id:))?.id
            ?? registry.modules.first?.id
            ?? ""
        stateMirror = listener.$state.sink { [weak self] state in
            guard let self else { return }
            let connection = Self.guestState(
                from: state, key: self.listener.activeKey)
            /* One assignment per model, from one place, in one turn. The
               models decide for themselves what a switch means to them —
               see GuestScopedState.swift — but they must all learn about it
               at the same moment, or the window shows two machines at once
               for a frame. */
            for model in self.guestScopedModels {
                model.connection = connection
            }
            // The console's completions came from THIS guest's `help`, and
            // the next one may serve a different set — NOW-68K serves three
            // commands where the Carbon guest serves fifteen. So they go
            // with the connection rather than lingering as a list from a
            // machine that is no longer there.
            self.console.focus(on: connection)
            if case .connected = state {} else {
                self.console.forgetGuest()
            }
            self.captureSmokeIfRequested(state)
        }
        /* A guest leaving the roster is a different event to the active one
           changing, and only the models whose cache dies with the
           connection act on it. Diffed here rather than published as a
           departure, because the roster is the thing that is true. */
        rosterMirror = listener.$guests.sink { [weak self] guests in
            guard let self else { return }
            let now = Set(guests.map(\.key))
            for gone in self.knownGuests.subtracting(now) {
                for model in self.guestScopedModels {
                    model.guestLeft(gone)
                }
            }
            self.knownGuests = now
        }
        if settings.listenAtLaunch {
            startListening()
        }
    }

    func startListening() {
        listener.start(port: settings.listenPort)
    }

    func stopListening() {
        listener.stop()
    }

    /// Opt-in end-to-end proof: with NOW_HOST_SMOKE set, pull one capture as
    /// soon as a guest connects, write it to /tmp, and log the numbers.
    private func captureSmokeIfRequested(_ state: GuestListener.State) {
        guard ProcessInfo.processInfo.environment["NOW_HOST_SMOKE"] != nil,
              case .connected = state else { return }
        // Defer past @Published's willSet so the listener sees .connected.
        DispatchQueue.main.async { [listener] in
            listener.requestCapture(depth: 8) { result in
                switch result {
                case .success(let d):
                    let raw = d.format.rowBytes * d.format.height
                    var note = "[now-host] capture \(d.format.width)x"
                    note += "\(d.format.height) \(d.format.depth)-bit "
                    note += "wire \(d.wireBytes)B raw \(raw)B "
                    note += String(format: "%.1fx ", Double(raw)
                                   / Double(max(d.wireBytes, 1)))
                    note += "guest cap \(d.format.captureMs)ms enc "
                    note += "\(d.format.encodeMs)ms transfer \(d.transferMs)ms"
                    if let png = CaptureDecoder.pngData(d.image) {
                        let url = URL(fileURLWithPath:
                            "/tmp/now-capture-smoke.png")
                        try? png.write(to: url)
                        note += " png \(png.count)B -> \(url.path)"
                    }
                    FileHandle.standardError.write(Data((note + "\n").utf8))
                case .failure(let f):
                    FileHandle.standardError.write(Data(
                        "[now-host] capture failed: \(f.message)\n".utf8))
                }
            }
        }
    }

    /// The listener's state says WHO is connected by name; the key comes
    /// from the listener itself.
    ///
    /// It used to be DERIVED from the name, by the same folding rule the
    /// gate used — safe only for exactly as long as identity was the name.
    /// It is not: two Macs may share one, and a redeploy changes it. The
    /// key is now per connection and cannot be recomputed from anything
    /// visible here, so it is passed rather than reconstructed. `activeKey`
    /// is a plain property, settled before the state is published, so this
    /// reads the same turn's answer and not the previous one's.
    private static func guestState(from state: GuestListener.State,
                                   key: GuestKey?)
        -> GuestConnectionState {
        switch state {
        case .connected(let name):
            guard let key else { return .disconnected }
            return .connected(name: name, key: key)
        case .idle, .listening, .failed: return .disconnected
        }
    }
}
