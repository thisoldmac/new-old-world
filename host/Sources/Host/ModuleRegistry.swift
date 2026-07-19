import Foundation

struct ModuleDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
}

struct ModuleRegistry: Sendable {
    let modules: [ModuleDescriptor]

    init(modules: [ModuleDescriptor]) {
        precondition(Set(modules.map(\.id)).count == modules.count,
                     "Module identifiers must be unique")
        self.modules = modules
    }

    func module(id: String) -> ModuleDescriptor? {
        modules.first { $0.id == id }
    }

    static let standard = ModuleRegistry(modules: [
        ModuleDescriptor(
            id: "screenshots",
            title: "Screenshots",
            symbol: "camera.viewfinder",
            summary: "Capture, browse, and save images from a classic Mac"
        ),
    ])
}

