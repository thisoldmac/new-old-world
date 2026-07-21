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
        return FilesModuleModel(listener: listener, defaults: defaults)
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
    let listener: GuestListener
    private(set) lazy var console = ConsoleModel(listener: listener)

    private let defaults: UserDefaults
    private static let selectionKey = "selectedModuleID"
    private var stateMirror: AnyCancellable?

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        settings = SettingsModel(defaults: defaults)
        listener = GuestListener(identity: .init(
            version: ProductIdentity.version,
            name: Host.current().localizedName ?? "Mac"))
        let stored = defaults.string(forKey: Self.selectionKey)
        selectedModuleID = stored.flatMap(registry.module(id:))?.id
            ?? registry.modules.first?.id
            ?? ""
        stateMirror = listener.$state.sink { [weak self] state in
            self?.screenshots.connection = Self.guestState(from: state)
            self?.files.connection = Self.guestState(from: state)
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

