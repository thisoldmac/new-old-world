import SwiftUI

enum ModuleTier: String, CaseIterable, Sendable {
    case core
    case experimental
    case debug
}

@MainActor
struct HostModuleContext {
    let listener: GuestListener
    let currentConnection: () -> GuestConnectionState
}

@MainActor
protocol HostModuleRuntime: AnyObject {
    func focus(on connection: GuestConnectionState)
    func guestLeft(_ key: GuestKey)
    func shutDown()
}

extension HostModuleRuntime {
    func focus(on connection: GuestConnectionState) {}
    func guestLeft(_ key: GuestKey) {}
    func shutDown() {}
}

@MainActor
struct HostModuleDefinition {
    typealias RuntimeFactory = (HostModuleContext) throws -> any HostModuleRuntime
    typealias ViewFactory = (HostAppState, (any HostModuleRuntime)?) -> AnyView

    let descriptor: ModuleDescriptor
    let makeRuntime: RuntimeFactory?
    let makeView: ViewFactory?

    init(descriptor: ModuleDescriptor,
         makeRuntime: RuntimeFactory? = nil,
         makeView: ViewFactory? = nil) {
        self.descriptor = descriptor
        self.makeRuntime = makeRuntime
        self.makeView = makeView
    }
}

enum HostModuleResolution: Equatable {
    case available
    case disabled(String)
    case constructionFailed(String)
    case unavailable
}

private enum HostModuleRuntimeStoreError: Error, CustomStringConvertible {
    case shutDown

    var description: String {
        "The module runtime store has already shut down."
    }
}

/// Owns the runtime instances behind statically linked definitions. A module
/// enters this dictionary only after construction succeeds, so a throwing
/// factory rolls back to exactly the state before selection and may be retried.
@MainActor
final class HostModuleRuntimeStore {
    private let registry: ModuleRegistry
    private let context: HostModuleContext
    private let featurePolicy: ProductFeaturePolicy
    private var runtimes: [String: any HostModuleRuntime] = [:]
    private(set) var isShutDown = false

    init(registry: ModuleRegistry,
         context: HostModuleContext,
         featurePolicy: ProductFeaturePolicy = ProductFeaturePolicy()) {
        self.registry = registry
        self.context = context
        self.featurePolicy = featurePolicy
    }

    func resolution(for id: String) -> HostModuleResolution {
        guard let definition = registry.definition(id: id),
              definition.makeView != nil else { return .unavailable }
        if let feature = definition.descriptor.featureID,
           case .disabled(let reason) = featurePolicy.resolve(feature) {
            return .disabled(reason.explanation)
        }
        guard definition.makeRuntime != nil else { return .available }
        do {
            _ = try runtime(for: definition)
            return .available
        } catch {
            return .constructionFailed(String(describing: error))
        }
    }

    func view(for id: String, state: HostAppState) -> AnyView {
        guard let definition = registry.definition(id: id),
              let makeView = definition.makeView else {
            return AnyView(ModuleUnavailableView(reason: nil))
        }
        if let feature = definition.descriptor.featureID,
           case .disabled(let reason) = featurePolicy.resolve(feature) {
            return AnyView(ModuleUnavailableView(reason: reason.explanation))
        }
        do {
            let runtime = try runtime(for: definition)
            return makeView(state, runtime)
        } catch {
            return AnyView(ModuleUnavailableView(
                reason: "Construction failed and was rolled back: \(error)"))
        }
    }

    func focus(on connection: GuestConnectionState) {
        for runtime in runtimes.values { runtime.focus(on: connection) }
    }

    func guestLeft(_ key: GuestKey) {
        for runtime in runtimes.values { runtime.guestLeft(key) }
    }

    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        for runtime in runtimes.values { runtime.shutDown() }
        runtimes.removeAll()
    }

    func isConstructed(_ id: String) -> Bool { runtimes[id] != nil }

    func runtime<Runtime: HostModuleRuntime>(for id: String,
                                             as type: Runtime.Type) -> Runtime? {
        guard let definition = registry.definition(id: id) else { return nil }
        return try? runtime(for: definition) as? Runtime
    }

    private func runtime(for definition: HostModuleDefinition) throws
        -> (any HostModuleRuntime)? {
        guard !isShutDown else { throw HostModuleRuntimeStoreError.shutDown }
        guard let factory = definition.makeRuntime else { return nil }
        if let existing = runtimes[definition.descriptor.id] { return existing }
        let made = try factory(context)
        made.focus(on: context.currentConnection())
        runtimes[definition.descriptor.id] = made
        return made
    }
}

struct ModuleUnavailableView: View {
    let reason: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.app")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Module Unavailable")
                .font(.title2.weight(.semibold))
            if let reason {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .nowGlassPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compatibility definitions for modules not migrated yet. Moving one module
/// means moving exactly one case into that module's own file; HostRootView and
/// HostAppState do not grow another branch while the migration is in flight.
@MainActor
enum LegacyHostModuleDefinitions {
    static func definition(for descriptor: ModuleDescriptor)
        -> HostModuleDefinition {
        if descriptor.id == NetworkingHostModule.definition.descriptor.id {
            return NetworkingHostModule.definition
        }
        if descriptor.id == ConsoleHostModule.definition.descriptor.id {
            return ConsoleHostModule.definition
        }
        if descriptor.id == CensusHostModule.definition.descriptor.id {
            return CensusHostModule.definition
        }
        if descriptor.id == SoftwareHostModule.definition.descriptor.id {
            return SoftwareHostModule.definition
        }
        if descriptor.id == ScreenHostModule.definition.descriptor.id {
            return ScreenHostModule.definition
        }
        return HostModuleDefinition(descriptor: descriptor, makeView: { state, _ in
            switch descriptor.id {
            case "files":
                return AnyView(FilesModuleView(model: state.files))
            case "icloud":
                return AnyView(CloudModuleView(model: state.cloudModule))
            case "processes":
                return AnyView(ProcessesModuleView(model: state.processes))
            case "mirror":
                return AnyView(MirrorModuleView(
                    model: state.mirror, source: state.mirrorSource,
                    run: state.mirrorRun,
                    presentation: state.mirrorPresentation,
                    window: state.mirrorWindow,
                    connectedMachineName: state.connectedMachineName,
                    timeline: state.mirrorSource.actTimeline,
                    cycles: state.mirrorSource.cycleTimeline))
            case "chat":
                return AnyView(ChatModuleView(model: state.chat))
            case "web":
                return AnyView(WebModuleView(model: state.web))
            case "development":
                return AnyView(DevelopmentModuleView(model: state.development))
            case "diagnostics":
                return AnyView(DiagnosticsModuleView(model: state.diagnostics))
            case "mcp":
                return AnyView(MCPModuleView(
                    model: state.agentActivity,
                    companions: state.agentCompanions,
                    listener: state.listener,
                    startStdio: state.startMCPStdio,
                    stopStdio: state.stopMCPStdio,
                    startHTTP: state.startMCPHTTP,
                    stopHTTP: state.stopMCPHTTP))
            case "logs":
                return AnyView(LogsModuleView(model: state.logs,
                                              log: state.logs.log))
            case "settings":
                return AnyView(ConnectionsModuleView(
                    model: state.connections, settings: state.settings,
                    listener: state.listener, onboarding: state.onboarding,
                    onStart: { state.startListening() },
                    onStop: { state.stopListening() }))
            default:
                return AnyView(ModuleUnavailableView(reason: nil))
            }
        })
    }
}
