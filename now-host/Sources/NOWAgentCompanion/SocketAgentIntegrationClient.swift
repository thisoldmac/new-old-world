import Foundation
import NOWAgentIntegration

/// The companion's one way to reach the running host: a bounded local
/// request per call over the per-uid private socket. It launches nothing and
/// keeps no state about the guest between calls.
struct SocketAgentIntegrationClient: AgentIntegrationClient {
    private var client: AgentIntegrationLocalClient?
    private let startupError: Error?

    init(endpoint: AgentIntegrationEndpoint? = nil) {
        do {
            client = try AgentIntegrationLocalClient(endpoint: endpoint)
            startupError = nil
        } catch {
            client = nil
            startupError = error
        }
    }

    func addressing(_ selector: String?) -> AgentIntegrationClient {
        var copy = self
        copy.client = client?.addressing(selector)
        return copy
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.sessionHealth()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.sessionCapabilities(
                probeCostly: probeCostly)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    /// One census page. A transport failure is "no host" and never a page:
    /// every value in the report's outcome vocabulary is a claim about a
    /// Macintosh, and a socket that could not be reached has made none.
    func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.census(probe: probe, cursor: cursor)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    /// One software listing page. A transport failure is "no host" and never
    /// an empty page: an empty listing reads as "nothing is installed on that
    /// Mac", and a socket that could not be reached has looked at no disk.
    func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.softwareInventory(
                domain: domain, cursor: cursor)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.listProcesses()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.launchSoftware(selection)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.requestQuit(reference: reference)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.bringToFront(reference: reference)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.revealItem(target: target)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        guard let client else {
            return .init(unavailable: unavailable(for: startupError))
        }
        do {
            return try await client.mirrorRead(request)
        } catch {
            return .init(unavailable: unavailable(for: error))
        }
    }

    /// The row this companion exists for, more than most: an agent on
    /// this socket is the caller with no other way to open the window.
    func mirrorOpen() async -> AgentIntegrationMirrorOpenResult {
        guard let client else {
            return .init(unavailable: unavailable(for: startupError))
        }
        do {
            return try await client.mirrorOpen()
        } catch {
            return .init(unavailable: unavailable(for: error))
        }
    }

    /* THE MIRROR'S MUTATION HALF, missing here from the day `mirror_drive`
       landed until 2026-08-07. `mirrorRead` above was written and this was
       not, so `now_mirror_drive` answered the protocol default — "This
       client cannot drive the host Mirror" — from a host whose socket had
       served the operation the whole time. A sentence about a missing lane,
       standing in for a missing forwarder, is the worst shape a refusal can
       take: it sends the reader one layer down to look for something that
       is there. `SocketClientForwardingTests` is now what would have said
       so. */
    func mirrorDrive(_ request: AgentIntegrationMirrorDriveRequest) async
        -> AgentIntegrationMirrorDriveResult {
        guard let client else {
            return .init(unavailable: unavailable(for: startupError))
        }
        do {
            return try await client.mirrorDrive(request)
        } catch {
            return .init(unavailable: unavailable(for: error))
        }
    }

    /* THE ACT LANE, overriding the five protocol defaults that answered
       `noActLane`. That sentence — "this host carries no act lane yet" — was
       true of every client that could reach them and stopped being true the
       moment the local protocol grew the five operations. It stays as the
       DEFAULT for the stub conformers in the test tree, which is exactly
       what the rule at the head of `AgentIntegrationClient` reserved it for.

       Each is the same four lines as the lanes above, and deliberately so:
       there is nothing for this file to decide about an act. The grammar was
       checked by the projection row, checked again by the codec, and checked
       a third time by the adapter; what a completed answer may claim was
       settled by `AgentIntegrationActControl` reading the machine's own
       rows. This side forwards, and turns a broken socket into an
       unavailable rather than into a refusal a machine never made. */

    func windowAct(_ request: AgentIntegrationWindowActRequest) async
        -> AgentIntegrationWindowActResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.windowAct(request)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func controlAct(_ request: AgentIntegrationControlActRequest) async
        -> AgentIntegrationControlActResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.controlAct(request)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func menuAct(_ request: AgentIntegrationMenuActRequest) async
        -> AgentIntegrationMenuActResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.menuAct(request)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.getElementText(element: element)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.setElementText(
                element: element, text: text)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    /* THE WALK, and the one of the three 2026-08-07 restorations that was
       not a forwarder at all. `mirrorDrive` and `tailGuestLog` had lanes
       under them the whole time; this had none — no `observe_elements`
       operation, no adapter method, nothing on the socket. The audit read
       the projection default and reported all three as missing forwarders,
       which was right about the symptom and wrong about this one's depth:
       `tools/now-agent` could not reach the walk either, because it speaks
       this same socket. So the "developer road is fine" consolation did not
       hold here, and the act plane's four addressed rows had no argument
       producer on ANY face of this host. */
    func observeElements(process: AgentIntegrationProcessSerial?) async
        -> AgentIntegrationElementObservationResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.observeElements(process: process)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func cancelTransfer() async
        -> AgentIntegrationTransferCancelResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.cancelTransfer()
        } catch {
            /* "No host" and never `nothingToCancel`: a socket that could not
               be reached has said nothing about whether a Macintosh is
               moving a file. */
            return .unavailable(unavailable(for: error))
        }
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.transferApprovedArtifact(receipt: receipt)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.guestFilesCapabilities()
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.listGuestFiles(
                path: path, cursor: cursor)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.statGuestFile(path: path)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func downloadGuestFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.downloadGuestFile(path: path)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func machineFacts() async -> AgentIntegrationGuestRowReportResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.machineFacts()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    /// The end of the guest's own log. `lines` is passed through as it
    /// arrived, absent included: absent means the guest's own default and is
    /// a COMPLETE request, so substituting a number here would send a
    /// Macintosh a count nobody wrote.
    ///
    /// Missing until 2026-08-07, with the same consequence as `mirrorDrive`
    /// above: `now_guest_log_tail` answered `.hostUnavailable` — "New Old
    /// World host is unavailable" — while the host was up and the
    /// `guest_log_tail` operation was being served.
    func tailGuestLog(lines: Int?) async
        -> AgentIntegrationGuestRowReportResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.tailGuestLog(lines: lines)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func catalogSearch() async -> AgentIntegrationGuestRowReportResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.catalogSearch()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    /// One lane for the three diagnostic rows: the probe is the request, and
    /// which of them a caller may use is the ledger's answer rather than this
    /// client's — see `GuestDiagnosticsProjection`.
    func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe) async
        -> AgentIntegrationGuestRowReportResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.diagnostics(probe: probe)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.beginGuestFileUpload(upload)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.appendGuestFileUpload(
                uploadID: uploadID, offset: offset, bytes: bytes)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            return try await client.commitGuestFileUpload(
                uploadID: uploadID)
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    /// The one place the four intentions become four local requests.
    ///
    /// The wire shapes differ per intention (P1a's `guestFileMutation`
    /// branch), the projection holds one operation, and this is the seam
    /// between them. The two `preconditionFailure`s cannot fire: only
    /// `AgentIntegrationGuestFileMutationRequest`'s failable initialisers can
    /// build one of these, and they refuse a move with no destination and a
    /// restore with no trashed name. They are stated rather than defaulted
    /// for the reason the local client's own branch states its: a substituted
    /// value here would send a Macintosh a request nobody wrote.
    func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult {
        guard let client else {
            return .hostUnavailable(unavailable(for: startupError))
        }
        do {
            switch mutation.mutation {
            case .move:
                guard let toPath = mutation.destinationPath else {
                    preconditionFailure("A move names where it is going")
                }
                return try await client.moveGuestFile(
                    path: mutation.path, toPath: toPath)
            case .trash:
                return try await client.trashGuestFile(path: mutation.path)
            case .restore:
                guard let trashedAs = mutation.trashedAs else {
                    preconditionFailure(
                        "A restore names the item's name in the Trash")
                }
                return try await client.restoreGuestFile(
                    trashedAs: trashedAs, toPath: mutation.path)
            case .mkdir:
                return try await client.makeGuestDirectory(
                    path: mutation.path)
            }
        } catch {
            return .hostUnavailable(unavailable(for: error))
        }
    }

    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.requestCapture(
                depth: depth ?? AgentIntegrationCapturePolicy.defaultDepth)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.fetchCapturePage(
                captureID: captureID, offset: offset)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func abandonGuestCapture() async -> AgentIntegrationCaptureResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.abandonCapture()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func startGuestStream(depth: Int, minIntervalMs: Int) async
        -> AgentIntegrationStreamResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.startStream(
                depth: depth, minIntervalMs: minIntervalMs)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func nextGuestStreamFrame() async -> AgentIntegrationStreamResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.nextStreamFrame()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func fetchGuestStreamFramePage(frameID: UUID, offset: Int) async
        -> AgentIntegrationStreamResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.fetchStreamFramePage(
                frameID: frameID, offset: offset)
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    func stopGuestStream() async -> AgentIntegrationStreamResult {
        guard let client else {
            return .unavailable(unavailable(for: startupError))
        }
        do {
            return try await client.stopStream()
        } catch {
            return .unavailable(unavailable(for: error))
        }
    }

    private func unavailable(for error: Error?)
        -> AgentIntegrationUnavailable {
        guard let error else { return .host }
        guard let local = error as? AgentIntegrationLocalTransportError
        else {
            return .init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed")
        }
        switch local {
        // Passed through as itself. "This host is driving another
        // machine" is a fact about ADDRESSING, and flattening it into a
        // communication failure would tell a caller to retry the one
        // thing that cannot work.
        case .notAddressed(let refusal):
            return refusal
        // Passed through for the same reason: "this host carries the verb
        // and nothing serves it yet" is a fact about the HOST's wiring, and
        // a caller told "communication failed" would retry a call that is
        // going to answer the same way every time.
        case .notImplemented(let pending):
            return pending
        case .hostUnavailable:
            return .host
        case .unsafeEndpoint:
            return .init(
                code: "now-host-endpoint-invalid",
                message: "New Old World host endpoint is not trustworthy")
        case .invalidMessage, .messageTooLarge:
            return .init(
                code: "now-host-invalid-response",
                message: "New Old World host returned an invalid response")
        case .io:
            return .init(
                code: "now-host-communication-failed",
                message: "New Old World host communication failed")
        }
    }
}
