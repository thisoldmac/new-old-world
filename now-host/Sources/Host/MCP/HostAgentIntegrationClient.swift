import Foundation
import NOWAgentIntegration

/* Every in-process agent face's way to reach this host: the same adapter calls the
   local server makes on behalf of the companion, minus the socket and
   the codec — a third CALLER of the one implementation, never a third
   implementation. Each method is the App.swift switch's branch for the
   same operation, read as typed Swift instead of validated wire
   fields.

   Addressing is checked once per call, before the operation, exactly
   as the local server checks it — session health exempt, because it is
   the call a caller makes to discover the ids. A refusal is the
   adapter's own typed sentence, never a substitute answer from another
   machine. `observeElements` is deliberately NOT implemented: no real
   client anywhere carries that lane yet, and the protocol default's
   "no observation lane" is the honest answer here too. */

struct HostAgentIntegrationClient: AgentIntegrationClient {
    let adapter: AgentIntegrationHostAdapter
    let guestFiles: GuestFilesCommandService
    private(set) var selector: String?

    func addressing(_ selector: String?) -> AgentIntegrationClient {
        var copy = self
        copy.selector = selector
        return copy
    }

    private func refusal() async -> AgentIntegrationUnavailable? {
        await adapter.addressingRefusal(selector)
    }

    func projects(_ request: AgentIntegrationProjectRequest) async
        -> AgentIntegrationProjectResult {
        await adapter.projects(request)
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        await adapter.sessionHealth()
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.sessionCapabilities(probeCostly: probeCostly)
    }

    func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.census(probe: probe, cursor: cursor)
    }

    func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.softwareInventory(domain: domain, cursor: cursor)
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.processList()
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.launchSoftware(selection)
    }

    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.requestQuit(reference: reference)
    }

    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.bringToFront(reference: reference)
    }

    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.revealItem(target: target)
    }

    func machineFacts() async -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.machineFacts()
    }

    func developmentEnvironment() async
        -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.developmentEnvironment()
    }

    func development(_ request: AgentIntegrationDevelopmentRequest) async
        -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.development(request)
    }

    func tailGuestLog(lines: Int?, area: String?) async
        -> AgentIntegrationGuestLogRetrievalResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.tailGuestLog(lines: lines, area: area)
    }

    func catalogSearch() async -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.measureCatalogSearch()
    }

    func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe) async
        -> AgentIntegrationGuestRowReportResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.runDiagnostic(probe)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.transferApprovedArtifact(receipt: receipt)
    }

    func cancelTransfer() async -> AgentIntegrationTransferCancelResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.cancelTransfer()
    }

    // MARK: - Guest files

    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentCapabilities()
    }

    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentList(path: path, cursor: cursor)
    }

    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentStat(path: path)
    }

    func downloadGuestFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentDownload(path: path)
    }

    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentBeginUpload(upload)
    }

    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentAppendUpload(
            uploadID: uploadID, offset: offset, bytes: bytes)
    }

    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentCommitUpload(uploadID: uploadID)
    }

    func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult {
        if let refusal = await refusal() { return .hostUnavailable(refusal) }
        return await guestFiles.agentMutate(mutation)
    }

    // MARK: - Capture and stream

    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.capture(
            depth: depth ?? AgentIntegrationCapturePolicy.defaultDepth)
    }

    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.capturePage(captureID: captureID, offset: offset)
    }

    func abandonGuestCapture() async -> AgentIntegrationCaptureResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.abandonCapture()
    }

    func startGuestStream(depth: Int, minIntervalMs: Int) async
        -> AgentIntegrationStreamResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.startStream(
            depth: depth, minIntervalMs: minIntervalMs)
    }

    func nextGuestStreamFrame() async -> AgentIntegrationStreamResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.nextStreamFrame()
    }

    func fetchGuestStreamFramePage(frameID: UUID, offset: Int) async
        -> AgentIntegrationStreamResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.streamFramePage(frameID: frameID, offset: offset)
    }

    func stopGuestStream() async -> AgentIntegrationStreamResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.stopStream()
    }

    // MARK: - Acts

    func windowAct(_ request: AgentIntegrationWindowActRequest) async
        -> AgentIntegrationWindowActResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.windowAct(request)
    }

    func controlAct(_ request: AgentIntegrationControlActRequest) async
        -> AgentIntegrationControlActResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.controlAct(request)
    }

    func menuAct(_ request: AgentIntegrationMenuActRequest) async
        -> AgentIntegrationMenuActResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.menuAct(request)
    }

    func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.getElementText(element: element)
    }

    func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.setElementText(element: element, text: text)
    }

    func observeElements(process: AgentIntegrationProcessSerial?) async
        -> AgentIntegrationElementObservationResult {
        if let refusal = await refusal() { return .unavailable(refusal) }
        return await adapter.observeElements(process: process)
    }

    func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        if let refusal = await refusal() {
            return .init(unavailable: refusal)
        }
        return await adapter.mirrorRead(request)
    }

    func mirrorDrive(_ request: AgentIntegrationMirrorDriveRequest) async
        -> AgentIntegrationMirrorDriveResult {
        if let refusal = await refusal() {
            return .init(unavailable: refusal)
        }
        return await adapter.driveMirror(request)
    }

    /// This Mac's own log. No addressing refusal in front of it, unlike
    /// every guest lane above: there is no guest in this answer, and a
    /// selector was already refused at the face for a row that takes none.
    func hostLogTail(lines: Int?, area: String?) async
        -> AgentIntegrationHostLogTailResult {
        .completed(await MainActor.run {
            HostLogTailReader.read(lines: lines, area: area)
        })
    }

    func mirrorOpen() async -> AgentIntegrationMirrorOpenResult {
        if let refusal = await refusal() {
            return .init(unavailable: refusal)
        }
        return await adapter.openMirror()
    }
}
