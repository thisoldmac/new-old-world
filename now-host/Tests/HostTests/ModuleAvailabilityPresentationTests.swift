import XCTest
@testable import Host

final class ModuleAvailabilityPresentationTests: XCTestCase {
    func testDisconnectedModulesHaveOneExplicitAvailabilityPolicy() {
        let expected: [String: ModuleAvailability] = [
            "files": .local,
            "icloud": .local,
            "chat": .local,
            "web": .local,
            "development": .local,
            "mcp": .local,
            "logs": .local,
            "settings": .local,
            "screen": .reduced,
            "processes": .unavailable,
            "mirror": .reduced,
            "console": .reduced,
            "census": .reduced,
            "diagnostics": .reduced,
            "software": .unavailable,
            "networking": .unavailable,
        ]

        XCTAssertEqual(Set(expected.keys),
                       Set(ModuleRegistry.standard.modules.map(\.id)),
                       "A new module needs an explicit disconnected policy")
        for (moduleID, availability) in expected {
            XCTAssertEqual(
                ModuleAvailabilityPresentation.resolve(
                    moduleID: moduleID,
                    status: .waiting(port: 5250)).availability,
                availability,
                moduleID)
        }
    }

    func testEveryModuleIsAvailableWhileAConnectionIsLive() {
        for module in ModuleRegistry.standard.modules {
            XCTAssertEqual(
                ModuleAvailabilityPresentation.resolve(
                    moduleID: module.id,
                    status: .connected(name: "PowerBook", quietFor: 0))
                    .availability,
                .available,
                module.id)
        }
    }

    func testMirrorKeepsItsOwnedDisconnectedPresentation() {
        let mirror = ModuleAvailabilityPresentation.resolve(
            moduleID: "mirror", status: .notListening)

        XCTAssertEqual(mirror.availability, .reduced)
        XCTAssertEqual(mirror.shellTreatment, .none)
    }

    func testReducedAndUnavailableTreatmentsAreDifferent() {
        XCTAssertEqual(
            ModuleAvailabilityPresentation.resolve(
                moduleID: "diagnostics", status: .notListening).shellTreatment,
            .staleBanner)
        XCTAssertEqual(
            ModuleAvailabilityPresentation.resolve(
                moduleID: "networking", status: .failed("port busy"))
                .shellTreatment,
            .unavailable)
    }

}
