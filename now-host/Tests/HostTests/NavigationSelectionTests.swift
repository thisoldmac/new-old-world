import XCTest
@testable import Host

@MainActor
final class NavigationSelectionTests: XCTestCase {
    func testPersistedModuleRestoresAsTheShelfTabWithoutChangingItsID() {
        let suite = "NavigationSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!.offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("software", forKey: "selectedModuleID")

        let state = HostAppState(registry: .standard, defaults: defaults)
        let selection = NavigationSelection.selecting(
            moduleID: state.selectedModuleID,
            in: .standard(for: .standard))

        XCTAssertEqual(state.selectedModuleID, "software")
        XCTAssertEqual(selection.destination, .module("software"))
        XCTAssertEqual(selection.containingShelfID, .machine)
    }

    func testPersistedModuleSelectionRestoresInsideItsShelf() {
        let selection = NavigationSelection.selecting(
            moduleID: "software",
            in: .standard(for: .standard))

        XCTAssertEqual(selection.destination, .module("software"))
        XCTAssertEqual(selection.containingShelfID, .machine)
    }

    func testViewMenuModuleSelectionRevealsItsContainingShelfAndTab() {
        let layout = NavigationLayout.standard(for: .standard)

        XCTAssertEqual(
            NavigationSelection.selecting(moduleID: "settings", in: layout),
            NavigationSelection(destination: .module("settings"),
                                containingShelfID: .network))
        XCTAssertEqual(
            NavigationSelection.selecting(moduleID: "mirror", in: layout),
            NavigationSelection(destination: .module("mirror"),
                                containingShelfID: .screen))
    }

    func testMachineHeroIsNotAStoredPseudoModule() throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .machine))

        XCTAssertEqual(NavigationSelection.selectingHero(of: shelf),
                       NavigationSelection(
                        destination: .shelfHero(.machine),
                        containingShelfID: .machine))
    }

    func testModuleBackedShelfHeroUsesTheStableModuleIdentifier() throws {
        let shelf = try XCTUnwrap(
            NavigationLayout.standard(for: .standard).shelf(id: .network))

        XCTAssertEqual(NavigationSelection.selectingHero(of: shelf),
                       NavigationSelection(
                        destination: .module("settings"),
                        containingShelfID: .network))
    }

    func testLooseModuleSelectionHasNoContainingShelf() {
        XCTAssertEqual(
            NavigationSelection.selectingLooseModule("chat"),
            NavigationSelection(destination: .module("chat"),
                                containingShelfID: nil))
    }

    func testMachineShelfUsesTheGuestNameOrTheDisconnectedLabel() {
        XCTAssertEqual(GuestStatus.connected(name: "PowerBook 1400c",
                                             quietFor: 0).machineShelfTitle,
                       "PowerBook 1400c")
        XCTAssertEqual(GuestStatus.notListening.machineShelfTitle,
                       "No Mac Connected")
        XCTAssertEqual(GuestStatus.waiting(port: 5250).machineShelfTitle,
                       "No Mac Connected")
        XCTAssertEqual(GuestStatus.failed("busy").machineShelfTitle,
                       "No Mac Connected")
    }
}
