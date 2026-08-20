import SwiftUI

@MainActor
final class FilesHostModuleRuntime: HostModuleRuntime {
    let model: FilesModuleModel

    init(context: HostModuleContext) {
        model = FilesModuleModel(
            listener: context.listener,
            defaults: context.defaults,
            artifactApprover: context.artifactApprover)
    }

    func focus(on connection: GuestConnectionState) {
        model.connection = connection
    }

    func guestLeft(_ key: GuestKey) {
        model.guestLeft(key)
    }
}

@MainActor
enum FilesHostModule {
    static let definition = HostModuleDefinition(
        descriptor: ModuleDescriptor(
            id: "files",
            title: "Files",
            symbol: "folder",
            summary: "\(MachineNaming.possessive(nil)) file share, "
                + "both directions"),
        makeRuntime: { FilesHostModuleRuntime(context: $0) },
        makeView: { _, runtime in
            guard let runtime = runtime as? FilesHostModuleRuntime else {
                return AnyView(ModuleUnavailableView(
                    reason: "The Files runtime has the wrong type."))
            }
            return AnyView(FilesModuleView(model: runtime.model))
        })
}
