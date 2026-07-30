import XCTest
@testable import Host
import NOWAgentIntegration

/// The transfer-cancel capability's own coverage, aimed at the two things
/// that are genuinely its own: **that it ends a transfer in either
/// direction**, and **that it never claims the guest stopped.**
///
/// The second is the harder one to test honestly, because the fact it
/// asserts is a negative: `file.cancel` has no reply, so there is nothing to
/// stub in that could make the answer better or worse. What CAN be pinned is
/// that the outcome vocabulary has no case that would say it, and that the
/// one positive claim the row makes — this host's own half of the lane came
/// free — is read back from the listener rather than assumed.
@MainActor
final class AgentIntegrationTransferCancelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Either direction, which is why this is not the download

    /// A transfer the host is SENDING is ended, and the receipt says so.
    ///
    /// This is the case that justifies the operation existing separately:
    /// an upload is invisible to the download lane, and a stalled send is
    /// exactly what wedges a one-wide lane — the send that would notice a
    /// cancellation is the one not completing.
    func testAnUploadInFlightIsEndedAndNamedAsOutgoing() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var settled = false
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 9, count: 200_000)) { _ in
            settled = true
        }
        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileAccept(FileAccept(id: try XCTUnwrap(offerId))))
        try await waitUntil("bytes moving") { guest.bulkReceived.count > 0 }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = adapter.cancelTransfer()

        guard case .completed(let receipt) = result else {
            return XCTFail("an upload in flight is cancellable: \(result)")
        }
        XCTAssertEqual(receipt.outcome, .asked)
        XCTAssertEqual(receipt.direction, .outgoing)
        XCTAssertTrue(receipt.hostLaneFree,
                      "the host's own half must come free, or the next "
                          + "transfer is refused by a lane nobody holds")
        try await waitUntil("the put settled") { settled }
        XCTAssertNil(listener.fileTransferInFlight)
    }

    /// A transfer the host is RECEIVING is ended too, and the cancel reaches
    /// the wire — the guest is the sender there, so the message is the only
    /// thing that can stop it.
    func testADownloadInFlightIsEndedAndTheCancelReachesTheWire()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        var failure: GuestListener.FileFailure?
        listener.getFile(path: "Interrupted", container: "data",
                         stagingDirectory: directory) { result in
            if case .failure(let problem) = result { failure = problem }
        }
        var getId: Int?
        try await waitUntil("file.get") {
            for message in guest.received {
                if case .fileGet(let get) = message {
                    getId = get.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileBegin(FileBegin(
            id: try XCTUnwrap(getId), transfer: 11, name: "Interrupted",
            container: "data", bytes: 1_000_000, dataBytes: 1_000_000,
            rsrcBytes: 0, fileType: "BINA", creator: "????", modified: nil)))
        /* The BEGIN, not the request: `Session.cancelFile()` names the
           transfer off the guest's own file.begin, so a cancel sent before
           that arrives reaches no wire. That is a real hole in the wire's
           cancel and it is not this row's to close — what is this row's is
           not claiming otherwise, which `askedNote` handles. */
        try await waitUntil("the guest has begun sending") {
            listener.captureProgress != nil
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        let result = adapter.cancelTransfer()

        guard case .completed(let receipt) = result else {
            return XCTFail("a download in flight is cancellable")
        }
        XCTAssertEqual(receipt.outcome, .asked)
        XCTAssertEqual(receipt.direction, .incoming)
        XCTAssertTrue(receipt.hostLaneFree)
        try await waitUntil("file.cancel on the wire") {
            guest.received.contains {
                if case .fileCancel(let cancel) = $0 {
                    return cancel.transfer == 11
                }
                return false
            }
        }
        try await waitUntil("the download settled") {
            failure?.code == "cancelled"
        }
    }

    // MARK: - Asked is not confirmed

    /// **The vocabulary has no way to say the guest stopped, and that is the
    /// assertion.**
    ///
    /// A guest that answers a cancel with anything at all is off-contract, so
    /// there is no stub that could earn a stronger word here. What this pins
    /// is the shape: two cases, neither of them `cancelled`, so a later
    /// author cannot reach for one — and the receipt's own confirmed fact is
    /// about this host.
    func testNoOutcomeClaimsTheGuestStopped() {
        XCTAssertEqual(
            Set(AgentIntegrationTransferCancelOutcome.allCases
                .map(\.rawValue)),
            ["asked", "nothing-to-cancel"],
            "A third case, or a rename back to \"cancelled\", would let "
                + "this row report a fact only the Macintosh can know: "
                + "file.cancel has no reply, and the terminal message a "
                + "guest does send for a cancelled transfer is discarded "
                + "by Session.finishFile on purpose.")
    }

    /// The confirmed half is READ BACK, not assumed. The listener's lane is
    /// the source: a receipt saying `hostLaneFree` while the listener still
    /// holds a transfer would be the host asserting its own state without
    /// looking, which is the same error one layer in.
    func testTheLaneIsReReadRatherThanAssumed() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 3, count: 100_000)) { _ in }
        try await waitUntil("the lane is holding it") {
            listener.fileTransferInFlight == .outgoing
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .completed(let receipt) = adapter.cancelTransfer() else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(receipt.hostLaneFree,
                       listener.fileTransferInFlight == nil)
        XCTAssertNil(listener.fileTransferInFlight)
    }

    // MARK: - Cancelling nothing

    /// A quiet lane is ANSWERED, not refused. Asking a machine that is not
    /// transferring anything to stop is a reasonable thing to have done —
    /// the guests treat it that way too, and a caller retrying after a
    /// transfer finished must not read a failure.
    func testAQuietLaneIsAnsweredRatherThanRefused() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .completed(let receipt) = adapter.cancelTransfer() else {
            return XCTFail("nothing to cancel is an answer, not a refusal")
        }
        XCTAssertEqual(receipt.outcome, .nothingToCancel)
        XCTAssertNil(receipt.direction)
        XCTAssertTrue(receipt.hostLaneFree)
        XCTAssertFalse(
            guest.received.contains {
                if case .fileCancel = $0 { return true }
                return false
            },
            "Nothing was in flight, so nothing should have been sent: a "
                + "cancel naming a transfer id the host invented could end "
                + "one it did not know about.")
    }

    /// Asking twice is safe, and the second answer is the quiet-lane one.
    /// That is the difference between this and an idempotent operation, and
    /// it is declared as such in the descriptor.
    func testASecondCancelFindsTheLaneQuiet() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 1, count: 50_000)) { _ in }
        try await waitUntil("in flight") {
            listener.fileTransferInFlight != nil
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .completed(let first) = adapter.cancelTransfer(),
              case .completed(let second) = adapter.cancelTransfer() else {
            return XCTFail("both calls answer")
        }
        XCTAssertEqual(first.outcome, .asked)
        XCTAssertEqual(second.outcome, .nothingToCancel)
    }

    /// A capture holding the one-wide lane is not a file transfer, and this
    /// operation does not end one — but the caller is TOLD, because
    /// "nothing to cancel" on its own would read as an idle machine whose
    /// next transfer will be accepted.
    func testACaptureHoldingTheLaneIsNamedAndNotEnded() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        listener.requestCapture(depth: 1) { _ in }
        try await waitUntil("capture pending") { listener.isCapturePending }
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        guard case .completed(let receipt) = adapter.cancelTransfer() else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(receipt.outcome, .nothingToCancel)
        XCTAssertEqual(receipt.note?.contains("capture"), true,
                       "a lane held by something this operation cannot end "
                           + "is the one thing the note is for")
        XCTAssertTrue(listener.isCapturePending,
                      "file.cancel does not abandon a capture; "
                          + "now_capture_screen's abandon does")
    }

    // MARK: - The person's transfer, and what they get told

    /// **An agent may end a transfer a person started, and the host says so
    /// where the person reads it.**
    ///
    /// The decision is deliberate: the host records no origin for the
    /// transfer holding the lane, so a row that refused what it could not
    /// attribute could never cancel anything — and the transfer most in need
    /// of ending is a stalled one on a machine that will otherwise refuse
    /// every later transfer. The price is this line, in the `files` area the
    /// person's own transfers already log under, at warn, claiming no owner
    /// because the host does not know one.
    func testTheLogLineNamesTheDirectionAndClaimsNoOwner() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        listener.putFile(name: "Report", into: "", container: "data",
                         bytes: Data(repeating: 7, count: 80_000)) { _ in }
        try await waitUntil("in flight") {
            listener.fileTransferInFlight != nil
        }
        let before = listener.log.count
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        _ = adapter.cancelTransfer()

        let written = listener.log.dropFirst(before).map(\.text)
        guard let line = written.first(where: {
            $0.contains("transfer cancel")
        }) else {
            return XCTFail("nothing a person could read: \(written)")
        }
        XCTAssertTrue(line.contains("an agent stopped"), line)
        XCTAssertTrue(line.contains("outgoing"), line)
        XCTAssertTrue(line.contains("does not record who started it"),
                      "Claiming the agent's own transfer was cancelled "
                          + "would be a guess: putFile and getFile take a "
                          + "completion and no origin. \(line)")
    }

    /// A quiet lane writes no `files` line. The dispatch's audit event
    /// already records every invocation; a second line for an operation that
    /// changed nothing would train the person to skim the area where their
    /// own transfers are reported.
    func testNothingToCancelWritesNoTransferLine() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let before = listener.log.count
        let adapter = AgentIntegrationHostAdapter(listener: listener)

        _ = adapter.cancelTransfer()

        XCTAssertFalse(
            listener.log.dropFirst(before).map(\.text)
                .contains { $0.contains("transfer cancel") })
    }

    // MARK: - No guest, no answer about a guest

    /// `unavailable`, not `nothingToCancel`. "There was no machine" and "the
    /// machine was quiet" are different facts, and only one of them is a
    /// statement about a Macintosh.
    func testADisconnectedGuestIsUnavailableRatherThanQuiet() {
        let disconnected = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let result = AgentIntegrationHostAdapter(
            listener: disconnected).cancelTransfer()

        guard case .unavailable(let missing) = result else {
            return XCTFail("no guest cannot report a quiet lane: \(result)")
        }
        XCTAssertEqual(missing.code, "now-guest-unavailable")
    }

    // MARK: - The projection's own bound

    /// It takes nothing, and says so in its own words. There is no
    /// identifier to accept: the lane is one transfer wide across both
    /// directions, and the wire's `transfer` field is the host's own
    /// sequence number.
    func testTheProjectionAcceptsNoArguments() async {
        let expected = "now_transfer_cancel accepts no arguments"
        for raw in [["transfer": 11], ["direction": "incoming"]] as [Any] {
            let outcome = await TransferCancelProjection.invoke(
                .init(raw: raw), through: CancelStubHost())
            guard case .invalidArguments(let message) = outcome else {
                return XCTFail("accepted \(raw) as an argument")
            }
            XCTAssertEqual(message, expected)
        }
        for raw in [nil, [String: Any]()] as [Any?] {
            let outcome = await TransferCancelProjection.invoke(
                .init(raw: raw), through: CancelStubHost())
            guard case .value = outcome else {
                return XCTFail("an empty call is a complete request")
            }
        }
    }

    /// The host's answer survives to the caller unchanged, and the row
    /// renders it rather than re-deciding it.
    func testTheHostsOutcomeIsRenderedAndNotReDecided() async throws {
        let host = CancelStubHost()
        let outcome = await TransferCancelProjection.invoke(
            .init(raw: nil), through: host)

        guard case .value(let value) = outcome else {
            return XCTFail("expected the host's answer")
        }
        let json = String(
            decoding: try value.encoded(using: JSONEncoder()),
            as: UTF8.self)
        XCTAssertTrue(json.contains("\"outcome\":\"completed\""))
        XCTAssertTrue(json.contains("\"asked\""))
        XCTAssertFalse(json.contains("cancelled"))
        XCTAssertNil(value.attachment,
                     "This row answers in JSON; only capture attaches.")
    }

    /// The row exposes what it requires: a caller directs the effect, which
    /// is the whole of the capability. And it requires the MESSAGE, not the
    /// 68K guest's verb — one capability, two guest answers, no ISA fork.
    func testTheRowRequiresTheMessageOnBothGuests() {
        XCTAssertEqual(TransferCancelProjection.requires,
                       [AgentIntegrationCapabilityNames.fileCancel])
        XCTAssertEqual(TransferCancelProjection.exposes,
                       TransferCancelProjection.requires)
        XCTAssertEqual(AgentIntegrationCapabilityNames.fileCancel,
                       "file.cancel",
                       "Requiring the 68K `cancel` verb instead would make "
                           + "a capability both guests serve read as "
                           + "68K-only.")
    }

    /// Every sentence this row can write fits the bound its schema
    /// declares. The note is the host's own words — a cancel has no reply
    /// to carry a guest's — so nothing else caps it.
    func testEveryNoteFitsTheDeclaredBound() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let adapter = AgentIntegrationHostAdapter(listener: listener)
        var notes: [String] = []

        if case .completed(let quiet) = adapter.cancelTransfer(),
           let note = quiet.note {
            notes.append(note)
        }
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 2, count: 60_000)) { _ in }
        try await waitUntil("in flight") {
            listener.fileTransferInFlight != nil
        }
        if case .completed(let asked) = adapter.cancelTransfer(),
           let note = asked.note {
            notes.append(note)
        }

        XCTAssertEqual(notes.count, 2)
        for note in notes {
            XCTAssertLessThanOrEqual(
                note.unicodeScalars.count,
                AgentIntegrationTransferCancelPolicy.maximumNoteScalars,
                "This row's own sentence overruns the maxLength its schema "
                    + "publishes: \(note.unicodeScalars.count) scalars.")
        }
    }
}

/// Answers one cancel and nothing else; every other lane falls to the
/// protocol's "no host" defaults.
private actor CancelStubHost: AgentIntegrationClient {
    func cancelTransfer() async -> AgentIntegrationTransferCancelResult {
        .completed(.init(outcome: .asked,
                         direction: .outgoing,
                         confirmedBytes: 4_096,
                         expectedBytes: 200_000,
                         hostLaneFree: true,
                         note: "file.cancel is on the wire",
                         observedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    // MARK: - Everything else answers "no host"

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
