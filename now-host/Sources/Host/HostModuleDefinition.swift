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
    let defaults: UserDefaults
    let artifactApprover: AgentIntegrationHostAdapter?
    let agentIntegration: AgentIntegrationHostAdapter?
    let guestFiles: GuestFilesCommandService?
    let agentActivity: AgentActivityModel?
    let agentCompanions: AgentCompanionModel?
    let mcpOAuthConsent: MCPOAuthConsentModel?
    let mcpRecords: MCPRecordsRecorder?
    let logs: LogsModel?
    let continuity: MirrorContinuityController?
    /// One host-side file lane, app-owned because the Continuity edge seam
    /// uses it with no Mirror page in the picture.
    let fileTransfer: MirrorFileTransferModel
    let settings: SettingsModel?
    let onboarding: OnboardingPortal?
    let localNetworkAccess: LocalNetworkAccessController
    let guestScreen: @Sendable () async -> ChatSystemPrompt.Screen?
    let mirrorEngines: MirrorStateEngineRegistry?
    let selectedModuleID: () -> String
    let selectModule: (String) -> Void
    /// The deep-link seam beside `selectModule`: a module builds
    /// `{ context.showSettings(.someTab) }` once at construction and hands
    /// it to its view as a "Settings…" button, the same shape `selectModule`
    /// already is. Settings itself is not a shelf module — it is a separate
    /// `NSWindow` — so this cannot simply BE `selectModule` with a tab id.
    let showSettings: (HostSettingsTab?) -> Void
    let selectGuest: (GuestKey) -> Bool
    let startListening: () -> Void
    let stopListening: () -> Void
    let connectedMachineName: () -> String

    init(listener: GuestListener,
         currentConnection: @escaping () -> GuestConnectionState,
         defaults: UserDefaults = ProductIdentity.defaults,
         artifactApprover: AgentIntegrationHostAdapter? = nil,
         agentIntegration: AgentIntegrationHostAdapter? = nil,
         guestFiles: GuestFilesCommandService? = nil,
         agentActivity: AgentActivityModel? = nil,
         agentCompanions: AgentCompanionModel? = nil,
         mcpOAuthConsent: MCPOAuthConsentModel? = nil,
         mcpRecords: MCPRecordsRecorder? = nil,
         logs: LogsModel? = nil,
         continuity: MirrorContinuityController? = nil,
         fileTransfer: MirrorFileTransferModel? = nil,
         settings: SettingsModel? = nil,
         onboarding: OnboardingPortal? = nil,
         localNetworkAccess: LocalNetworkAccessController? = nil,
         guestScreen: @escaping @Sendable () async
            -> ChatSystemPrompt.Screen? = { nil },
         mirrorEngines: MirrorStateEngineRegistry? = nil,
         selectedModuleID: @escaping () -> String = { "" },
         selectModule: @escaping (String) -> Void = { _ in },
         showSettings: @escaping (HostSettingsTab?) -> Void = { _ in },
         selectGuest: @escaping (GuestKey) -> Bool = { _ in false },
         startListening: @escaping () -> Void = {},
         stopListening: @escaping () -> Void = {},
         connectedMachineName: @escaping () -> String = {
            "no Mac connected"
         }) {
        self.listener = listener
        self.currentConnection = currentConnection
        self.defaults = defaults
        self.artifactApprover = artifactApprover
        self.agentIntegration = agentIntegration
        self.guestFiles = guestFiles
        self.agentActivity = agentActivity
        self.agentCompanions = agentCompanions
        self.mcpOAuthConsent = mcpOAuthConsent
        self.mcpRecords = mcpRecords
        self.logs = logs
        self.continuity = continuity
        self.fileTransfer = fileTransfer
            ?? MirrorFileTransferModel(listener: listener)
        self.settings = settings
        self.onboarding = onboarding
        self.localNetworkAccess = localNetworkAccess
            ?? LocalNetworkAccessController()
        self.guestScreen = guestScreen
        self.mirrorEngines = mirrorEngines
        self.selectedModuleID = selectedModuleID
        self.selectModule = selectModule
        self.showSettings = showSettings
        self.selectGuest = selectGuest
        self.startListening = startListening
        self.stopListening = stopListening
        self.connectedMachineName = connectedMachineName
    }
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

    func existingRuntime<Runtime: HostModuleRuntime>(
        for id: String, as type: Runtime.Type
    ) -> Runtime? {
        runtimes[id] as? Runtime
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
