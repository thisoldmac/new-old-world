import XCTest
@testable import NOWAgentIntegration

/// The seam's own coverage.
///
/// The property under test is not "the twelve capabilities are there" — it
/// is that adding a thirteenth is one file plus one row, and that two rows
/// claiming one capability fails loudly instead of one winning silently.
/// The second half is what makes the first safe to fan out across agents.
final class HostProjectionRegistryTests: XCTestCase {

    // MARK: - Registration

    /// The `try!` behind `HostProjectionRegistry.hostFaces` traps, so this
    /// is where a duplicate row is found rather than in a running host.
    func testTheDeclaredCatalogRegistersWithoutCollision() throws {
        let registry = try HostProjectionRegistry(
            HostProjectionCatalog.projections)
        XCTAssertEqual(
            registry.capabilities.count,
            Set(registry.capabilities).count,
            "Two catalog rows claim one capability name.")
        XCTAssertEqual(
            registry.projections.count,
            HostProjectionCatalog.projections.count)
    }

    /// Duplicate registration must FAIL, not resolve. A silent winner
    /// leaves the loser's capability unreachable from whichever face reads
    /// the registry second, which is exactly the drift the host-face parity
    /// work exists to catch — and it would be invisible.
    func testADuplicateCapabilityFailsLoudlyNamingIt() {
        do {
            _ = try HostProjectionRegistry([
                SessionHealthProjection.self,
                ListProcessesProjection.self,
                DuplicateHealthProjection.self,
            ])
            XCTFail(
                "A second projection claiming now_list_machines "
                    + "registered without complaint.")
        } catch let error as HostProjectionRegistry.DuplicateCapability {
            XCTAssertEqual(
                error.capability, SessionHealthProjection.capability)
            XCTAssertTrue(
                error.description.contains("now_list_machines"),
                "The failure should name the capability that collided; "
                    + "that is the useful half. Got: \(error.description)")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testDeclarationOrderIsPreservedAndLookupIsByName() throws {
        let registry = HostProjectionRegistry.hostFaces
        XCTAssertEqual(
            registry.capabilities.map(\.rawValue),
            HostProjectionCatalog.projections.map {
                $0.capability.rawValue
            })
        XCTAssertNotNil(
            registry.projection(named: "now_launch_software"))
        XCTAssertNil(registry.projection(named: "now_not_a_capability"))
        XCTAssertNotNil(registry[SessionHealthProjection.capability])
    }

    // MARK: - What a row has to state

    /// A row states its own rendering completely, and does NOT state its
    /// own name: the renderer injects that, so a capability cannot end up
    /// registered under one spelling and advertised under another.
    func testEveryRowRendersACompleteDescriptorWithoutItsOwnName() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let name = projection.capability.rawValue
            let descriptor = projection.mcpDescriptor
            XCTAssertNil(
                descriptor["name"],
                "\(name) writes its own tool name into its descriptor. "
                    + "The renderer injects it from the capability, so a "
                    + "row that also states it can disagree with itself.")
            for key in [
                "title", "description", "inputSchema", "outputSchema",
                "annotations",
            ] {
                XCTAssertNotNil(
                    descriptor[key],
                    "\(name) renders no \(key).")
            }
            XCTAssertFalse(
                projection.availabilityNote.isEmpty,
                "\(name) states no availability note, so the capability "
                    + "report has nothing to tell a caller when the guest "
                    + "does serve it.")
        }
    }

    /// The server guide and repo skill state the evidence ladder, but the
    /// escalation tools must also carry it locally. A small client may choose
    /// from one tool description without consulting either optional surface.
    func testDirectAndPixelEscalationsStateTheirPlaceInTheEvidenceLadder() {
        let direct = ObserveElementsProjection.mcpDescriptor["description"]
            as? String ?? ""
        XCTAssertTrue(
            direct.contains("now_semantic_ui_snapshot"), direct)
        XCTAssertTrue(
            direct.contains("retained state is incomplete"), direct)
        XCTAssertTrue(
            direct.contains("Do not call this in parallel"), direct)

        let retained = MirrorSnapshotProjection.mcpDescriptor["description"]
            as? String ?? ""
        XCTAssertTrue(
            retained.contains("now_observe_elements"), retained)
        XCTAssertTrue(
            retained.contains("before deciding whether to escalate"), retained)

        let pixels = CaptureScreenProjection.mcpDescriptor["description"]
            as? String ?? ""
        XCTAssertTrue(
            pixels.contains("genuinely visual"), pixels)
        XCTAssertTrue(
            pixels.contains("semantic evidence cannot answer"), pixels)
    }

    /// A requirement is a guest command or message family that the ledger
    /// resolves. A typo does not fail anywhere: `state(of:)` falls through
    /// to the command table, misses, and reports the capability
    /// permanently UNAVAILABLE against every guest — a tool switched off by
    /// a spelling mistake, with no error anywhere.
    ///
    /// The known set is `AgentIntegrationCapabilityNames.all`, read rather
    /// than restated: this test used to keep its own copy of the seven
    /// names, so a capability requiring a newly-declared one had to edit a
    /// test to be allowed to. The declaration is the list now.
    func testEveryRequirementIsAKnownGuestCapabilityName() {
        let known = AgentIntegrationCapabilityNames.all
        XCTAssertFalse(
            known.isEmpty,
            "AgentIntegrationCapabilityNames.all is empty, so this check "
                + "passes nothing and would accept any requirement.")
        for projection in HostProjectionRegistry.hostFaces.projections {
            for requirement in projection.requires {
                XCTAssertTrue(
                    known.contains(requirement),
                    "\(projection.capability.rawValue) requires "
                        + "\"\(requirement)\", which is not a name in "
                        + "AgentIntegrationCapabilityNames. Add it there "
                        + "rather than spelling it here: an unknown "
                        + "requirement is silently treated as a missing "
                        + "command, so the capability reads unavailable "
                        + "against every guest and nothing complains.")
            }
        }
    }

    // MARK: - Bounding is the projection's own job

    /// The three no-argument projections reject a non-empty object and
    /// accept both absent and empty, which is the distinction the
    /// arguments box exists to keep.
    func testANoArgumentProjectionRefusesArgumentsInItsOwnWords() async {
        let client = SilentClient()
        for projection in [
            SessionHealthProjection.self as any HostProjection.Type,
            ListProcessesProjection.self,
            GuestFilesCapabilitiesProjection.self,
        ] {
            let name = projection.capability.rawValue
            switch await projection.invoke(
                .init(raw: ["unexpected": 1]), through: client) {
            case .invalidArguments(let message):
                XCTAssertEqual(message, "\(name) accepts no arguments")
            case .value:
                XCTFail("\(name) accepted an argument it does not take.")
            case .deniedByConsent:
                /* Unreachable by construction: the consent check runs in the
                   dispatch, before `invoke`, so a row cannot produce this. */
                XCTFail("\(name) produced a consent denial of its own.")
            }
            for raw in [nil, [String: Any]()] as [Any?] {
                switch await projection.invoke(
                    .init(raw: raw), through: client) {
                case .value:
                    break
                case .invalidArguments(let message):
                    XCTFail("\(name) refused \(String(describing: raw)): "
                        + message)
                case .deniedByConsent:
                    XCTFail("\(name) produced a consent denial of its own.")
                }
            }
        }
    }
}

/// A second claimant on a registered capability. It exists only to be
/// refused; nothing registers it.
private enum DuplicateHealthProjection: HostProjection {
    static let capability = SessionHealthProjection.capability
    static let requires: [String] = []
    static let exposes: [String] = []
    /// Stated for the same reason `faces` is, and by the same rule: the
    /// protocol gives no default, so a row that has not thought about its
    /// key namespace does not compile. Including this one.
    static let acceptedArguments: Set<String> = []
    /// Nothing registers it, so no face reaches it. Stated rather than
    /// defaulted, because the protocol deliberately has no default: a row
    /// that says nothing about a face is the drift HostFaceParityTests is
    /// for, and that has to be true of every conformer including this one.
    static let faces: [HostCapabilityFace: HostFaceReach] = Dictionary(
        uniqueKeysWithValues: HostCapabilityFace.allCases.map {
            ($0, .notReached(because:
                "A second claimant on a registered capability, existing only "
                + "to be refused by the registry. It is never in the "
                + "catalog, so no face can reach it."))
        })
    static let availabilityNote = "Never reached."
    static var mcpDescriptor: [String: Any] { [:] }

    static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        .invalidArguments("Never reached.")
    }
}

/// Answers "no host" to everything, through the protocol's own defaults.
/// A projection under test must reach its argument bound without a host.
private struct SilentClient: AgentIntegrationClient {
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }

    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}
