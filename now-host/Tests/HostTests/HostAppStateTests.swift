import XCTest
@testable import Host

@MainActor
final class HostAppStateTests: XCTestCase {
    /// `offTheWire()` on every suite here: none of these tests is about the
    /// wire, and without it each one binds 5250 for the rest of the run.
    func testInvalidPersistedSelectionFallsBackToFirstModule() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!.offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-module", forKey: "selectedModuleID")

        let state = HostAppState(registry: .standard, defaults: defaults)

        XCTAssertEqual(state.selectedModuleID, "screen")
    }

    /// The footer is drawn apart from the list but selected the same way, so
    /// a relaunch has to restore it like any other module.
    func testPersistedFooterSelectionSurvivesRelaunch() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!.offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("settings", forKey: "selectedModuleID")

        let state = HostAppState(registry: .standard, defaults: defaults)

        XCTAssertEqual(state.selectedModuleID, "settings")
        XCTAssertEqual(ModuleRegistry.standard
            .module(id: state.selectedModuleID)?.placement, .footer)
    }

    /// **A saved selection naming a module's old id lands on the module,
    /// not on the fallback.**
    ///
    /// The Agent page became the MCP page. A person who was last looking at
    /// it has `agent` in their preferences, and without the rename table
    /// that resolves to nothing and they are silently moved to Screen
    /// — which reads as the app forgetting them rather than as a rename.
    func testAPersistedSelectionSurvivesTheModuleBeingRenamed() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!.offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("agent", forKey: "selectedModuleID")

        let state = HostAppState(registry: .standard, defaults: defaults)

        XCTAssertEqual(state.selectedModuleID, "mcp")
    }

    func testSelectionPersists() {
        let suite = "HostAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!.offTheWire()
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


/// The log file, which exists because the window forgets.
@MainActor
final class HostLogTests: XCTestCase {
    func testTheLogFileIsWrittenAndTailable() throws {
        let log = HostLog.shared
        let url = try XCTUnwrap(log.url, "a log file should have been opened")
        XCTAssertTrue(url.path.contains("now-logs"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".log"))

        log.write(.info, "app", "a line worth keeping")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("a line worth keeping"))
        XCTAssertTrue(text.hasSuffix("\n"), "one line per line, for tail")

        // Timestamped per launch: the name has to sort chronologically.
        let name = url.deletingPathExtension().lastPathComponent
        XCTAssertNotNil(DateFormatter.now_test_stamp.date(from: name),
                        "the file name is the launch time: \(name)")
    }
}

extension DateFormatter {
    static let now_test_stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()
}
