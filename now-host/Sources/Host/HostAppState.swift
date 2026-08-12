import Foundation
import Combine
import MirrorKit
import SwiftUI

@MainActor
final class HostAppState: ObservableObject {
    @Published var selectedModuleID: String {
        didSet { defaults.set(selectedModuleID, forKey: Self.selectionKey) }
    }
    private let notifier = CaptureNotifier()

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
        mirrorRuntime?.show() ?? .refused(
            code: "unavailable", reason: "The Mirror is unavailable.")
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
        existingMirrorRuntime?.guestScreenIfKnown
    }

    private let defaults: UserDefaults
    private static let selectionKey = "selectedModuleID"
    /// The one subscription that re-focuses every constructed module runtime.
    private var focusWatch: HostEventSubscription?

    private lazy var moduleRuntimes = HostModuleRuntimeStore(
        registry: moduleRegistry,
        context: HostModuleContext(
            listener: listener,
            currentConnection: { [unowned self] in self.currentConnection },
            defaults: defaults,
            artifactApprover: agentIntegration,
            agentIntegration: agentIntegration,
            guestFiles: guestFiles,
            agentActivity: agentActivity,
            agentCompanions: agentCompanions,
            logs: logs,
            guestScreen: { [weak self] in
                await MainActor.run {
                    self?.guestScreenIfKnown.flatMap {
                        ChatSystemPrompt.Screen(w: $0.w, h: $0.h)
                    }
                }
            },
            mirrorEngines: mirrorEngines,
            selectedModuleID: { [unowned self] in self.selectedModuleID },
            selectModule: { [unowned self] in self.selectedModuleID = $0 },
            connectedMachineName: { [unowned self] in
                self.connectedMachineName
            }))
    private let moduleRegistry: ModuleRegistry

    /// Points the whole window at another connected Mac.
    ///
    /// The listener moves the request plane; the models re-focus off the
    /// state change that follows, which is why this is two lines and not a
    /// broadcast. Returns false when the key names nobody, so a stale menu
    /// item is a no-op rather than a silent nothing.
    @discardableResult
    func selectGuest(_ key: GuestKey) -> Bool {
        listener.selectGuest(key) { [weak self] in
            self?.existingMirrorRuntime?.activeGuestWillChange()
        }
    }

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        moduleRegistry = registry
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
        /* Forced now rather than at first page view. A guest may ask
           chat.models before anyone opens Chat, and the app delegate binds
           MCP's transport controls before anyone opens MCP. The runtimes
           remain module-owned; this only admits both eager services. */
        defer {
            _ = moduleRuntime(for: "chat", as: ChatHostModuleRuntime.self)
            _ = moduleRuntime(for: "mcp", as: MCPHostModuleRuntime.self)
        }
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
                self.moduleRuntimes.guestLeft(gone)
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
            guard let runtime = self?.mirrorRuntime else {
                return .init(unavailable: .init(
                    code: "now-mirror-drive-unavailable",
                    message: "The host is shutting down"))
            }
            return runtime.drive(request)
        }
        integration.bindMirrorLifecycle { [weak self] in
            self?.mirrorRuntime?.lifecycle
        }
        integration.bindMirrorMetrics { [weak self] in
            self?.existingMirrorRuntime?.metrics
        }
        if settings.listenAtLaunch {
            startListening()
        }
    }

    /// Bind the MCP page to the delegate-owned transport lifecycles.
    /// The sockets remain application services; the module owns the controls
    /// that expose them and clears those controls when its runtime shuts down.
    func configureMCPTransports(
        startStdio: @escaping () -> Void,
        stopStdio: @escaping () -> Void,
        startHTTP: @escaping () -> Void,
        stopHTTP: @escaping () -> Void
    ) {
        moduleRuntime(for: "mcp", as: MCPHostModuleRuntime.self)?
            .configureTransports(
                startStdio: startStdio, stopStdio: stopStdio,
                startHTTP: startHTTP, stopHTTP: stopHTTP)
    }

    /// One assignment per model, from one place, in one turn. The models
    /// decide for themselves what a switch means to them — see
    /// GuestScopedState.swift — but they must all learn about it at the same
    /// moment, or the window shows two machines at once for a frame.
    private func repointModels() {
        let state = listener.state
        let connection = Self.guestState(from: state, key: listener.activeKey)
        moduleRuntimes.focus(on: connection)
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

    func moduleView(registry: ModuleRegistry, id: String) -> AnyView {
        precondition(registry.modules.map(\.id) == moduleRegistry.modules.map(\.id),
                     "HostRootView must render the state registry")
        return moduleRuntimes.view(for: id, state: self)
    }

    func runConsoleHelp() {
        moduleRuntimes.runtime(
            for: ConsoleHostModule.definition.descriptor.id,
            as: ConsoleHostModuleRuntime.self)?.runHelp()
    }

    func moduleRuntime<Runtime: HostModuleRuntime>(
        for id: String, as type: Runtime.Type
    ) -> Runtime? {
        moduleRuntimes.runtime(for: id, as: type)
    }

    private var mirrorRuntime: MirrorHostModuleRuntime? {
        moduleRuntimes.runtime(
            for: MirrorHostModule.definition.descriptor.id,
            as: MirrorHostModuleRuntime.self)
    }

    private var existingMirrorRuntime: MirrorHostModuleRuntime? {
        moduleRuntimes.existingRuntime(
            for: MirrorHostModule.definition.descriptor.id,
            as: MirrorHostModuleRuntime.self)
    }

    private var screenRuntime: ScreenHostModuleRuntime? {
        moduleRuntimes.runtime(
            for: ScreenHostModule.definition.descriptor.id,
            as: ScreenHostModuleRuntime.self)
    }

    var quickCaptureReadiness: QuickCaptureReadiness {
        screenRuntime?.quickCapture.readiness
            ?? .init(isEnabled: false, reason: "Screen is unavailable")
    }

    func setQuickCaptureFeedback(
        _ feedback: @escaping (QuickCaptureOutcome) -> Void
    ) {
        screenRuntime?.quickCaptureFeedback = feedback
    }

    func runQuickCapture() {
        screenRuntime?.quickCapture.run()
    }

    func captureProcess(psnHigh: Int, psnLow: Int) {
        screenRuntime?.model.captureProcess(psnHigh: psnHigh, psnLow: psnLow)
    }

    func shutDownModules() {
        moduleRuntimes.shutDown()
    }

    var currentConnection: GuestConnectionState {
        Self.guestState(from: listener.state, key: listener.activeKey)
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
