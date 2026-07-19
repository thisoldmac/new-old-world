import XCTest
@testable import Host

@MainActor
final class HostAppStateTests: XCTestCase {
    func testInvalidPersistedSelectionFallsBackToFirstModule() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-module", forKey: "selectedModuleID")

        let state = HostAppState(registry: .standard, defaults: defaults)

        XCTAssertEqual(state.selectedModuleID, "screenshots")
    }

    func testSelectionPersists() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ModuleRegistry(modules: [
            ModuleDescriptor(id: "screenshots", title: "Screenshots",
                             symbol: "camera", summary: "Capture"),
            ModuleDescriptor(id: "settings", title: "Settings",
                             symbol: "gear", summary: "Configure"),
        ])
        let state = HostAppState(registry: registry, defaults: defaults)

        state.selectedModuleID = "settings"

        XCTAssertEqual(defaults.string(forKey: "selectedModuleID"), "settings")
    }
}

