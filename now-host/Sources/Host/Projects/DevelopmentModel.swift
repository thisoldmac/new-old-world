import Foundation
import NOWAgentIntegration

@MainActor
final class DevelopmentModel: ObservableObject {
    @Published private(set) var projects: [ProjectStatus] = []
    @Published var selectedProjectID: ProjectID?
    @Published private(set) var workspace: ProjectWorkspace?
    @Published private(set) var problem: String?
    @Published private(set) var latestRevision: ProjectRevisionReceipt?
    @Published private(set) var environmentRows: [AgentIntegrationGuestRow] = []
    @Published private(set) var buildRows: [AgentIntegrationGuestRow] = []
    @Published private(set) var developmentBusy = false
    /// Whether the last environment read found a qualified guest MPW —
    /// what the create sheet's MPW option enables on.
    @Published private(set) var guestToolchainQualified = false

    let projectsRootDescription = "New Old World's Application Support Projects directory"
    private let store: ProjectStore?
    private let readEnvironment: () async -> AgentIntegrationGuestRowReportResult
    private let performDevelopment:
        (AgentIntegrationDevelopmentRequest) async
            -> AgentIntegrationGuestRowReportResult

    init(
        store: ProjectStore?,
        readEnvironment: @escaping () async
            -> AgentIntegrationGuestRowReportResult = { .unavailable(.guest) },
        performDevelopment: @escaping (AgentIntegrationDevelopmentRequest) async
            -> AgentIntegrationGuestRowReportResult = { _ in .unavailable(.guest) }
    ) {
        self.store = store
        self.readEnvironment = readEnvironment
        self.performDevelopment = performDevelopment
        refresh()
    }

    var selectedProject: ProjectStatus? {
        projects.first { $0.projectID == selectedProjectID }
    }

    var isAvailable: Bool { store != nil }
    var productReference: String? {
        buildRows.first { $0.label == "Product" && $0.value != "unavailable" }?.value
    }
    var candidateReference: String? {
        buildRows.first {
            $0.label == "Candidate" && $0.value.hasPrefix("candidate-")
        }?.value
    }
    var canBuildActiveGuestProject: Bool {
        selectedProject?.home == .guest && !developmentBusy
    }
    var canRun: Bool { productReference != nil && !developmentBusy }
    var canStage: Bool {
        guard let project = selectedProject else { return false }
        return !developmentBusy && (project.home == .host || workspace != nil)
    }
    var canPromote: Bool { candidateReference != nil && !developmentBusy }

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

    func createHostProject(name: String, toolchain: String? = nil) {
        guard let store, !developmentBusy else { return }
        developmentBusy = true
        problem = nil
        /* The pin is resolved rather than emitted as `unselected@0`:
           the guest refuses `toolchain-pin-mismatch` against anything
           but its own measured identity, so a template pin nothing can
           build is a project broken by construction. The sheet passes
           the person's explicit choice; absent one, the defaulting
           rule (guest's qualified MPW when it reports one, the
           host-retro68 sentinel otherwise) lives in ProjectGround. */
        Task { @MainActor in
            defer { developmentBusy = false }
            let pin: String
            switch await ProjectGround.resolvePin(
                toolchain: toolchain,
                environment: { await self.readEnvironment() }) {
            case .failure(let refusal):
                problem = refusal.message
                return
            case .success(let resolved):
                pin = resolved
            }
            let identity = String(repeating: "0", count: 32)
            let document = Data("""
                CKPROJECT 1
                id=\(identity)
                name=\(name)
                target=application
                configuration=debug
                toolchain=\(pin)
                product=Build/\(name)
                type=APPL
                creator=????
                architecture=powerpc
                file=Sources/Main.c
                file-info=TEXT|MPS |0000|Sources/Main.c
                build-action=compile|Sources/Main.c|Build/Main.c.o
                build-action=link|Build/Main.c.o|Build/\(name)
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
    }

    func importGuestProject(projectID: String) {
        perform(.init(operation: .importGuest, projectID: projectID,
                      attemptID: attemptID()))
    }

    func stage() {
        guard let project = selectedProject else { return }
        perform(.init(operation: .stage,
                      projectID: project.projectID.rawValue,
                      workspaceID: workspace?.workspaceID.rawValue,
                      attemptID: attemptID()))
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

    func refreshDevelopment() {
        guard !developmentBusy else { return }
        developmentBusy = true
        problem = nil
        Task { @MainActor in
            let environment = await readEnvironment()
            environmentRows = rows(from: environment, problemPrefix: "Environment")
            guestToolchainQualified =
                ProjectGround.qualifiedToolchain(in: environment) != nil
            let status = await performDevelopment(.init(operation: .buildStatus))
            buildRows = rows(from: status, problemPrefix: "Build status")
            developmentBusy = false
        }
    }

    func build() {
        if let candidateReference {
            perform(.init(operation: .buildStart,
                          candidateID: candidateReference,
                          attemptID: attemptID()))
            return
        }
        guard let project = selectedProject, project.home == .guest else {
            problem = "Only an active guest-home project can build directly; host work must be staged as a candidate first."
            return
        }
        perform(.init(operation: .buildStart,
                      projectID: project.projectID.rawValue,
                      attemptID: attemptID()))
    }

    func promote() {
        guard let candidateReference else { return }
        perform(.init(operation: .promote,
                      candidateID: candidateReference,
                      attemptID: attemptID()))
    }

    func cancelBuild() {
        perform(.init(operation: .buildCancel, attemptID: attemptID()))
    }

    func run() {
        guard let productReference else {
            problem = "A successful build has not minted an exact product reference."
            return
        }
        perform(.init(operation: .run, productRef: productReference,
                      attemptID: attemptID()))
    }

    func openInCodeKitten() {
        guard let project = selectedProject, project.home == .guest else {
            problem = "Open in CodeKitten targets an active guest-home Project.ckp."
            return
        }
        perform(.init(operation: .openInCodeKitten,
                      projectID: project.projectID.rawValue,
                      attemptID: attemptID()))
    }

    private func perform(_ request: AgentIntegrationDevelopmentRequest) {
        guard !developmentBusy else { return }
        developmentBusy = true
        problem = nil
        Task { @MainActor in
            let result = await performDevelopment(request)
            buildRows = rows(from: result, problemPrefix: "Projects")
            refresh()
            developmentBusy = false
        }
    }

    private func attemptID() -> String {
        UUID().uuidString.lowercased()
    }

    private func rows(
        from result: AgentIntegrationGuestRowReportResult,
        problemPrefix: String
    ) -> [AgentIntegrationGuestRow] {
        switch result {
        case .completed(let report):
            return report.groups.flatMap(\.rows)
        case .refused(let failure):
            problem = "\(problemPrefix): \(failure.message)"
        case .unavailable(let unavailable):
            problem = "\(problemPrefix): \(unavailable.message)"
        }
        return []
    }
}
