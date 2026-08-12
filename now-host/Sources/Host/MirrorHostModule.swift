import MirrorKit
import NOWAgentIntegration
import SwiftUI

private enum MirrorHostModuleError: Error, CustomStringConvertible {
    case missingServices

    var description: String {
        "Mirror's host services are unavailable."
    }
}

@MainActor
final class MirrorHostModuleRuntime: HostModuleRuntime {
    let model: MirrorControlModel
    let presentation: MirrorPresentation
    private let context: HostModuleContext
    private let engines: MirrorStateEngineRegistry
    private(set) var madeSource = false

    private(set) lazy var source: NOWMirrorSource = {
        madeSource = true
        let source = NOWMirrorSource(
            listener: context.listener,
            engineRegistry: engines,
            act: AgentIntegrationActControl(
                listener: context.listener,
                currentSessionID: { [unowned self] in
                    self.context.agentIntegration?.connectedSessionID()
                }),
            localNetworkAccess: context.localNetworkAccess,
            planePolicy: { [unowned self] key in
                self.model.requestedPlaneIDs(for: key)
            },
            finderComplementPolicy: { [unowned self] key in
                self.model.finderComplementsAllowed(for: key)
            },
            lifecycleDidChange: { [weak self] in
                self?.model.refreshLifecycle()
            })
        model.bindPolicyProjection { [weak source] in
            source?.planePolicyDidChange()
        }
        return source
    }()
    private(set) lazy var run = MirrorRunControl(
        source: source, defaults: context.defaults)
    private(set) lazy var window = NOWMirrorWindow(
        source: source, presentation: presentation)

    init(context: HostModuleContext) throws {
        guard let engines = context.mirrorEngines,
              context.agentIntegration != nil else {
            throw MirrorHostModuleError.missingServices
        }
        self.context = context
        self.engines = engines
        model = MirrorControlModel(
            guestProbe: MirrorGuestWireProbe(listener: context.listener))
        presentation = MirrorPresentation(defaults: context.defaults)
    }

    func activeGuestWillChange() {
        guard madeSource else { return }
        run.activeGuestWillChange()
    }

    func focus(on connection: GuestConnectionState) {
        guard madeSource else { return }
        run.activeGuestDidChange()
    }

    var guestScreenIfKnown: MirrorKit.Scene.ScreenSize? {
        guard madeSource else { return nil }
        return source.scene?.screen.known
    }

    var connectedMachineName: String {
        context.connectedMachineName()
    }

    var metrics: AgentIntegrationMirrorMetrics? {
        guard madeSource else { return nil }
        return source.actTimeline.projected(
            cycles: source.cycleTimeline,
            running: source.running,
            scheduler: context.listener.workScheduler.snapshot(),
            work: context.listener.workTimeline.entries)
    }

    var lifecycle: AgentIntegrationMirrorLifecycle? {
        guard let facts = model.wireFacts else { return nil }
        return .init(
            lifecycle: facts.resident.lifecycle.rawValue,
            residentBuild: facts.resident.buildFingerprint,
            residentMajor: facts.resident.residentMajor,
            residentMinor: facts.resident.residentMinor,
            capabilities: facts.resident.capabilities,
            requested: facts.resident.requested,
            active: facts.resident.active,
            reason: facts.resident.reason,
            planes: facts.planes.map { plane in
                .init(id: plane.id.rawValue, title: plane.id.title,
                      purpose: plane.purpose, format: plane.format,
                      generation: plane.generation,
                      requestedByHost: model.policyEnabled(plane.id))
            })
    }

    func drive(_ request: AgentIntegrationMirrorDriveRequest)
        -> AgentIntegrationMirrorDriveResult {
        let source = source
        return MirrorDriveService(
            scene: { source.shadowEngine?.snapshot?.scene },
            perform: { source.perform($0, source: .mcp) },
            journal: { source.shadowEngine?.operations },
            cancel: { source.cancelPendingActs() })
            .drive(request)
    }

    @discardableResult
    func show() -> HostSurfaceOutcome {
        let name = context.connectedMachineName()
        let detached = presentation.isDetached
        let wasShowing = detached
            ? window.isOpen
            : context.selectedModuleID() == "mirror"
        let wasRunning = source.running
        guard wasRunning || context.currentConnection().canCapture else {
            return .refused(
                code: "unavailable",
                reason: "No Mac is connected, so there is nothing to "
                    + "mirror yet.")
        }
        run.start()
        if detached {
            window.show(title: "Mirror — \(name)")
        } else {
            context.selectModule("mirror")
        }
        let place = detached ? "in its own window" : "on the Mirror page"
        return .showing(
            wasAlreadyOpen: wasShowing && wasRunning,
            detail: wasShowing && wasRunning
                ? "The Mirror was already running; brought it to the front "
                    + place + "."
                : "The Mirror is running on \(name), \(place).")
    }

    func shutDown() {
        guard madeSource else { return }
        run.stop()
        window.close()
    }
}

@MainActor
enum MirrorHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "mirror",
            title: "Mirror",
            symbol: "macwindow.on.rectangle",
            summary: "See and drive \(MachineNaming.simpleReference), "
                + "here or in its own window",
            tier: .experimental),
        makeRuntime: { try MirrorHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? MirrorHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Mirror runtime has the wrong type."))
            }
            return AnyView(MirrorModuleView(
                model: runtime.model, source: runtime.source,
                run: runtime.run, presentation: runtime.presentation,
                window: runtime.window,
                connectedMachineName: runtime.connectedMachineName,
                timeline: runtime.source.actTimeline,
                cycles: runtime.source.cycleTimeline))
        })
}
