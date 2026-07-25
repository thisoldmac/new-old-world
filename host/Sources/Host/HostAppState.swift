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

    /// Drives the menu bar's connection glyph and status line.
    private(set) lazy var guestStatus = GuestStatusMonitor(listener: listener)
    let settings: SettingsModel
    /// Not lazy: constructing it applies the saved disk-persistence switch
    /// to HostLog before the first wire event has a line to write.
    let logs: LogsModel
    let listener: GuestListener
    let agentIntegration: AgentIntegrationHostAdapter
    let guestFiles: GuestFilesCommandService
    private let artifactApprovals: AgentIntegrationArtifactApprovalStore?
    private(set) lazy var console = ConsoleModel(listener: listener)
    private(set) lazy var census = CensusModuleModel(listener: listener)
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

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        settings = SettingsModel(defaults: defaults)
        logs = LogsModel(log: .shared, defaults: defaults)
        listener = GuestListener(identity: .init(
            version: ProductIdentity.version,
            name: Host.current().localizedName ?? "Mac"))
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
        selectedModuleID = stored.flatMap(registry.module(id:))?.id
            ?? registry.modules.first?.id
            ?? ""
        stateMirror = listener.$state.sink { [weak self] state in
            self?.screenshots.connection = Self.guestState(from: state)
            self?.files.connection = Self.guestState(from: state)
            self?.census.connection = Self.guestState(from: state)
            self?.processes.connection = Self.guestState(from: state)
            self?.software.connection = Self.guestState(from: state)
            // The console's completions came from THIS guest's `help`, and
            // the next one may serve a different set — NOW-68K serves three
            // commands where the Carbon guest serves fifteen. So they go
            // with the connection rather than lingering as a list from a
            // machine that is no longer there.
            if case .connected = state {} else {
                self?.console.forgetGuest()
            }
            self?.captureSmokeIfRequested(state)
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

    private static func guestState(from state: GuestListener.State)
        -> GuestConnectionState {
        switch state {
        case .connected(let name): return .connected(name: name)
        case .idle, .listening, .failed: return .disconnected
        }
    }
}
