import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/// The agent surface, whole, in front of a REAL classic Mac.
///
/// The two metal suites that use it (`MetalCaptureProjectionTests`,
/// `MetalAddressingTests`) both need the same stack, and it is deliberately
/// the shipped one at every layer except the last:
///
/// * a real `GuestListener` on the metal port — the guest dials it,
/// * the real `AgentIntegrationHostAdapter` over that listener, which is
///   what the app itself puts behind its local socket,
/// * the real `AgentIntegrationLocalServer` on a private endpoint, so the
///   16 KiB request/response cap is enforced by the code that enforces it in
///   production rather than by a constant read in a test,
/// * the real `AgentIntegrationLocalClient` in front of it.
///
/// **Only the dispatch in `handle` is written here**, and it mirrors
/// `App.swift`'s. That is the one honest gap: it is not the app's own
/// `switch`, so a divergence between the two would not be caught by these
/// suites. It is duplicated rather than extracted because extracting it
/// would be a change to the seam, and these gates exist to measure the seam
/// as it stands.
///
/// It runs against a temporary endpoint under `/tmp` rather than the real
/// per-user one for the reason `GuestRegistry` keeps its store in memory by
/// default: a metal run must not be able to take the socket out from under
/// the human's own running app.
@MainActor
final class MetalAgentLocalSurface {
    let listener: GuestListener
    let adapter: AgentIntegrationHostAdapter
    let port: UInt16
    let endpoint: AgentIntegrationEndpoint

    /// The largest local response this run encoded, and how many there
    /// were. Measured with the same codec call the server makes, so it is
    /// the shipped bound rather than a restatement of it — the number that
    /// says whether a screen really had to be paged.
    private(set) var largestResponseBytes = 0
    private(set) var responsesEncoded = 0
    /// Every selector the host was asked about, in order. A gate that
    /// claims a machine was named has to be able to show that the host saw
    /// the name.
    private(set) var selectorsSeen: [String?] = []

    private let root: URL
    private var server: AgentIntegrationLocalServer?

    init(port: UInt16, identityName: String = "Metal Harness") {
        self.port = port
        listener = GuestListener(identity: .init(
            version: "0.1-metal-agent", name: identityName))
        adapter = AgentIntegrationHostAdapter(listener: listener)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-metal-agent-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        endpoint = AgentIntegrationEndpoint(
            directoryURL: root,
            socketURL: root.appendingPathComponent("host.sock"))
    }

    /// Binds the local socket and starts listening for the guest.
    ///
    /// The port guard has already run by the time this is called; what this
    /// adds is `requireItIsListening`, which turns the harness's single most
    /// misleading failure — a two-minute wait blamed on the Macintosh — into
    /// the bind error it always was.
    func start(file: StaticString = #filePath, line: UInt = #line) throws {
        let server = try AgentIntegrationLocalServer(
            endpoint: endpoint,
            handler: { [self] request in await handle(request) })
        try server.start()
        self.server = server
        listener.start(port: port)
        try MetalMachineGuard.requireItIsListening(
            listener.state, port: port, file: file, line: line)
    }

    func stop() {
        server?.stop()
        server = nil
        listener.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Waiting for the machine

    /// Waits for the guest to dial in, and FAILS rather than skips: with
    /// `NOW_METAL` set, a gate that reads green having never reached a
    /// machine is worse than no gate (AGENTS.md).
    ///
    /// The window is generous on purpose. The guest retries its dial every
    /// 30 s, so a run started a moment after a retry waits out most of one
    /// before anything happens, and reading that as a dead machine is how a
    /// working PowerBook gets reported broken.
    @discardableResult
    func waitForGuest(_ seconds: TimeInterval = 120,
                      file: StaticString = #filePath,
                      line: UInt = #line) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected(let name) = listener.state,
               listener.health != nil {
                // Let the handshake settle before driving it.
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("""
            No guest dialled in on port \(port) within \(Int(seconds))s. \
            NOW_METAL is set, so this is a failure and not a skip. The guest \
            retries every 30 s, so check that the machine is running a build \
            whose host setting points at this Mac and this port.
            """, file: file, line: line)
        throw XCTSkip("no guest")
    }

    // MARK: - Which machine answered

    /// Refuses to measure anything until the guest on the wire is the one
    /// this run is about.
    ///
    /// **The version string cannot do this job.** `PRODUCT_VERSION` is
    /// `0.1.0` in the current source and was `0.1.0` on the build that was
    /// on this machine before it — two different builds wearing one number —
    /// so a version check here would read green against a stale guest. Two
    /// facts are asserted instead:
    ///
    /// * the **address the host observed**, which the guest has no say in
    ///   (`GuestAddress` is taken off the accepted connection before a byte
    ///   of the guest's own account of itself is read). This is what
    ///   separates the PowerBook from every QEMU guest on this Mac, all of
    ///   which arrive from loopback.
    /// * a **capability**, from the guest's own `help` table: the verbs a
    ///   Carbon PPC guest serves and the 68K guest does not. A capability
    ///   is the right kind of claim because it is what the run goes on to
    ///   use.
    ///
    /// Returns the verb table, which is worth printing whatever happens.
    @discardableResult
    func requireTheBuildUnderTest(
        servingAnyOf wanted: Set<String> = ["gestalt", "putstat", "catsearch"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        if let expected = ProcessInfo.processInfo
            .environment["NOW_METAL_MACHINE"], !expected.isEmpty {
            let addresses = listener.guests.map(\.address.text)
            guard addresses.contains(expected) else {
                XCTFail("""
                    The guest on this wire arrived from \
                    \(addresses.joined(separator: ", ")), not from \
                    \(expected). That is a different machine answering this \
                    listener — most likely another session's VM, all of \
                    which reach this Mac from loopback. Nothing this run \
                    measured would be about \(expected).
                    """, file: file, line: line)
                throw XCTSkip("wrong machine on the wire")
            }
        } else {
            print("=== NOW_METAL_MACHINE unset, so which MACHINE answered "
                  + "could not be checked — only which guest.")
        }

        var help: CommandResult?
        listener.runCommand("help", line: "") { help = $0 }
        let deadline = Date().addingTimeInterval(30)
        while help == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let reply = try XCTUnwrap(help, "the guest did not answer `help`",
                                  file: file, line: line)
        let verbs = (reply.output?["help"] ?? []).compactMap(\.first)
        guard !wanted.isDisjoint(with: Set(verbs)) else {
            XCTFail("""
                The guest on this wire serves none of \
                \(wanted.sorted().joined(separator: ", ")), so it is not the \
                Carbon PPC build under test — an older or 68K guest found \
                this listener. Give this run a port nothing else is dialling \
                with NOW_METAL_PORT. Verbs seen: \
                \(verbs.sorted().joined(separator: ", "))
                """, file: file, line: line)
            throw XCTSkip("wrong build on the wire")
        }
        return verbs
    }

    // MARK: - Clients

    /// A client on the shipped path, optionally naming a machine.
    func localClient(addressing selector: String? = nil) throws
        -> AgentIntegrationLocalClient {
        try AgentIntegrationLocalClient(endpoint: endpoint)
            .addressing(selector)
    }

    /// What a projection is handed. Mirrors the companion's
    /// `SocketAgentIntegrationClient` for the calls these gates make and
    /// answers "no host" to the rest, so a projection cannot reach a lane
    /// this rig has not thought about.
    func projectionClient(addressing selector: String? = nil) throws
        -> AgentIntegrationClient {
        MetalLocalProjectionClient(client: try localClient(addressing: selector))
    }

    // MARK: - The dispatch, mirroring App.swift

    private func handle(_ request: AgentIntegrationLocalRequest) async
        -> AgentIntegrationLocalResult {
        selectorsSeen.append(request.guestSelector)
        /* Addressing first, and it is an assertion rather than a switch: a
           caller naming a machine this host is not driving is refused with
           the roster, never answered by whichever guest happened to be
           there. */
        if let refusal = adapter.addressingRefusal(request.guestSelector) {
            return record(.notAddressed(refusal))
        }
        switch request.operation {
        case .projects:
            guard let project = request.projectRequest else {
                return record(.projects(.hostUnavailable))
            }
            return record(.projects(adapter.projects(project)))
        case .chats:
            guard let chat = request.chatRequest else {
                return record(.chats(.unavailable(.host)))
            }
            return record(.chats(adapter.chats(chat)))
        case .development:
            guard let development = request.developmentRequest else {
                return record(.development(.unavailable(.host)))
            }
            return record(.development(
                await adapter.development(development)))
        case .sessionHealth:
            return record(.sessionHealth(adapter.sessionHealth()))
        case .sessionCapabilities:
            return record(.sessionCapabilities(
                await adapter.sessionCapabilities(
                    probeCostly: request.probeCostly ?? false)))
        case .listProcesses:
            return record(.processList(await adapter.processList()))
        case .capture:
            if request.captureAbandon == true {
                return record(.capture(adapter.abandonCapture()))
            }
            if let captureID = request.captureID,
               let offset = request.captureOffset {
                return record(.capture(adapter.capturePage(
                    captureID: captureID, offset: offset)))
            }
            guard let depth = request.captureDepth else {
                return record(.capture(.refused(.init(
                    code: "now-capture-request-invalid",
                    message: "The capture request named no depth, page or "
                        + "abandon"))))
            }
            return record(.capture(await adapter.capture(depth: depth)))
        case .launchSoftware, .requestQuit, .transferApprovedArtifact,
             .guestFilesCapabilities, .guestFilesList, .guestFilesStat,
             .guestFilesUploadBegin, .guestFilesUploadAppend,
             .guestFilesUploadCommit, .audit,
             /* P1a's eleven, refused here for the same reason and one more:
                on this rig they are not merely out of scope, they are
                unserved everywhere — so a gate that let one through would
                be measuring nothing. */
             .census, .softwareInventory, .guestFileDownload,
             .bringToFront, .guestFileMutation, .transferCancel,
             .guestLogTail,
             /* And the HOST's own log, refused here for a reason unlike
                every neighbour's: it is served on the real host and reads
                nothing from a guest at all. This rig is not the app, so its
                ring is not the log anybody wants — answering out of it
                would be the exact substitution `SocketAgentIntegrationClient`
                refuses to make. */
             .hostLogTail,
             .machineFacts, .developmentEnvironment,
             .catalogSearch, .revealItem,
             .diagnostics, .mirrorRead, .mirrorDrive,
             /* And opening the Mirror, refused here for a reason unlike
                every neighbour's: this rig has no window layer at all, so
                there is nothing for it to open. On the real host it is
                served; here the honest answer is that this surface cannot. */
             .mirrorOpen,
             /* And the bracket, refused for a reason of its own on TOP of
                those: it is the one operation that would not end when the
                gate did. A rig that opened a stream on the person's
                PowerBook and then finished its test run would leave the
                machine capturing its own screen, and the ownership rule
                that ends such a bracket lives in the host app's control,
                not here. */
             .stream,
             /* And the act lane, which belongs in this list more plainly
                than anything already in it. These five reach INSIDE an
                application on the person's own PowerBook and answer its
                FindWindow, its TrackControl, its MenuSelect — a rig that
                let one through could close a window over unsaved work
                while its owner was typing in it. `textget` changes
                nothing and is refused with the other four anyway: the
                exemption would be a fourth reading of "which acts are
                safe", and this rig is not where that question is
                answered. */
             .windowAct, .controlAct, .menuAct, .textGet, .textSet,
             /* And the walk that mints what those five address. It changes
                nothing — so it is here for the OTHER reason in this list
                rather than the safety one: it is unserved by this rig, and
                a gate that let it through would be measuring nothing. It
                also costs the machine real work, binding a process through
                the anchor oracle and reading foreign memory window by
                window, which is not what a capture/addressing rig is for. */
             .observeElements:
            /* Every operation that could CHANGE the machine, refused by
               this rig rather than served. A capture gate has no business
               being able to move a file on somebody's PowerBook, and the
               person sitting at it did not agree to that. */
            return record(.sessionHealth(.unavailable(.init(
                code: "now-metal-rig-refuses",
                message: "\(request.operation.rawValue) is not served by "
                    + "the metal capture/addressing rig"))))
        }
    }

    /// Encodes the response the way the server is about to, purely to
    /// measure it. The server's own `encode` is what enforces the cap — an
    /// oversize response is never written, and the caller sees a timeout —
    /// so this is a record of a bound that is already being kept, not a
    /// second implementation of it.
    private func record(_ result: AgentIntegrationLocalResult)
        -> AgentIntegrationLocalResult {
        let response: AgentIntegrationLocalResponse
        switch result {
        case .notAddressed(let unavailable):
            response = .init(requestID: UUID(), notAddressed: unavailable)
        case .capture(let capture):
            response = .init(requestID: UUID(), captureResult: capture)
        case .sessionHealth(let health):
            response = .init(requestID: UUID(), result: health)
        case .processList(let processes):
            response = .init(requestID: UUID(), processListResult: processes)
        case .sessionCapabilities(let capabilities):
            response = .init(requestID: UUID(),
                             sessionCapabilitiesResult: capabilities)
        default:
            return result
        }
        if let encoded = try? AgentIntegrationLocalCodec.encode(response) {
            largestResponseBytes = max(largestResponseBytes, encoded.count)
            responsesEncoded += 1
        }
        return result
    }
}

/// A projection's view of the rig: the shipped local client, with the
/// same error mapping the companion uses.
private struct MetalLocalProjectionClient: AgentIntegrationClient {
    let client: AgentIntegrationLocalClient

    func addressing(_ selector: String?) -> AgentIntegrationClient {
        MetalLocalProjectionClient(client: client.addressing(selector))
    }

    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        do {
            return try await client.requestCapture(
                depth: depth ?? AgentIntegrationCapturePolicy.defaultDepth)
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        do {
            return try await client.fetchCapturePage(
                captureID: captureID, offset: offset)
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    func abandonGuestCapture() async -> AgentIntegrationCaptureResult {
        do {
            return try await client.abandonCapture()
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        do {
            return try await client.sessionHealth()
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    func listProcesses() async -> AgentIntegrationProcessListResult {
        do {
            return try await client.listProcesses()
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        do {
            return try await client.sessionCapabilities(
                probeCostly: probeCostly)
        } catch {
            return .unavailable(Self.unavailable(for: error))
        }
    }

    // MARK: - Lanes this rig does not open

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

    /// The companion's mapping, kept identical on purpose: a refusal
    /// arrives as itself and a transport fault as a transport fault.
    private static func unavailable(for error: Error)
        -> AgentIntegrationUnavailable {
        guard let local = error as? AgentIntegrationLocalTransportError else {
            return .init(code: "now-host-communication-failed",
                         message: "New Old World host communication failed")
        }
        switch local {
        case .incompatibleProtocol(let expected, let actual):
            return .init(code: "now-host-companion-incompatible",
                         message: "Host protocol \(actual) does not match companion protocol \(expected)")
        case .notAddressed(let refusal):
            return refusal
        case .notImplemented(let pending):
            return pending
        case .attemptRefused(let code, let message):
            return .init(code: code, message: message)
        case .hostUnavailable:
            return .host
        case .unsafeEndpoint:
            return .init(code: "now-host-endpoint-invalid",
                         message: "New Old World host endpoint is not "
                             + "trustworthy")
        case .invalidMessage, .messageTooLarge:
            return .init(code: "now-host-invalid-response",
                         message: "New Old World host returned an invalid "
                             + "response")
        case .io:
            return .init(code: "now-host-communication-failed",
                         message: "New Old World host communication failed")
        }
    }
}
