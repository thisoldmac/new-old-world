import Foundation
import NOWAgentIntegration

/// The thin API view over host-owned connection state. It exposes deliberate
/// DTOs rather than serializing `GuestListener`, registry records, or socket
/// objects, so adding a private field to those owners cannot enlarge v1.
@MainActor
final class NOWAPIHostAdapter: NOWAPIHostServing {
    private let listener: GuestListener
    private let settings: SettingsModel
    private let commands: NOWAPIConsoleCommandService
    private let files: NOWAPIFileTransferService?
    private let operationService: NOWService?
    private let operationClient: AgentIntegrationClient?

    init(listener: GuestListener, settings: SettingsModel,
         guestFiles: GuestFilesCommandService? = nil,
         agentIntegration: AgentIntegrationHostAdapter? = nil) {
        self.listener = listener
        self.settings = settings
        commands = NOWAPIConsoleCommandService(driver: listener)
        if let guestFiles, let agentIntegration {
            files = NOWAPIFileTransferService(driver: NOWAPIHostFileDriver(
                listener: listener, files: guestFiles,
                adapter: agentIntegration))
            operationService = NOWService(
                face: .api, audit: NOWAPIProjectionAuditSink())
            operationClient = HostAgentIntegrationClient(
                adapter: agentIntegration, guestFiles: guestFiles)
        } else {
            files = nil
            operationService = nil
            operationClient = nil
        }
    }

    func apiGuests() -> [NOWAPIGuestSummary] {
        let live = listener.guests.map { guest in
            NOWAPIGuestSummary(
                id: guest.id.slug, sessionID: guest.sessionID,
                displayName: guest.label, connected: true,
                connectedAt: guest.connectedAt)
        }
        let liveIDs = Set(live.map(\.id))
        let known: [NOWAPIGuestSummary] = listener.registry.known.compactMap {
            record -> NOWAPIGuestSummary? in
            guard !liveIDs.contains(record.id.slug) else { return nil }
            return NOWAPIGuestSummary(
                id: record.id.slug, sessionID: nil,
                displayName: record.displayName ?? record.lastName,
                connected: false, connectedAt: nil)
        }
        return live + known
    }

    func apiGuest(id: String) -> NOWAPIGuestDetail? {
        if let guest = listener.guests.first(where: { $0.id.slug == id }) {
            let health = listener.health(for: guest.key)
            let capabilities = listener.familyObservations(for: guest.key)
                .filter { $0.value.served }.map(\.key).sorted()
            return .init(
                summary: .init(id: guest.id.slug,
                               sessionID: guest.sessionID,
                               displayName: guest.label,
                               connected: true,
                               connectedAt: guest.connectedAt),
                name: guest.name, version: guest.version,
                build: guest.build,
                operatingSystem: guest.operatingSystem,
                agentAccess: health?.guestAgentAccess.map(String.init(describing:)),
                capabilities: capabilities)
        }
        guard let record = listener.registry.known.first(where: {
            $0.id.slug == id
        }) else { return nil }
        return .init(
            summary: .init(id: record.id.slug, sessionID: nil,
                           displayName: record.displayName ?? record.lastName,
                           connected: false, connectedAt: nil),
            name: record.lastName, version: nil, build: nil,
            operatingSystem: nil, agentAccess: nil, capabilities: [])
    }

    func apiListener() -> NOWAPIListenerSummary {
        let state: String
        var failure: String?
        switch listener.state {
        case .idle: state = "idle"
        case .listening: state = "listening"
        case .connected: state = "connected"
        case .failed(let reason):
            state = "failed"
            failure = reason
        }
        return .init(
            state: state,
            desiredPorts: listener.registry.portsToBind(base: settings.listenPort),
            boundPorts: listener.boundPorts,
            failure: failure)
    }

    func apiStartListener() -> NOWAPIListenerSummary {
        listener.start(
            ports: listener.registry.portsToBind(base: settings.listenPort))
        return apiListener()
    }

    func apiStopListener() -> NOWAPIListenerSummary {
        listener.stop()
        return apiListener()
    }

    func apiConnections() -> [NOWAPIConnectionSummary] {
        listener.guests.map {
            .init(guestID: $0.id.slug, sessionID: $0.sessionID,
                  connectedAt: $0.connectedAt)
        }
    }

    func apiDisconnect(sessionID: String) -> Bool {
        guard let key = GuestKey.parse(sessionID) else { return false }
        return listener.disconnect(key)
    }

    func apiEventStream() -> NOWAPISSEStream {
        NOWAPISSEStream(bus: listener.events)
    }

    func apiExecuteCommand(
        guestID: String, expectedSessionID: String,
        request: NOWAPIConsoleCommandRequest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void
    ) {
        commands.execute(guestID: guestID, expectedSessionID: expectedSessionID,
                         request: request,
                         completion: completion)
    }

    func apiFiles() -> NOWAPIFileTransferService? { files }

    func apiInvokeOperation(
        operationID: String, guest: String?, argumentsJSON: Data?
    ) async -> NOWAPIOperationInvocationOutcome {
        guard let capability = NOWOperationInventory.projectionCapability(
                forPublicOperationID: operationID),
              let operationService, let operationClient else {
            return .init(disposition: .failed, valueJSON: nil,
                         attachmentJSON: nil,
                         errorCode: "operation_unavailable",
                         errorMessage: "That public operation is unavailable on this host.")
        }
        let arguments = argumentsJSON.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        }
        let client = operationClient.addressing(guest)
        let outcome = await operationService.invokeProjection(
            named: capability.rawValue,
            arguments: .init(raw: arguments), guest: guest, through: client)
        switch outcome {
        case .value(let value):
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try value.encoded(using: encoder)
                var attachmentJSON: Data?
                if case .image(let bytes, let mimeType)? = value.attachment {
                    attachmentJSON = try JSONSerialization.data(
                        withJSONObject: [
                            "mediaType": mimeType,
                            "base64": bytes.base64EncodedString(),
                        ], options: [.sortedKeys])
                }
                let disposition: NOWAPIOperationInvocationOutcome.Disposition
                switch value.disposition {
                case .completed: disposition = .completed
                case .refused: disposition = .refused
                case .unavailable: disposition = .unavailable
                case .failed: disposition = .failed
                }
                return .init(disposition: disposition, valueJSON: data,
                             attachmentJSON: attachmentJSON,
                             errorCode: nil, errorMessage: nil)
            } catch {
                return .init(disposition: .failed, valueJSON: nil,
                             attachmentJSON: nil,
                             errorCode: "response_encoding_failed",
                             errorMessage: "The operation result could not be encoded.")
            }
        case .invalidArguments(let message):
            return .init(disposition: .refused, valueJSON: nil,
                         attachmentJSON: nil,
                         errorCode: "invalid_arguments", errorMessage: message)
        case .deniedByConsent(let denial):
            return .init(disposition: .refused, valueJSON: nil,
                         attachmentJSON: nil,
                         errorCode: "guest_consent_refused",
                         errorMessage: denial.message)
        case nil:
            return .init(disposition: .failed, valueJSON: nil,
                         attachmentJSON: nil,
                         errorCode: "operation_unavailable",
                         errorMessage: "That public operation is unavailable on this host.")
        }
    }
}

private struct NOWAPIProjectionAuditSink: HostProjectionAuditSink {
    func record(_ event: HostProjectionAuditEvent) async {
        // The HTTP adapter records the public operation ID and disposition.
        // Dispatch still requires an explicit sink so no face can bypass the
        // audited service boundary by construction.
    }
}
