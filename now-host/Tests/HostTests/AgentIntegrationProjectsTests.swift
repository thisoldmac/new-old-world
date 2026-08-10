import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class AgentIntegrationProjectsTests: XCTestCase {
    private func store() throws -> ProjectStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-agent-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ProjectStore(root: root)
    }

    private func write(_ path: String, _ contents: String)
        -> AgentIntegrationProjectChange {
        .init(path: path, action: .write,
              contentsBase64: Data(contents.utf8).base64EncodedString(),
              finderType: "TEXT", finderCreator: "MPS ", finderFlags: 0)
    }

    func testRequestShapesRefusePathsInjectionAndDestructiveCreate() {
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad\nfile=Injected.c",
            changes: [write("Main.c", "")]).isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "../outside", action: .write,
                            contentsBase64: Data().base64EncodedString())])
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Sources/.private/Main.c", action: .write,
                            contentsBase64: Data().base64EncodedString())])
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Project.ckp", action: .write,
                            contentsBase64: Data().base64EncodedString())])
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Main.c", action: .delete)])
            .isWellFormed)
    }

    func testHostAdapterCreatesReadsAndAtomicallyRevisesAProject() throws {
        let projectStore = try store()
        let adapter = AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "project-test", name: "Project Test Host")),
            projectStore: projectStore)

        let created = adapter.projects(.init(
            operation: .create, name: "Memory Meter",
            changes: [
                write("Sources/Main.c", "int value = 1;"),
                .init(path: "Sources/Main.c", action: .write,
                      fork: .resource,
                      contentsBase64: Data("resource".utf8).base64EncodedString()),
            ]))
        let project = try XCTUnwrap(created.project)
        XCTAssertEqual(project.home, "host")
        XCTAssertEqual(created.revision?.message, "Create project")
        XCTAssertNil(created.failure)

        let read = adapter.projects(.init(
            operation: .read, projectID: project.projectID,
            path: "Sources/Main.c", maximumBytes: 1024))
        XCTAssertEqual(read.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("int value = 1;".utf8))
        XCTAssertEqual(read.fork, "data")
        XCTAssertEqual(read.finderType, "TEXT")
        XCTAssertEqual(read.finderCreator, "MPS ")
        XCTAssertEqual(read.finderFlags, 0)

        let resource = adapter.projects(.init(
            operation: .read, projectID: project.projectID,
            path: "Sources/Main.c", fork: .resource, maximumBytes: 1024))
        XCTAssertEqual(resource.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("resource".utf8))
        XCTAssertEqual(resource.fork, "resource")

        let changed = adapter.projects(.init(
            operation: .apply, projectID: project.projectID,
            expectedRevision: project.revision,
            message: "Raise the sample", changes: [
                write("Sources/Main.c", "int value = 2;"),
            ]))
        XCTAssertEqual(changed.project?.revision, 2)
        XCTAssertEqual(changed.revision?.parent, project.commit)
        XCTAssertEqual(changed.revision?.message, "Raise the sample")

        let stale = adapter.projects(.init(
            operation: .apply, projectID: project.projectID,
            expectedRevision: project.revision,
            message: "Stale write", changes: [write("Other", "no")]))
        XCTAssertEqual(stale.failure?.code,
                       "now-projects-revision-conflict")
        XCTAssertEqual(adapter.projects(.init(
            operation: .status, projectID: project.projectID))
            .project?.revision, 2)
    }

    func testProjectRequestAndResultSurviveTheLocalCodec() throws {
        let request = AgentIntegrationLocalRequest.projects(.init(
            operation: .create, name: "Codec",
            changes: [write("Main.c", "int main(void) { return 0; }")]))
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request)), request)

        let result = AgentIntegrationProjectResult(
            projects: [], failure: nil)
        let response = AgentIntegrationLocalResponse(
            requestID: request.requestID, projectResult: result)
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeResponse(
            AgentIntegrationLocalCodec.encode(response)), response)
    }

    func testReadOfLegacyProjectReturnsBytesWithoutInventingIdentity() throws {
        let projectStore = try store()
        let document = Data("""
            CKPROJECT 1
            id=0123456789abcdef0123456789abcdef
            name=Legacy
            target=application
            configuration=debug
            toolchain=mpw@3.6
            product=Build/Legacy
            type=APPL
            creator=TEST
            file=Sources/Main.c
            """.utf8)
        let created = try projectStore.create(
            name: "Legacy", home: .host, projectDocument: document,
            files: [.init(path: "Sources/Main.c",
                          contents: Data("legacy".utf8))])
        let adapter = AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "project-test", name: "Project Test Host")),
            projectStore: projectStore)

        let result = adapter.projects(.init(
            operation: .read, projectID: created.projectID.rawValue,
            path: "Sources/Main.c", maximumBytes: 1024))

        XCTAssertEqual(result.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("legacy".utf8))
        XCTAssertNil(result.finderType)
        XCTAssertNil(result.finderCreator)
        XCTAssertNil(result.finderFlags)
        XCTAssertNil(result.failure)
    }

    func testProjectProjectionDeclaresHostAuthorityAndDelegatesTypedRequest()
        async {
        XCTAssertEqual(ProjectsProjection.authorityDomain, .hostProjects)
        XCTAssertFalse(ProjectsProjection.acceptsGuestAddressing)
        XCTAssertNotNil(HostProjectionRegistry.hostFaces[
            ProjectsProjection.capability])

        let client = ProjectProjectionClient()
        let outcome = await HostProjectionDispatch(
            face: .chat, audit: ProjectAuditSink()).invoke(
                ProjectsProjection.capability.rawValue,
                arguments: .init(raw: ["operation": "list"]),
                guest: "a-pinned-conversation-machine",
                through: client)
        guard case .value(let value) = outcome,
              let object = try? JSONSerialization.jsonObject(
                with: value.encoded(using: JSONEncoder())) as? [String: Any]
        else { return XCTFail("Host-owned project listing was not returned") }
        XCTAssertNotNil(object["projects"])
        let healthCalls = await client.healthCalls()
        XCTAssertEqual(healthCalls, 0,
                       "Guest consent was consulted for host project storage")
    }
}

private actor ProjectProjectionClient: AgentIntegrationClient {
    private var healthCount = 0

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        healthCount += 1
        return .unavailable(.host)
    }

    func projects(_ request: AgentIntegrationProjectRequest) async
        -> AgentIntegrationProjectResult {
        .init(projects: [])
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult { .unavailable(.host) }
    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult { .unavailable(.host) }
    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult { .unavailable(.host) }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult { .hostUnavailable(.host) }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }

    func healthCalls() -> Int { healthCount }
}

private actor ProjectAuditSink: HostProjectionAuditSink {
    func record(_ event: HostProjectionAuditEvent) async {}
}
