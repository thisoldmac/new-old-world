import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **An unread parameter is indistinguishable from an absent one.**
///
/// The sibling Mirror project measured what that costs on a real machine
/// (`mirror` 156b8ce): a caller sent `modifiers` where the contract's name is
/// `mods`, the key was never read, the service pressed an unmodified `q` into
/// an open document, and the reply said `performed: true`. A misspelled VALUE
/// was already refused there; a misspelled KEY was not, and that is the worse
/// half — the failure mode of a dropped modifier is not "nothing happens", it
/// is "a different thing happens, silently, and the reply says it worked".
///
/// Three separate properties are gated here, and they fail apart on purpose:
///
/// 1. **The declaration is read off the contract, not guessed.** Every row's
///    `acceptedArguments` equals the `properties` of the `inputSchema` it
///    publishes. This is the test that stops the fix from rebuilding the bug
///    one row over: a hand-written set that has drifted from the schema is a
///    surface advertising one spelling and accepting another.
/// 2. **The gate is SHARED.** It lives at the dispatch, so a row that reads
///    its arguments carelessly — or a row added next year that reads them not
///    at all — is strict anyway, and is strict before its `invoke` runs.
/// 3. **The refusal names both halves.** "Unknown parameter" leaves the
///    caller guessing which of `toPath` and `destinationPath` is real, and
///    guessing is the whole failure being fixed.
final class HostProjectionArgumentStrictnessTests: XCTestCase {

    /// A key no row accepts and no row ever will, spelled once.
    private static let unknownKey = "nowNoRowAcceptsThisParameter"

    // MARK: - The declaration is the contract's, not a guess

    /// **Every row's accepted set IS its published schema's properties.**
    ///
    /// Asked of the registry, so row twenty-six is covered the day it lands.
    /// The direction matters in both senses and each has its own failure: a
    /// key in the schema and not in the set is a documented parameter the
    /// gate would refuse, and a key in the set and not in the schema is a
    /// parameter the gate admits that no caller was ever told about.
    func testEveryRowsAcceptedSetIsExactlyItsPublishedSchemasProperties() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let schema = projection.mcpDescriptor["inputSchema"]
                as? [String: Any]
            XCTAssertNotNil(
                schema,
                "\(projection.capability) publishes no inputSchema, so "
                    + "nothing can check its accepted keys against what its "
                    + "callers were told.")
            let properties = Set(
                ((schema?["properties"] as? [String: Any]) ?? [:]).keys)
            XCTAssertEqual(
                projection.acceptedArguments, properties,
                "\(projection.capability) accepts "
                    + "\(projection.acceptedArguments.sorted()) and "
                    + "publishes \(properties.sorted()). One of the two is "
                    + "the lie a caller reads.")
        }
    }

    /// The schema says strict too, so the two halves of the promise agree.
    ///
    /// A published `additionalProperties: true` beside a gate that refuses
    /// unknown keys would be a surface documenting the fail-open behaviour it
    /// no longer has.
    func testEveryRowsSchemaDeclaresItselfClosed() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let schema = (projection.mcpDescriptor["inputSchema"]
                as? [String: Any]) ?? [:]
            XCTAssertEqual(
                schema["additionalProperties"] as? Bool, false,
                "\(projection.capability) does not publish "
                    + "additionalProperties: false, so its schema still "
                    + "tells a caller unknown keys are allowed.")
        }
    }

    /// **The envelope's members are not any row's arguments.**
    ///
    /// `guest` says which machine a call is about. A row that listed it would
    /// be claiming an addressing member as a capability parameter, and would
    /// be the row that starts implementing addressing itself.
    func testNoRowClaimsAnEnvelopeMemberAsItsOwnArgument() {
        for projection in HostProjectionRegistry.hostFaces.projections {
            XCTAssertTrue(
                projection.acceptedArguments.isDisjoint(
                    with: HostProjectionArguments.envelopeMembers),
                "\(projection.capability) lists an envelope member among its "
                    + "own arguments.")
        }
    }

    // MARK: - The gate refuses, for every row

    /// Every registered row refuses a key it does not know.
    ///
    /// Registry-wide rather than row by row, because the property being
    /// asserted is that no row is exempt — and a hand-written list of rows to
    /// check is the shape that leaves the twenty-sixth one out.
    func testEveryRowRefusesAKeyItDoesNotKnow() async {
        for projection in HostProjectionRegistry.hostFaces.projections {
            let outcome = await HostProjectionDispatch(
                face: .mcp, audit: SilentSink())
                .invoke(projection.capability.rawValue,
                        arguments: .init(raw: [Self.unknownKey: "anything"]),
                        guest: nil,
                        through: NoHostRecordingClient())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail(
                    "\(projection.capability) did not refuse "
                        + "\(Self.unknownKey): \(String(describing: outcome))")
            }
            guard !projection.acceptedArguments.isEmpty else {
                XCTAssertEqual(
                    message,
                    "\(projection.capability.rawValue) accepts no arguments",
                    "A row that takes nothing changed the wording it has "
                        + "answered with since before this gate existed.")
                continue
            }
            XCTAssertTrue(
                message.contains(Self.unknownKey),
                "\(projection.capability) refused without saying what it "
                    + "got: \(message)")
            for accepted in projection.acceptedArguments {
                XCTAssertTrue(
                    message.contains(accepted),
                    "\(projection.capability) refused without offering "
                        + "\(accepted), so the caller is still guessing: "
                        + "\(message)")
            }
        }
    }

    /// **The refusal, in full, for the row where a typo is most expensive.**
    ///
    /// `now_guest_files_mutate` carries two OPTIONAL keys, which is the shape
    /// a dropped parameter hides in: on a fail-open surface a caller who
    /// wrote `destinationPath` for `toPath` has described a move and would
    /// get a trash — a different destructive action, reported as a success.
    /// Asserted as the whole sentence rather than a `contains`, because the
    /// sentence is the fix.
    func testTheRefusalNamesBothWhatArrivedAndWhatTheRowAccepts() async {
        let outcome = await HostProjectionDispatch(
            face: .mcp, audit: SilentSink())
            .invoke(GuestFilesMutateProjection.capability.rawValue,
                    arguments: .init(raw: [
                        "mutation": "move",
                        "path": "Documents:notes",
                        "destinationPath": "Documents:notes 2",
                    ]),
                    guest: nil,
                    through: NoHostRecordingClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail(
                "A misspelled destination was not refused: "
                    + String(describing: outcome))
        }
        XCTAssertEqual(
            message,
            "now_guest_files_mutate does not accept destinationPath; "
                + "it accepts mutation, path, toPath, trashedAs")
    }

    // MARK: - The gate is the dispatch's, not each row's

    /// **A row that reads nothing is strict anyway.**
    ///
    /// This is the property the whole mechanism exists for: strictness that
    /// each row implements is strictness the next row forgets. The stand-in
    /// here ignores its arguments entirely — the pre-fix shape — and records
    /// whether it ran.
    ///
    /// The negative assertion is ORDERED, not early: `invoke` is awaited to
    /// completion before the flag is read, so the row has either run or will
    /// never run by the time it is asked. A fake read straight after an
    /// un-awaited call would pass whether or not the row ran.
    func testARowThatIgnoresItsArgumentsIsStillRefusedBeforeItRuns() async {
        await CarelessProjection.ran.reset()
        let registry = try! HostProjectionRegistry(
            [CarelessProjection.self])

        let refused = await HostProjectionDispatch(
            face: .mcp, registry: registry, audit: SilentSink())
            .invoke(CarelessProjection.capability.rawValue,
                    arguments: .init(raw: [Self.unknownKey: 1]),
                    guest: nil,
                    through: NoHostRecordingClient())

        guard case .invalidArguments(let message) = refused else {
            return XCTFail(
                "A row that validates nothing was not gated: "
                    + String(describing: refused))
        }
        XCTAssertTrue(message.contains(Self.unknownKey), message)
        let ran = await CarelessProjection.ran.value
        XCTAssertFalse(
            ran,
            "The row ran anyway, so the refusal happened after the machine "
                + "had already been asked.")

        /* The other direction, through the same seam: a key it DOES accept
           reaches it. A gate that refused everything would pass every
           assertion above. */
        _ = await HostProjectionDispatch(
            face: .mcp, registry: registry, audit: SilentSink())
            .invoke(CarelessProjection.capability.rawValue,
                    arguments: .init(raw: ["known": 1]),
                    guest: nil,
                    through: NoHostRecordingClient())
        let reached = await CarelessProjection.ran.value
        XCTAssertTrue(
            reached, "A well-formed call never reached the row.")
    }

    /// **The `guest` selector is addressing and is never an unknown
    /// argument.**
    ///
    /// It is lifted in `HostProjectionArguments.init` rather than by the one
    /// face that happens to strip it today, so the two faces that do not
    /// exist yet cannot forget to. Asserted through the arguments type and
    /// through the dispatch, because those are the two places a regression
    /// would land.
    func testTheGuestSelectorIsNotAnUnknownArgument() async {
        let arguments = HostProjectionArguments(
            raw: ["known": 1, "guest": "pb1400c"])
        XCTAssertEqual(
            Set(arguments.objectOrEmpty.keys), ["known"],
            "The envelope member reached the projection's own arguments.")
        XCTAssertNil(
            arguments.refusalForUnknownMembers(
                tool: CarelessProjection.capability, accepting: ["known"]),
            "The envelope member was counted as an unknown argument.")

        await CarelessProjection.ran.reset()
        let registry = try! HostProjectionRegistry(
            [CarelessProjection.self])
        let outcome = await HostProjectionDispatch(
            face: .mcp, registry: registry, audit: SilentSink())
            .invoke(CarelessProjection.capability.rawValue,
                    arguments: .init(raw: ["known": 1, "guest": "pb1400c"]),
                    guest: "pb1400c",
                    through: NoHostRecordingClient())
        if case .invalidArguments(let message) = outcome {
            XCTFail("Addressing was refused as an argument: \(message)")
        }
        let reached = await CarelessProjection.ran.value
        XCTAssertTrue(reached, "The addressed call never reached the row.")
    }

    // MARK: - What the gate is not

    /// Arguments that are not an object at all stay each row's own business.
    ///
    /// An unknown KEY is a question you can only ask of something with keys.
    /// A row handed a JSON array has a different complaint to make, and the
    /// shared gate must not pre-empt it with a sentence about key spelling.
    func testTheGateSaysNothingAboutArgumentsThatAreNotAnObject() {
        let arguments = HostProjectionArguments(raw: ["a", "b"])
        XCTAssertNil(
            arguments.refusalForUnknownMembers(
                tool: CarelessProjection.capability, accepting: ["known"]))
        XCTAssertNotNil(
            arguments.refusalIfAnyPresent(
                tool: CarelessProjection.capability),
            "A row that takes nothing must still refuse a non-object.")
    }
}

// MARK: - Fixtures

/// A row whose `invoke` reads nothing and refuses nothing — the pre-fix
/// shape, kept as a stand-in so the shared gate can be watched doing the
/// work no row is doing.
private enum CarelessProjection: HostProjection {
    /// Whether `invoke` was reached. An actor because the assertion about it
    /// is a negative one, and a negative assertion read off unsynchronised
    /// state is theatre twice over.
    actor Ran {
        private(set) var value = false
        func note() { value = true }
        func reset() { value = false }
    }

    static let ran = Ran()

    static let capability = HostCapabilityID("now_test_careless")
    static let requires: [String] = []
    static let exposes: [String] = []
    static let acceptedArguments: Set<String> = ["known"]
    static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(because: "A test fixture reaches no face."),
        .mcp: .notReached(because: "A test fixture reaches no face."),
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    static let availabilityNote = "A test fixture."

    static var mcpDescriptor: [String: Any] {
        [
            "title": "A test fixture",
            "description": "A test fixture.",
            "inputSchema": [
                "type": "object",
                "properties": ["known": ["type": "integer"]],
                "additionalProperties": false,
            ],
            "annotations": HostProjectionSchema.readOnlyAnnotations,
        ]
    }

    static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        await ran.note()
        return .value(.init(["ok": true]))
    }
}

/// Records nothing. The audit seam has its own tests; here it is a
/// requirement of constructing a dispatch, not the subject.
private actor SilentSink: HostProjectionAuditSink {
    func record(_ event: HostProjectionAuditEvent) async {}
}

/// No host, so consent never denies and the argument gate is what a call
/// meets. Any lane it is asked for answers unavailable rather than reaching
/// a machine.
private struct NoHostRecordingClient: AgentIntegrationClient {
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

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
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
