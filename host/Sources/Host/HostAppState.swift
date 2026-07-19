import Foundation
import Combine

@MainActor
final class HostAppState: ObservableObject {
    @Published var selectedModuleID: String {
        didSet { defaults.set(selectedModuleID, forKey: Self.selectionKey) }
    }
    let screenshots = ScreenshotModuleModel()
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

    private static func guestState(from state: GuestListener.State)
        -> GuestConnectionState {
        switch state {
        case .connected(let name): return .connected(name: name)
        case .idle, .listening, .failed: return .disconnected
        }
    }
}

