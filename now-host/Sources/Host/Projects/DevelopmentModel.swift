import Foundation

@MainActor
final class DevelopmentModel: ObservableObject {
    @Published private(set) var projects: [ProjectStatus] = []
    @Published var selectedProjectID: ProjectID?
    @Published private(set) var workspace: ProjectWorkspace?
    @Published private(set) var problem: String?
    @Published private(set) var latestRevision: ProjectRevisionReceipt?

    let projectsRootDescription = "New Old World's Application Support Projects directory"
    private let store: ProjectStore?

    init(store: ProjectStore?) {
        self.store = store
        refresh()
    }

    var selectedProject: ProjectStatus? {
        projects.first { $0.projectID == selectedProjectID }
    }

    var isAvailable: Bool { store != nil }

    func refresh() {
        guard let store else {
            projects = []
            problem = "The application-owned Projects directory is unavailable."
            return
        }
        do {
            projects = try store.list()
            if selectedProjectID == nil { selectedProjectID = projects.first?.projectID }
            if let id = selectedProject?.activeWorkspaceID {
                workspace = try? store.resumeWorkspace(workspaceID: id)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func createHostProject(name: String) {
        guard let store else { return }
        let identity = String(repeating: "0", count: 32)
        let document = Data("""
            CKPROJECT 1
            id=\(identity)
            name=\(name)
            target=application
            configuration=debug
            toolchain=unselected@0
            product=Build/\(name)
            type=APPL
            creator=????
            architecture=powerpc
            file=Sources/Main.c
            """.utf8)
        do {
            let receipt = try store.create(
                name: name, home: .host, projectDocument: document,
                files: [ProjectFileChange(
                    path: "Sources/Main.c",
                    contents: Data("/* \(name) */\nint main(void) { return 0; }\n".utf8))])
            latestRevision = receipt
            selectedProjectID = receipt.projectID
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    func openWorkspace() {
        guard let store, let projectID = selectedProjectID else { return }
        do {
            workspace = try store.openWorkspace(projectID: projectID)
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    func discardWorkspace() {
        guard let store, let id = workspace?.workspaceID else { return }
        do {
            try store.discardWorkspace(workspaceID: id)
            workspace = nil
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }
}
