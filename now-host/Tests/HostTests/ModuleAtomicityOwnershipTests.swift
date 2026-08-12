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

    func testProcessesDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = ProcessesHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "processes")
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testProcessesOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let model = try GateSource.hostSwift(
            "now-host/Sources/Host/ProcessesModel.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/processes/processes_module_definition.c")

        XCTAssertFalse(state.contains("lazy var processes"))
        XCTAssertFalse(state.contains("onScreenshotApp"))
        XCTAssertFalse(model.contains("onScreenshotApp"))
        XCTAssertFalse(compatibility.contains("case \"processes\""))
        XCTAssertFalse(registry.contains("k_processes_definition"))
        XCTAssertTrue(registry.contains("processes_module_definition()"))
        XCTAssertTrue(definition.contains("\"processes\""))
        XCTAssertTrue(definition.contains("processes_module_ops"))
    }

    func testCloudDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = CloudHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "icloud")
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testCloudOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/cloud/cloud_module_definition.c")

        XCTAssertFalse(state.contains("lazy var cloudModule"))
        XCTAssertFalse(compatibility.contains("case \"icloud\""))
        XCTAssertFalse(registry.contains("k_cloud_definition"))
        XCTAssertTrue(registry.contains("cloud_module_definition()"))
        XCTAssertTrue(definition.contains("\"icloud\""))
        XCTAssertTrue(definition.contains("cloud_module_ops"))
    }

    func testChatDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = ChatHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "chat")
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testChatRuntimeIsEagerAndOwnsTheWireService() {
        let suite = "ChatModuleOwnership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)

        XCTAssertNotNil(state.listener.chatService,
                        "chat.* must be served before the page is opened")
        XCTAssertNotNil(state.moduleRuntime(
            for: "chat", as: ChatHostModuleRuntime.self))

        state.shutDownModules()
        XCTAssertNil(state.listener.chatService)
    }

    func testChatOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/chat/chat_module_definition.c")

        XCTAssertFalse(state.contains("lazy var chat"))
        XCTAssertFalse(compatibility.contains("case \"chat\""))
        XCTAssertFalse(registry.contains("k_chat_definition"))
        XCTAssertTrue(registry.contains("chat_module_definition()"))
        XCTAssertTrue(definition.contains("\"chat\""))
        XCTAssertTrue(definition.contains("chat_module_ops"))
    }

    func testWebDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = WebHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "web")
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testWebOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/WebHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/web/web_module_definition.c")

        XCTAssertFalse(state.contains("lazy var web"))
        XCTAssertFalse(compatibility.contains("case \"web\""))
        XCTAssertTrue(runtime.contains("model.stop()"))
        XCTAssertFalse(registry.contains("k_web_definition"))
        XCTAssertTrue(registry.contains("web_module_definition()"))
        XCTAssertTrue(definition.contains("\"web\""))
        XCTAssertTrue(definition.contains("web_module_ops"))
    }

    func testDevelopmentDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = DevelopmentHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "development")
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testDevelopmentOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/development/development_module_definition.c")

        XCTAssertFalse(state.contains("lazy var development"))
        XCTAssertFalse(compatibility.contains("case \"development\""))
        XCTAssertFalse(registry.contains("k_development_definition"))
        XCTAssertTrue(registry.contains("development_module_definition()"))
        XCTAssertTrue(definition.contains("\"development\""))
        XCTAssertTrue(definition.contains("development_module_ops"))
    }
}
