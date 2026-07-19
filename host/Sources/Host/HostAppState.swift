import Foundation

@MainActor
final class HostAppState: ObservableObject {
    @Published var selectedModuleID: String {
        didSet { defaults.set(selectedModuleID, forKey: Self.selectionKey) }
    }
    let screenshots = ScreenshotModuleModel()

    private let defaults: UserDefaults
    private static let selectionKey = "selectedModuleID"

    init(registry: ModuleRegistry,
         defaults: UserDefaults = UserDefaults(
             suiteName: ProductIdentity.preferencesSuite) ?? .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.selectionKey)
        selectedModuleID = stored.flatMap(registry.module(id:))?.id
            ?? registry.modules.first?.id
            ?? ""
    }
}

