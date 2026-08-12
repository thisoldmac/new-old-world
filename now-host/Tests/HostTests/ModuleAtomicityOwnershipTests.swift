import XCTest
@testable import Host

@MainActor
final class ModuleAtomicityOwnershipTests: XCTestCase {
    func testConsoleDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = ConsoleHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "console")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testConsoleRuntimeIsResolvedLazilyThroughTheStore() {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let store = HostModuleRuntimeStore(
            registry: ModuleRegistry(definitions: [ConsoleHostModule.definition]),
            context: HostModuleContext(
                listener: listener,
                currentConnection: { .disconnected }))

        XCTAssertFalse(store.isConstructed("console"))
        let runtime = store.runtime(
            for: "console", as: ConsoleHostModuleRuntime.self)
        XCTAssertNotNil(runtime)
        XCTAssertTrue(store.isConstructed("console"))
        XCTAssertEqual(runtime?.model.lines.count, 1)
    }

    func testConsoleOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/console/console_module_definition.c")

        XCTAssertFalse(state.contains("lazy var console"))
        XCTAssertFalse(compatibility.contains("case \"console\""))
        XCTAssertFalse(registry.contains("k_console_definition"))
        XCTAssertTrue(registry.contains("console_module_definition()"))
        XCTAssertTrue(definition.contains("\"console\""))
        XCTAssertTrue(definition.contains("console_module_ops"))
    }

    func testHardwareDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = CensusHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "census")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testHardwareOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/census/census_module_definition.c")

        XCTAssertFalse(state.contains("lazy var census"))
        XCTAssertFalse(compatibility.contains("case \"census\""))
        XCTAssertFalse(registry.contains("k_hardware_definition"))
        XCTAssertTrue(registry.contains("census_module_definition()"))
        XCTAssertTrue(definition.contains("\"census\""))
        XCTAssertTrue(definition.contains("census_module_ops"))
    }

    func testSoftwareDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = SoftwareHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "software")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testSoftwareOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/software/software_module_definition.c")

        XCTAssertFalse(state.contains("lazy var software"))
        XCTAssertFalse(compatibility.contains("case \"software\""))
        XCTAssertFalse(registry.contains("k_software_definition"))
        XCTAssertTrue(registry.contains("software_module_definition()"))
        XCTAssertTrue(definition.contains("\"software\""))
        XCTAssertTrue(definition.contains("software_module_ops"))
    }

    func testScreenDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = ScreenHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "screen")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testScreenOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/screenshots/screenshots_module_definition.c")

        XCTAssertFalse(state.contains("lazy var screenshots"))
        XCTAssertFalse(state.contains("lazy var quickCapture"))
        XCTAssertFalse(compatibility.contains("case \"screen\""))
        XCTAssertFalse(registry.contains("k_screenshots_definition"))
        XCTAssertTrue(registry.contains("screenshots_module_definition()"))
        XCTAssertTrue(definition.contains("\"screen\""))
        XCTAssertTrue(definition.contains("screenshots_module_ops"))
    }

    func testFilesDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = FilesHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "files")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testFilesOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/files/files_module_definition.c")

        XCTAssertFalse(state.contains("lazy var files"))
        XCTAssertFalse(compatibility.contains("case \"files\""))
        XCTAssertFalse(registry.contains("k_files_definition"))
        XCTAssertTrue(registry.contains("files_module_definition()"))
        XCTAssertTrue(definition.contains("\"files\""))
        XCTAssertTrue(definition.contains("files_module_ops"))
    }
}
