import SwiftUI

@MainActor
final class ScreenHostModuleRuntime: HostModuleRuntime {
    let model: ScreenshotModuleModel
    let quickCapture: QuickCaptureCommand
    private let notifier = CaptureNotifier()
    var quickCaptureFeedback: ((QuickCaptureOutcome) -> Void)?

    init(context: HostModuleContext) {
        model = ScreenshotModuleModel(listener: context.listener)
        quickCapture = QuickCaptureCommand(
            screenshots: model, listener: context.listener)
        model.announce = { [notifier] guest, format, fileURL in
            notifier.announce(guest: guest, format: format, fileURL: fileURL)
        }
        quickCapture.report = { [weak self] outcome in
            guard let self else { return }
            notifier.announce(outcome: outcome)
            quickCaptureFeedback?(outcome)
        }
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum ScreenHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "screen",
            title: "Screen",
            symbol: "camera.viewfinder",
            summary: "Capture, stream and save "
                + "\(MachineNaming.possessive(nil)) screen"),
        makeRuntime: { ScreenHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? ScreenHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Screen runtime has the wrong type."))
            }
            return AnyView(ScreenshotsModuleView(model: runtime.model))
        })
}
