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

    func testMirrorDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = MirrorHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "mirror")
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testMirrorOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/mirror/mirror_module_definition.c")

        XCTAssertFalse(state.contains("lazy var mirror"))
        XCTAssertFalse(state.contains("lazy var mirrorSource"))
        XCTAssertFalse(compatibility.contains("case \"mirror\""))
        XCTAssertTrue(runtime.contains("run.stop()"))
        XCTAssertTrue(runtime.contains("window.close()"))
        XCTAssertFalse(registry.contains("k_mirror_definition"))
        XCTAssertTrue(registry.contains("mirror_module_definition()"))
        XCTAssertTrue(definition.contains("\"mirror\""))
        XCTAssertTrue(definition.contains("mirror_module_ops"))
    }

    func testMCPDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = MCPHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "mcp")
        XCTAssertEqual(definition.descriptor.placement, .footer)
        XCTAssertEqual(definition.descriptor.tier, .experimental)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testMCPRuntimeOwnsAndReleasesTransportControls() throws {
        let runtime = try MCPHostModuleRuntime(context: HostModuleContext(
            listener: GuestListener(
                identity: .init(version: "test", name: "Test Host")),
            currentConnection: { .disconnected },
            agentActivity: AgentActivityModel(),
            agentCompanions: AgentCompanionModel()))
        var calls: [String] = []

        runtime.configureTransports(
            startStdio: { calls.append("start-stdio") },
            stopStdio: { calls.append("stop-stdio") },
            startHTTP: { calls.append("start-http") },
            stopHTTP: { calls.append("stop-http") })
        runtime.startStdio?()
        runtime.stopStdio?()
        runtime.startHTTP?()
        runtime.stopHTTP?()

        XCTAssertEqual(calls, [
            "start-stdio", "stop-stdio", "start-http", "stop-http",
        ])
        runtime.shutDown()
        XCTAssertNil(runtime.startStdio)
        XCTAssertNil(runtime.stopStdio)
        XCTAssertNil(runtime.startHTTP)
        XCTAssertNil(runtime.stopHTTP)
    }

    func testMCPOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/MCPHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/mcp/mcp_module_definition.c")

        XCTAssertFalse(state.contains("var startMCPStdio"))
        XCTAssertFalse(state.contains("var stopMCPStdio"))
        XCTAssertFalse(state.contains("var startMCPHTTP"))
        XCTAssertFalse(state.contains("var stopMCPHTTP"))
        XCTAssertFalse(compatibility.contains("case \"mcp\""))
        XCTAssertTrue(runtime.contains("func shutDown()"))
        XCTAssertFalse(registry.contains("k_mcp_definition"))
        XCTAssertTrue(registry.contains("mcp_module_definition()"))
        XCTAssertTrue(definition.contains("\"mcp\""))
        XCTAssertTrue(definition.contains("mcp_module_ops"))
    }

    func testDiagnosticsDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = DiagnosticsHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "diagnostics")
        XCTAssertEqual(definition.descriptor.tier, .debug)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testDiagnosticsOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/DiagnosticsHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/diagnostics/diagnostics_module_definition.c")

        XCTAssertFalse(state.contains("lazy var diagnostics"))
        XCTAssertFalse(state.contains("guestScopedModels"))
        XCTAssertFalse(compatibility.contains("case \"diagnostics\""))
        XCTAssertTrue(runtime.contains("model.connection = connection"))
        XCTAssertTrue(runtime.contains("model.guestLeft(key)"))
        XCTAssertFalse(registry.contains("k_diagnostics_definition"))
        XCTAssertTrue(registry.contains("diagnostics_module_definition()"))
        XCTAssertTrue(definition.contains("\"diagnostics\""))
        XCTAssertTrue(definition.contains("diagnostics_module_ops"))
    }

    func testLogsDefinitionOwnsItsRuntimeAndMetadata() throws {
        let definition = LogsHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "logs")
        XCTAssertEqual(definition.descriptor.placement, .footer)
        XCTAssertEqual(definition.descriptor.tier, .debug)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)

        let listener = GuestListener(
            identity: .init(version: "test", name: "Test Host"))
        let suite = "LogsModuleOwnership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "logsPersistsToDisk")
        let logs = LogsModel(log: .shared, defaults: defaults)
        let runtime = try LogsHostModuleRuntime(context: HostModuleContext(
            listener: listener,
            currentConnection: { .disconnected },
            logs: logs))

        XCTAssertTrue(runtime.model === logs,
                      "the module must reference the eager logging service")
    }

    func testLogsPageOwnershipDidNotRemainAtEitherCompositionRoot() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/LogsHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let definition = try GateSource.guestC(
            "now-guest-ppc/src/logs/logs_module_definition.c")

        XCTAssertTrue(state.contains("let logs: LogsModel"),
                      "logging remains an eager application service")
        XCTAssertFalse(compatibility.contains("case \"logs\""))
        XCTAssertTrue(runtime.contains("context.logs"))
        XCTAssertFalse(registry.contains("k_logs_definition"))
        XCTAssertTrue(registry.contains("logs_module_definition()"))
        XCTAssertTrue(definition.contains("\"logs\""))
        XCTAssertTrue(definition.contains("logs_module_ops"))
    }

    func testSettingsDefinitionOwnsItsRuntimeAndMetadata() {
        let definition = SettingsHostModule.definition

        XCTAssertEqual(definition.descriptor.id, "settings")
        XCTAssertEqual(definition.descriptor.placement, .footer)
        XCTAssertEqual(definition.descriptor.tier, .core)
        XCTAssertTrue(definition.descriptor.showsLinkStatus)
        XCTAssertNotNil(definition.makeRuntime)
        XCTAssertNotNil(definition.makeView)
    }

    func testSettingsOwnershipKeepsServicesAtTheAppBoundary() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/HostAppState.swift")
        let compatibility = try GateSource.hostSwift(
            "now-host/Sources/Host/HostModuleDefinition.swift")
        let runtime = try GateSource.hostSwift(
            "now-host/Sources/Host/SettingsHostModule.swift")
        let registry = try GateSource.guestC(
            "now-guest-ppc/src/workshop/workshop_registry.c")
        let preferences = try GateSource.guestC(
            "now-guest-ppc/src/preferences/preferences_module_definition.c")
        let connection = try GateSource.guestC(
            "now-guest-ppc/src/connection/connection_module_definition.c")

        XCTAssertTrue(state.contains("let settings: SettingsModel"))
        XCTAssertTrue(state.contains("let onboarding: OnboardingPortal"))
        XCTAssertFalse(state.contains("lazy var connections"))
        XCTAssertFalse(compatibility.contains("case \"settings\""))
        XCTAssertTrue(runtime.contains("model = ConnectionsModel("))
        XCTAssertTrue(runtime.contains("select: context.selectGuest"))
        XCTAssertFalse(registry.contains("k_preferences_definition"))
        XCTAssertFalse(registry.contains("k_connection_definition"))
        XCTAssertTrue(registry.contains("preferences_module_definition()"))
        XCTAssertTrue(registry.contains("connection_module_definition()"))
        XCTAssertTrue(preferences.contains("\"settings\""))
        XCTAssertTrue(preferences.contains("preferences_module_ops"))
        XCTAssertTrue(connection.contains("\"settings\""))
        XCTAssertTrue(connection.contains("connection_module_ops"))
    }
}
