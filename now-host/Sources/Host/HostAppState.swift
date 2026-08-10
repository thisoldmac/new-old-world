import Foundation
import Combine
import MirrorKit

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
        FilesModuleModel(
            listener: listener,
            defaults: defaults,
            artifactApprover: agentIntegration)
    }()

    /// A file the guest sent landed here — say so outside the window.
    ///
    /// This used to be an assignment hook on the listener
    /// (`announceReceivedFile`), set from the middle of `files`' lazy
    /// initialiser, which meant the notification only existed once somebody
    /// had touched the Files page and that exactly one thing could ever
    /// hear it. It is an event now, and this is one subscriber among
    /// however many want it.
    private lazy var arrivals: HostEventSubscription = listener.events
        .subscribe { [notifier] event in
            guard case .fileReceived(_, let url, let bytes, let guest) = event
            else { return }
            notifier.announce(fileFrom: guest, url: url, bytes: bytes)
        }

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

    /// Starting and stopping NOW's two MCP transports, set by the app delegate.
    ///
    /// Hooks rather than methods for the same reason as the flash above: the
    /// server object belongs to the delegate, which is the only thing whose
    /// lifetime matches a listening socket's, and a test or a preview that
    /// leaves these nil gets a pane with buttons that do nothing to any real
    /// socket instead of a host process with an endpoint it never wanted.
    var startMCPStdio: (() -> Void)?
    var stopMCPStdio: (() -> Void)?
    var startMCPHTTP: (() -> Void)?
    var stopMCPHTTP: (() -> Void)?

    /// Drives the menu bar's connection glyph and status line.
    private(set) lazy var guestStatus = GuestStatusMonitor(listener: listener)
    let settings: SettingsModel
    let onboarding: OnboardingPortal
    /// Not lazy: constructing it applies the saved disk-persistence switch
    /// to HostLog before the first wire event has a line to write.
    let logs: LogsModel
    let listener: GuestListener
    let mirrorEngines: MirrorStateEngineRegistry
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
    /// The one NOW Extension lifecycle and host plane policy for this Mac.
    /// It moves with the guest picker because every fact and policy claim is
    /// scoped to the selected wire session.
    private(set) lazy var mirror = MirrorControlModel(
        guestProbe: MirrorGuestWireProbe(listener: listener))
    /// The native data-driven Mirror source. It reads the same policy model
    /// the page renders, so the visible toggles are the claims this source
    /// actually makes.
    /// Whether `mirrorSource` has actually been made. The MCP metrics read
    /// must not be the thing that constructs the Mirror: an agent asking
    /// what has been measured would otherwise create the measurer and get
    /// an empty answer that reads like a quiet machine.
    private var madeMirrorSource = false

    private(set) lazy var mirrorSource: NOWMirrorSource = {
        madeMirrorSource = true
        let source = NOWMirrorSource(
            listener: listener,
            engineRegistry: mirrorEngines,
            act: AgentIntegrationActControl(
                listener: listener,
                currentSessionID: { [unowned self] in
                    self.agentIntegration.connectedSessionID()
                }),
            planePolicy: { [unowned self] key in
                self.mirror.requestedPlaneIDs(for: key)
            },
            finderComplementPolicy: { [unowned self] key in
                self.mirror.finderComplementsAllowed(for: key)
            },
            lifecycleDidChange: {
                [weak self] in self?.mirror.refreshLifecycle()
            })
        mirror.bindPolicyProjection { [weak source] in
            source?.planePolicyDidChange()
        }
        return source
    }()
    /// Where the Mirror is shown, and at what size. Persisted, so a
    /// person finds it where they left it.
    private(set) lazy var mirrorPresentation = MirrorPresentation(
        defaults: defaults)
    /// Whether it is running, which is a different question. See
    /// `MirrorRunControl` for why they had to stop being one.
    private(set) lazy var mirrorRun = MirrorRunControl(source: mirrorSource,
                                                       defaults: defaults)
    private(set) lazy var mirrorWindow = NOWMirrorWindow(
        source: mirrorSource, presentation: mirrorPresentation)

    /// **Show the Mirror on an already-running host, whoever asked.**
    ///
    /// The one implementation behind four faces: the Mirror page's own
    /// button, the Window menu item, the `mirror_open` agent verb and
    /// the guest's `host.show`. All of them end here, so none of them can
    /// drift into being a second way to do it.
    ///
    /// It exists because until now there was no third face at all.
    /// `--open-mirror` covers launch and a click covers a person at this
    /// Mac; an agent on the socket, and a person sitting at the classic
    /// Mac, had nothing — and the gap was closed in practice by
    /// scripting macOS accessibility to click the button, on somebody's
    /// actual desktop.
    ///
    /// **It resolves BOTH axes now, and the order matters.** Showing used
    /// to imply starting because a window was the only container and its
    /// `show()` called `source.start()`. With the two split, a `showmirror`
    /// against a stopped Mirror would otherwise put a frozen picture in
    /// front of somebody and refuse every act behind it — which is
    /// `docs/open-issues.md`'s "a window over a stopped poll" arriving
    /// through a new door. So: start first, then put it where it can be
    /// seen — raise the detached window if that is where it lives,
    /// otherwise select the module.
    ///
    /// Already showing is not an error. The asker wanted the Mirror in
    /// front of them, and it is.
    @discardableResult
    func showMirror() -> HostSurfaceOutcome {
        let name = connectedMachineName
        let detached = mirrorPresentation.isDetached
        let wasShowing = detached
            ? mirrorWindow.isOpen
            : selectedModuleID == "mirror"
        let wasRunning = mirrorSource.running
        guard wasRunning || Self.guestState(
            from: listener.state, key: listener.activeKey).canCapture else {
            /* Refused rather than shown-empty. A Mirror with no Mac
               behind it publishes nothing, so a caller that opened one
               would read an honest empty answer and have no way to tell
               it from a quiet machine — the same trap `--open-mirror`
               fell into before it learned to retry `start()`. */
            return .refused(
                code: "unavailable",
                reason: "No Mac is connected, so there is nothing to "
                    + "mirror yet.")
        }
        mirrorRun.start()
        if detached {
            mirrorWindow.show(title: "Mirror — \(name)")
        } else {
            selectedModuleID = "mirror"
        }
        /* **These sentences are read on the OTHER machine.** They cross
           the wire in `host.shown` and the guest draws them verbatim in
           its Mirror page's status line (`mirror_module.c:63-70`), so
           they must describe an outcome a person at a classic Mac can
           check, and must not name a host window that may not exist. */
        let place = detached ? "in its own window" : "on the Mirror page"
        return .showing(
            wasAlreadyOpen: wasShowing && wasRunning,
            detail: wasShowing && wasRunning
                ? "The Mirror was already running; brought it to the front "
                    + place + "."
                : "The Mirror is running on \(name), \(place).")
    }

    /// Whether `--open-mirror` has been honoured yet this launch. A guest
    /// that dials in, drops and redials must not be treated as a second
    /// launch request.
    private var didHonourMirrorLaunchRequest = false

    /// **A Mac arrived. Does the Mirror care?**
    ///
    /// Two independent reasons it might, and they are checked in the
    /// order of who asked most recently:
    ///
    /// 1. `--open-mirror` on argv, once per launch. It means *start*,
    ///    and shows the Mirror wherever the person last left it — the
    ///    headless sweep needs the poll and has no opinion about windows.
    /// Every later connection change reaches the already-created run control
    /// through `repointModels()`. Its in-process intent may resume there, but
    /// ordinary app launch always leaves Mirror off.
    private func mirrorFollowsTheConnection() {
        if MirrorLaunchOptions.parse(ProcessInfo.processInfo.arguments)
            .openAtLaunch, !didHonourMirrorLaunchRequest {
            didHonourMirrorLaunchRequest = true
            showMirror()
            return
        }
    }

    /// What to put in the mirror window's title bar. A person may have
    /// several Macs connected, and a window showing one of them that does
    /// not say which is a window they will drive by mistake.
    var connectedMachineName: String {
        if case .connected(let name, _) = Self.guestState(
            from: listener.state, key: listener.activeKey) {
            return name
        }
        return "no Mac connected"
    }
    /// **The guest's screen, or nothing.** The one place on this side that
    /// answers the question, and it answers it from the guest's own
    /// `scene.screen` — never from a constant. nil means `unknown`: no
    /// scene has arrived, so nobody has measured it.
    ///
    /// Deliberately does not construct the Mirror, for the same reason
    /// `bindMirrorMetrics` does not: asking what has been measured must
    /// not create the measurer and then answer for it.
    var guestScreenIfKnown: MirrorKit.Scene.ScreenSize? {
        guard madeMirrorSource else { return nil }
        return mirrorSource.scene?.screen.known
    }

    private(set) lazy var chat: ChatModuleModel = {
        let model = ChatModuleModel(
            agentIntegration: agentIntegration,
            guestFiles: guestFiles,
            agentActivity: agentActivity,
            guestScreen: { [weak self] in
                await MainActor.run {
                    self?.guestScreenIfKnown.flatMap {
                        ChatSystemPrompt.Screen(w: $0.w, h: $0.h)
                    }
                }
            })
        listener.chatService = model.wireService
        return model
    }()
    private(set) lazy var development = DevelopmentModel(
        store: try? ProjectStore(),
        readEnvironment: { [agentIntegration] in
            await agentIntegration.developmentEnvironment()
        },
        performDevelopment: { [agentIntegration] request in
            await agentIntegration.development(request)
        })
    private(set) lazy var census = CensusModuleModel(listener: listener)
    private(set) lazy var diagnostics = DiagnosticsModel(listener: listener)
    private(set) lazy var networking = NetworkingModel(listener: listener)
    private(set) lazy var cloudModule = CloudModuleModel(listener: listener)
    private(set) lazy var software = SoftwareModel(listener: listener)
    private(set) lazy var processes: ProcessesModel = {
        let model = ProcessesModel(listener: listener)
        // "Screenshot App" shows the Screen page and asks for a
        // window-cropped capture of the process. The guest owns the timing
        // (front, let it repaint, crop, deliver — process.shot), so there
        // is no delay to fake here.
        model.onScreenshotApp = { [weak self] psnHigh, psnLow in
            guard let self else { return }
            self.selectedModuleID = "screen"
            self.screenshots.captureProcess(psnHigh: psnHigh, psnLow: psnLow)
        }
        return model
    }()

    private let defaults: UserDefaults
    private static let selectionKey = "selectedModuleID"
    /// The one subscription that re-points every guest-scoped model.
    private var focusWatch: HostEventSubscription?

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
        listener.selectGuest(key) { [weak self] in
            guard let self, self.madeMirrorSource else { return }
            self.mirrorRun.activeGuestWillChange()
        }
    }

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        settings = SettingsModel(defaults: defaults)
        onboarding = OnboardingPortal()
        logs = LogsModel(log: .shared, defaults: defaults)
        mirrorEngines = MirrorStateEngineRegistry()
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
            artifactApprovals: artifactApprovals,
            mirrorEngines: mirrorEngines)
        agentIntegration = integration
        guestFiles = GuestFilesCommandService(
            listener: listener,
            policy: GuestFileAccessPolicy(defaults: defaults),
            currentSessionID: {
                integration.connectedSessionID()
            })
        /* Forced now rather than at first page view: a guest may ask
           chat.models before anyone opens the Chat page, and a lazy
           wire service would answer that with pre-family silence. */
        defer { _ = chat }
        let stored = defaults.string(forKey: Self.selectionKey)
        /* Through the rename table, so a person whose saved selection is a
           module's OLD id lands on it rather than on the fallback. */
        selectedModuleID = stored.flatMap(registry.resolvingRenames(id:))?.id
            ?? registry.modules.first?.id
            ?? ""
        _ = arrivals
        focusWatch = listener.events.subscribe { [weak self] event in
            guard let self else { return }
            switch event {
            /* Both, because either can change what "the machine on screen"
               means: the link going down with one Mac attached, and the
               focus moving between two that are both up. They settle in
               either order, so this reads the listener rather than the
               event's payload. */
            case .linkStateChanged, .focusChanged:
                self.repointModels()
            /* A guest leaving is a different event to the active one
               changing, and only the models whose cache dies with the
               connection act on it. It arrives named now; it used to be
               DIFFED out of the roster here, which was a second thing that
               had to agree with the listener about who had gone. */
            case .guestDisconnected(let gone, _):
                for model in self.guestScopedModels {
                    model.guestLeft(gone)
                }
            default:
                break
            }
        }
        /* Bound at the end of init, once every stored property exists: the
           closure captures self, and the Mirror source it reads is made
           lazily. A metrics read must never be the thing that constructs
           the Mirror — an agent asking what has been measured would then
           create the measurer and get an empty answer that reads exactly
           like a quiet machine. */
        /* The guest's face on the same implementation. Bound here rather
           than in the listener's own init for the reason the drivers
           below are: the window layer is the app's, and a listener
           running without one must refuse by name instead of pretending. */
        listener.hostSurfaceOpener = { [weak self] surface in
            guard let self else {
                return .refused(code: "unavailable",
                                reason: "This Mac is shutting down.")
            }
            switch surface {
            case .mirror: return self.showMirror()
            }
        }
        integration.bindMirrorOpener { [weak self] in
            guard let self else {
                return .refused(code: "unavailable",
                                reason: "This Mac is shutting down.")
            }
            return self.showMirror()
        }
        integration.bindMirrorDriver { [weak self] request in
            guard let self else {
                return .init(unavailable: .init(
                    code: "now-mirror-drive-unavailable",
                    message: "The host is shutting down"))
            }
            /* Reading `mirrorSource` here DOES make it, unlike the metrics
               reader. That is the difference between asking what has been
               measured and asking for something to be done: a drive is a
               request to act, and refusing it because nobody had opened a
               window yet would be refusing the thing that was asked for. */
            let source = self.mirrorSource
            return MirrorDriveService(
                /* Resolve the entity against the same immutable publication
                   the MCP snapshot projected. `source.scene` is the rendered
                   view and can still be independently enriched by host UI;
                   using it here recreated two semantic authorities. */
                scene: { source.shadowEngine?.snapshot?.scene },
                perform: { source.perform($0, source: .mcp) },
                journal: { source.shadowEngine?.operations },
                cancel: { source.cancelPendingActs() })
                .drive(request)
        }
        integration.bindMirrorLifecycle { [weak self] in
            guard let self, let facts = self.mirror.wireFacts else {
                return nil
            }
            return .init(
                lifecycle: facts.resident.lifecycle.rawValue,
                residentBuild: facts.resident.buildFingerprint,
                residentMajor: facts.resident.residentMajor,
                residentMinor: facts.resident.residentMinor,
                capabilities: facts.resident.capabilities,
                requested: facts.resident.requested,
                active: facts.resident.active,
                reason: facts.resident.reason,
                planes: facts.planes.map { plane in
                    .init(id: plane.id.rawValue, title: plane.id.title,
                          purpose: plane.purpose, format: plane.format,
                          generation: plane.generation,
                          requestedByHost:
                            self.mirror.policyEnabled(plane.id))
                })
        }
        integration.bindMirrorMetrics { [weak self] in
            guard let self, self.madeMirrorSource else { return nil }
            return self.mirrorSource.actTimeline.projected(
                cycles: self.mirrorSource.cycleTimeline,
                running: self.mirrorSource.running,
                scheduler: self.listener.workScheduler.snapshot(),
                work: self.listener.workTimeline.entries)
        }
        if settings.listenAtLaunch {
            startListening()
        }
    }

    /// One assignment per model, from one place, in one turn. The models
    /// decide for themselves what a switch means to them — see
    /// GuestScopedState.swift — but they must all learn about it at the same
    /// moment, or the window shows two machines at once for a frame.
    private func repointModels() {
        let state = listener.state
        let connection = Self.guestState(from: state, key: listener.activeKey)
        for model in guestScopedModels {
            model.connection = connection
        }
        /* Do not construct the Mirror merely because a connection changed.
           Once it exists, however, its pinned GuestKey is session state and
           must cross the same boundary as every model above. */
        if madeMirrorSource {
            mirrorRun.activeGuestDidChange()
        }
        // The console's completions came from THIS guest's `help`, and the
        // next one may serve a different set — NOW-68K serves three commands
        // where the Carbon guest serves fifteen. So they go with the
        // connection rather than lingering as a list from a machine that is
        // no longer there.
        console.focus(on: connection)
        if case .connected = state {} else {
            console.forgetGuest()
        }
        captureSmokeIfRequested(state)
        /* Re-attached at the 019 integration, when this body moved out of
           the event closure and into a method. Every connection change
           comes through this door and this door only, which is what lets
           `mirrorFollowsTheConnection` be asked repeatedly — see its own
           comment: an open window is not a running poll, and the launch
           request arrives before the listener has an active key.

           It replaced `mirrorWindow.openIfLaunchAsked` at the round-3
           integration. The window can no longer answer this question,
           because with the Mirror embedded as a module there may be no
           window: the two axes are RUNNING and WHERE, and only the app
           knows both. */
        if case .connected = state {
            mirrorFollowsTheConnection()
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
