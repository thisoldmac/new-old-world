import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

@MainActor
final class AgentIntegrationProjectsTests: XCTestCase {
    private let attempt = "01234567-89ab-cdef-0123-456789abcdef"

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
            changes: [write("Main.c", "")], attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "../outside", action: .write,
                            contentsBase64: Data().base64EncodedString())],
            attemptID: attempt)
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Sources/.private/Main.c", action: .write,
                            contentsBase64: Data().base64EncodedString())],
            attemptID: attempt)
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Project.ckp", action: .write,
                            contentsBase64: Data().base64EncodedString())],
            attemptID: attempt)
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad",
            changes: [.init(path: "Main.c", action: .delete)],
            attemptID: attempt)
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Missing Attempt",
            changes: [write("Main.c", "")]).isWellFormed)
    }

    func testMCPContractDiscriminatesEveryProjectOperationAndApplyGuard() {
        let descriptor = ProjectsProjection.mcpDescriptor
        let schema = descriptor["inputSchema"] as? [String: Any]
        let branches = schema?["oneOf"] as? [[String: Any]] ?? []
        let operations = branches.compactMap { branch -> String? in
            let properties = branch["properties"] as? [String: Any]
            let operation = properties?["operation"] as? [String: Any]
            return operation?["const"] as? String
        }
        XCTAssertEqual(Set(operations), [
            "list", "create", "status", "read", "apply", "history",
            "workspace-open", "workspace-resume", "workspace-discard",
        ])
        XCTAssertEqual(operations.filter { $0 == "apply" }.count, 2)
        let apply = zip(branches, operations).filter { $0.1 == "apply" }
        XCTAssertEqual(apply.count, 2)
        let keySets = apply.map { pair in
            Set((pair.0["properties"] as? [String: Any] ?? [:]).keys)
        }
        XCTAssertTrue(keySets.contains {
            $0.contains("expectedRevision") && !$0.contains("expectedCommit")
        })
        XCTAssertTrue(keySets.contains {
            $0.contains("expectedCommit") && !$0.contains("expectedRevision")
        })
        XCTAssertTrue(branches.allSatisfy {
            ($0["additionalProperties"] as? Bool) == false
        })
    }

    func testHostAdapterCreatesReadsAndAtomicallyRevisesAProject() async throws {
        let projectStore = try store()
        let adapter = AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "project-test", name: "Project Test Host")),
            projectStore: projectStore)

        let created = await adapter.projects(.init(
            operation: .create, name: "Memory Meter",
            changes: [
                write("Sources/Main.c", "int value = 1;"),
                .init(path: "Sources/Main.c", action: .write,
                      fork: .resource,
                      contentsBase64: Data("resource".utf8).base64EncodedString()),
            ], attemptID: attempt))
        let project = try XCTUnwrap(created.project)
        XCTAssertEqual(project.home, "host")
        XCTAssertEqual(created.revision?.message, "Create project")
        XCTAssertNil(created.failure)

        let read = await adapter.projects(.init(
            operation: .read, projectID: project.projectID,
            path: "Sources/Main.c", maximumBytes: 1024))
        XCTAssertEqual(read.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("int value = 1;".utf8))
        XCTAssertEqual(read.fork, "data")
        XCTAssertEqual(read.finderType, "TEXT")
        XCTAssertEqual(read.finderCreator, "MPS ")
        XCTAssertEqual(read.finderFlags, 0)

        let resource = await adapter.projects(.init(
            operation: .read, projectID: project.projectID,
            path: "Sources/Main.c", fork: .resource, maximumBytes: 1024))
        XCTAssertEqual(resource.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("resource".utf8))
        XCTAssertEqual(resource.fork, "resource")

        let changed = await adapter.projects(.init(
            operation: .apply, projectID: project.projectID,
            expectedRevision: project.revision,
            message: "Raise the sample", changes: [
                write("Sources/Main.c", "int value = 2;"),
            ], attemptID: "11234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertEqual(changed.project?.revision, 2)
        XCTAssertEqual(changed.revision?.parent, project.commit)
        XCTAssertEqual(changed.revision?.message, "Raise the sample")

        let stale = await adapter.projects(.init(
            operation: .apply, projectID: project.projectID,
            expectedRevision: project.revision,
            message: "Stale write", changes: [write("Other", "no")],
            attemptID: "21234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertEqual(stale.failure?.code,
                       "now-projects-revision-conflict")
        let status = await adapter.projects(.init(
            operation: .status, projectID: project.projectID))
        XCTAssertEqual(status.project?.revision, 2)
    }

    func testProjectRequestAndResultSurviveTheLocalCodec() throws {
        let request = AgentIntegrationLocalRequest.projects(.init(
            operation: .create, name: "Codec",
            changes: [write("Main.c", "int main(void) { return 0; }")],
            attemptID: attempt), requestID: UUID(uuidString: attempt)!)
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeRequest(
            AgentIntegrationLocalCodec.encode(request)), request)

        let result = AgentIntegrationProjectResult(
            projects: [], failure: nil)
        let response = AgentIntegrationLocalResponse(
            requestID: request.requestID, projectResult: result)
        XCTAssertEqual(try AgentIntegrationLocalCodec.decodeResponse(
            AgentIntegrationLocalCodec.encode(response)), response)
    }

    func testReadOfLegacyProjectReturnsBytesWithoutInventingIdentity()
        async throws {
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

        let result = await adapter.projects(.init(
            operation: .read, projectID: created.projectID.rawValue,
            path: "Sources/Main.c", maximumBytes: 1024))

        XCTAssertEqual(result.contentsBase64.flatMap { Data(base64Encoded: $0) },
                       Data("legacy".utf8))
        XCTAssertNil(result.finderType)
        XCTAssertNil(result.finderCreator)
        XCTAssertNil(result.finderFlags)
        XCTAssertNil(result.failure)
    }

    // MARK: - Ground: home and toolchain (plan 039, slices A/B)

    /// A stubbed guest development-environment read: the rows the real
    /// lane renders, in the guest's own vocabulary.
    private func environment(
        toolchain: String, version: String, qualification: String
    ) -> AgentIntegrationGuestRowReportResult {
        .completed(.init(
            verb: "development",
            groups: [.init(name: "development", rows: [
                .init(label: "Projects", value: "chosen"),
                .init(label: "Toolchain", value: toolchain),
                .init(label: "Version", value: version),
                .init(label: "Qualification", value: qualification),
                .init(label: "ToolServer", value: "found"),
                .init(label: "MrC", value: "found"),
            ])],
            observedAt: Date()))
    }

    private func adapter(
        store: ProjectStore,
        environment: AgentIntegrationGuestRowReportResult? = nil
    ) -> AgentIntegrationHostAdapter {
        AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "project-test", name: "Project Test Host")),
            projectStore: store,
            developmentEnvironmentOverride: environment.map { report in
                { report }
            })
    }

    private func descriptor(
        of projectID: String, through adapter: AgentIntegrationHostAdapter
    ) async throws -> String {
        let read = await adapter.projects(.init(
            operation: .read, projectID: projectID,
            path: "Project.ckp", maximumBytes: 4096))
        let data = try XCTUnwrap(
            read.contentsBase64.flatMap { Data(base64Encoded: $0) })
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testGroundFieldsRideCreateOnlyAndOnlyTheirClosedVocabularies() {
        XCTAssertTrue(AgentIntegrationProjectRequest(
            operation: .create, name: "Grounded", home: "host",
            toolchain: "host-retro68",
            changes: [write("Sources/Main.c", "")],
            attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad", home: "cloud",
            changes: [write("Sources/Main.c", "")],
            attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .create, name: "Bad", toolchain: "mpw",
            changes: [write("Sources/Main.c", "")],
            attemptID: attempt).isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .list, home: "host").isWellFormed)
        XCTAssertFalse(AgentIntegrationProjectRequest(
            operation: .status, projectID: String(repeating: "0", count: 32),
            toolchain: "guest-mpw").isWellFormed)
    }

    /// The store's guest-digest guard is the authority story, so a
    /// guest-home create is a typed refusal that NAMES the import path
    /// — never a silently-host project.
    /// A display name becomes a `name=` line in Project.ckp, so a line
    /// break in one is a directive nobody wrote. The agent surface has
    /// always refused these; the STORE did not, and the chat faces mint
    /// through the store with a name a guest supplied — where CR is the
    /// ordinary line ending.
    func testTheStoreRefusesALineBreakInADisplayName() throws {
        let projectStore = try store()
        let document = Data("""
            CKPROJECT 1
            id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            name=Injected
            target=application
            configuration=debug
            toolchain=host-retro68@1
            product=Build/Injected
            type=APPL
            creator=TEST
            file=Sources/Main.c
            """.utf8)
        for hostile in ["Beeper\rtype=DANGER", "Beeper\ntype=DANGER",
                        "Beeper\u{0}x"] {
            XCTAssertThrowsError(
                try projectStore.create(
                    name: hostile, home: .host, projectDocument: document,
                    files: [.init(path: "Sources/Main.c",
                                  contents: Data("x".utf8))]),
                "a name carrying \(hostile.debugDescription) was accepted")
        }
        // The ordinary name still works, so the guard is not a wall.
        XCTAssertNoThrow(try projectStore.create(
            name: "Beeper", home: .host, projectDocument: document,
            files: [.init(path: "Sources/Main.c",
                          contents: Data("x".utf8))]))
    }

    func testCreateWithGuestHomeIsRefusedNamingTheImportPath() async throws {
        let adapter = adapter(store: try store())
        let refused = await adapter.projects(.init(
            operation: .create, name: "Guest Wish", home: "guest",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        XCTAssertNil(refused.project)
        XCTAssertEqual(refused.failure?.code,
                       "now-projects-guest-home-create-refused")
        XCTAssertTrue(refused.failure?.message.contains("import") == true,
                      refused.failure?.message ?? "no message")
        XCTAssertTrue(refused.failure?.message.contains("promote") == true)
    }

    /// The pin is what the GUEST measured — never a host guess. The
    /// stub reports one identity; the descriptor must carry exactly it.
    func testCreateWithGuestMPWPinsWhatTheGuestMeasured() async throws {
        let adapter = adapter(
            store: try store(),
            environment: environment(toolchain: "mpw-ffff-00001486",
                                     version: "structural-1",
                                     qualification: "qualified"))
        let created = await adapter.projects(.init(
            operation: .create, name: "Pinned", toolchain: "guest-mpw",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        let project = try XCTUnwrap(created.project)
        let descriptor = try await descriptor(of: project.projectID,
                                              through: adapter)
        XCTAssertTrue(descriptor.contains(
            "toolchain=mpw-ffff-00001486@structural-1"), descriptor)
        XCTAssertFalse(descriptor.contains("unselected@0"))
    }

    /// Refused in the guest's own vocabulary: the human act it needs
    /// is Register MPW Folder, and the refusal says so.
    func testCreateWithGuestMPWAndNothingQualifiedRefusesWithTheGuestsWords()
        async throws {
        let adapter = adapter(
            store: try store(),
            environment: environment(toolchain: "not registered",
                                     version: "unavailable",
                                     qualification: "unavailable"))
        let refused = await adapter.projects(.init(
            operation: .create, name: "Unpinnable", toolchain: "guest-mpw",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        XCTAssertNil(refused.project)
        XCTAssertEqual(refused.failure?.code,
                       "now-projects-toolchain-unqualified")
        XCTAssertTrue(refused.failure?.message
            .contains("Register MPW Folder") == true,
            refused.failure?.message ?? "no message")
    }

    /// A registration whose qualification was REFUSED is not a pin
    /// either — `qualified` is the only row value that mints one.
    func testCreateWithGuestMPWAgainstARefusedQualificationRefuses()
        async throws {
        let adapter = adapter(
            store: try store(),
            environment: environment(toolchain: "mpw-ffff-00001486",
                                     version: "structural-1",
                                     qualification: "refused"))
        let refused = await adapter.projects(.init(
            operation: .create, name: "Unpinnable", toolchain: "guest-mpw",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        XCTAssertEqual(refused.failure?.code,
                       "now-projects-toolchain-unqualified")
    }

    func testCreateWithHostRetro68WritesTheSentinelPin() async throws {
        // No environment stub on purpose: the sentinel must not
        // consult the guest at all (nothing is connected here).
        let projectStore = try store()
        let adapter = AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "project-test", name: "Project Test Host")),
            projectStore: projectStore)
        let created = await adapter.projects(.init(
            operation: .create, name: "Lane Built",
            toolchain: "host-retro68",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        let project = try XCTUnwrap(created.project)
        let descriptor = try await descriptor(of: project.projectID,
                                              through: adapter)
        XCTAssertTrue(descriptor.contains("toolchain=host-retro68@1"),
                      descriptor)
    }

    /// THE DEFAULTING RULE, both halves: absent a choice, a qualified
    /// guest wins for a host-home project too (the mainline MPW flow),
    /// and no qualified guest degrades to the host lane's sentinel.
    func testAbsentToolchainDefaultsByWhatTheGuestReports() async throws {
        let qualified = adapter(
            store: try store(),
            environment: environment(toolchain: "mpw-aaaa-00000001",
                                     version: "structural-1",
                                     qualification: "qualified"))
        let pinned = await qualified.projects(.init(
            operation: .create, name: "Defaulted",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        let pinnedDescriptor = try await descriptor(
            of: try XCTUnwrap(pinned.project).projectID, through: qualified)
        XCTAssertTrue(pinnedDescriptor.contains(
            "toolchain=mpw-aaaa-00000001@structural-1"), pinnedDescriptor)

        let unqualified = adapter(
            store: try store(),
            environment: environment(toolchain: "not registered",
                                     version: "unavailable",
                                     qualification: "unavailable"))
        let sentinel = await unqualified.projects(.init(
            operation: .create, name: "Defaulted Too",
            changes: [write("Sources/Main.c", "int main(void) { return 0; }")],
            attemptID: attempt))
        let sentinelDescriptor = try await descriptor(
            of: try XCTUnwrap(sentinel.project).projectID,
            through: unqualified)
        XCTAssertTrue(sentinelDescriptor.contains(
            "toolchain=host-retro68@1"), sentinelDescriptor)
    }

    /// The sidebar's sheet passes an explicit choice through the chat
    /// mint seam, and it beats the default: a qualified guest with the
    /// person choosing Retro68 still writes the sentinel, and choosing
    /// MPW writes exactly what the guest measured.
    func testChatMintThreadsTheExplicitToolchainChoice() async throws {
        let projectStore = try store()
        let adapter = adapter(
            store: projectStore,
            environment: environment(toolchain: "mpw-cccc-00000003",
                                     version: "structural-1",
                                     qualification: "qualified"))
        let sentinel = try (await adapter.mintChatLinkedProject(
            name: "Lane Chosen", home: .host,
            toolchain: "host-retro68")).get()
        let sentinelDescriptor = try await descriptor(
            of: sentinel.rawValue, through: adapter)
        XCTAssertTrue(sentinelDescriptor.contains("toolchain=host-retro68@1"),
                      sentinelDescriptor)

        let pinned = try (await adapter.mintChatLinkedProject(
            name: "MPW Chosen", home: .host,
            toolchain: "guest-mpw")).get()
        let pinnedDescriptor = try await descriptor(
            of: pinned.rawValue, through: adapter)
        XCTAssertTrue(pinnedDescriptor.contains(
            "toolchain=mpw-cccc-00000003@structural-1"), pinnedDescriptor)
    }

    /// The explicit MPW ask refuses with the guest's own vocabulary
    /// when nothing is qualified — the sheet shows these words on the
    /// disabled option.
    func testChatMintRefusesAnUnqualifiedExplicitMPWAsk() async throws {
        let adapter = adapter(
            store: try store(),
            environment: environment(toolchain: "not registered",
                                     version: "unavailable",
                                     qualification: "unavailable"))
        let refused = await adapter.mintChatLinkedProject(
            name: "MPW Wish", home: .host, toolchain: "guest-mpw")
        guard case .failure(let refusal) = refused else {
            return XCTFail("an unqualified explicit MPW ask minted anyway")
        }
        XCTAssertEqual(refusal, .guestToolchainUnqualified)
        XCTAssertTrue(refusal.message.contains("Register MPW Folder"),
                      refusal.message)
    }

    /// The agent template used to emit NO build-action lines, so every
    /// created project refused `build-plan-empty` on the guest. The
    /// descriptor must now parse to a nonempty single-file MrC/PPCLink
    /// plan, with a Rez append for each .r source.
    func testAgentTemplateEmitsAWorkingSingleFileBuildPlan() async throws {
        let adapter = adapter(store: try store())
        let created = await adapter.projects(.init(
            operation: .create, name: "Buildable",
            toolchain: "host-retro68",
            changes: [
                write("Sources/Main.c", "int main(void) { return 0; }"),
                write("Sources/Main.r", "/* resources */"),
            ], attemptID: attempt))
        let project = try XCTUnwrap(created.project)
        let text = try await descriptor(of: project.projectID,
                                        through: adapter)
        let parsed = try CKProjectDocument.parse(Data(text.utf8))
        let actions = parsed.records.filter { $0.key == "build-action" }
            .map(\.value)
        XCTAssertEqual(actions, [
            "compile|Sources/Main.c|Build/Main.c.o",
            "link|Build/Main.c.o|Build/Product",
            "rez|Sources/Main.r|Build/Product",
        ])
    }

    /// The closed kind|input|output vocabulary cannot express a
    /// multi-object link, so a multi-C create honestly emits no plan
    /// rather than one that fails at action 1.
    func testAgentTemplateDeclinesToGuessAMultiFilePlan() async throws {
        let adapter = adapter(store: try store())
        let created = await adapter.projects(.init(
            operation: .create, name: "Two Files",
            toolchain: "host-retro68",
            changes: [
                write("Sources/Main.c", "int main(void) { return 0; }"),
                write("Sources/Other.c", "int other(void) { return 1; }"),
            ], attemptID: attempt))
        let project = try XCTUnwrap(created.project)
        let text = try await descriptor(of: project.projectID,
                                        through: adapter)
        XCTAssertFalse(text.contains("build-action="), text)
    }

    /// The host UI template resolves the same pin by the same rule —
    /// it used to emit `unselected@0`, which no build can ever pass.
    func testHostUITemplateResolvesItsPinInsteadOfUnselected() async throws {
        let projectStore = try store()
        let report = environment(toolchain: "mpw-bbbb-00000002",
                                 version: "structural-1",
                                 qualification: "qualified")
        let model = DevelopmentModel(
            store: projectStore,
            readEnvironment: { report })
        model.createHostProject(name: "Sheet Made")
        var status: ProjectStatus?
        for _ in 0..<200 where status == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            status = try projectStore.list().first
        }
        let projectID = try XCTUnwrap(status,
            model.problem ?? "the create never landed").projectID
        let text = try XCTUnwrap(String(
            data: try projectStore.read(projectID: projectID,
                                        path: "Project.ckp"),
            encoding: .utf8))
        XCTAssertTrue(text.contains(
            "toolchain=mpw-bbbb-00000002@structural-1"), text)
        XCTAssertFalse(text.contains("unselected@0"))
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
