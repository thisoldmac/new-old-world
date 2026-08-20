import Foundation

struct NOWAPIGuestSummary: Equatable, Sendable {
    let id: String
    let sessionID: String?
    let displayName: String
    let connected: Bool
    let connectedAt: Date?
}

struct NOWAPIGuestDetail: Equatable, Sendable {
    let summary: NOWAPIGuestSummary
    let name: String
    let version: String?
    let build: String?
    let operatingSystem: String?
    let agentAccess: String?
    let capabilities: [String]
}

struct NOWAPIListenerSummary: Equatable, Sendable {
    let state: String
    let desiredPorts: [UInt16]
    let boundPorts: [UInt16]
    var failure: String? = nil
}

struct NOWAPIConnectionSummary: Equatable, Sendable {
    let guestID: String
    let sessionID: String
    let connectedAt: Date
}

@MainActor
protocol NOWAPIHostServing: AnyObject {
    func apiGuests() -> [NOWAPIGuestSummary]
    func apiGuest(id: String) -> NOWAPIGuestDetail?
    func apiListener() -> NOWAPIListenerSummary
    func apiStartListener() -> NOWAPIListenerSummary
    func apiStopListener() -> NOWAPIListenerSummary
    func apiConnections() -> [NOWAPIConnectionSummary]
    func apiDisconnect(sessionID: String) -> Bool
    func apiEventStream() -> NOWAPISSEStream?
    func apiExecuteCommand(
        guestID: String, expectedSessionID: String,
        request: NOWAPIConsoleCommandRequest,
        completion: @escaping (NOWAPIConsoleCommandOutcome) -> Void)
    func apiInvokeOperation(
        operationID: String, guest: String?, argumentsJSON: Data?
    ) async -> NOWAPIOperationInvocationOutcome
}

struct NOWAPIOperationInvocationOutcome: Sendable {
    enum Disposition: String, Sendable {
        case completed, refused, unavailable, failed
    }
    let disposition: Disposition
    let valueJSON: Data?
    let attachmentJSON: Data?
    let errorCode: String?
    let errorMessage: String?
}

extension NOWAPIHostServing {
    func apiInvokeOperation(
        operationID: String, guest: String?, argumentsJSON: Data?
    ) async -> NOWAPIOperationInvocationOutcome {
        .init(disposition: .failed, valueJSON: nil, attachmentJSON: nil,
              errorCode: "operation_service_unavailable",
              errorMessage: "The neutral operation service is unavailable.")
    }
}

struct NOWAPIConsoleCommandRequest: Equatable, Sendable {
    let command: String
    let arguments: [String: CommandArg]?
    let argumentLine: String?
}

struct NOWAPIConsoleCommandOutcome: Equatable, Sendable {
    enum Disposition: String, Sendable {
        case completed
        case invalid
        case unadvertised
        case timedOut = "timed-out"
        case disconnected
        case refused
        case failed
    }

    struct Failure: Equatable, Sendable {
        let code: String
        let message: String
        let reach: String
    }

    let guestID: String
    let sessionID: String?
    let disposition: Disposition
    let output: [String: [[String]]]?
    let outputObjects: [String: JSONValue]?
    let error: Failure?
}

struct NOWAPIAuditEvent: Equatable, Sendable {
    enum Disposition: String, Sendable {
        case completed
        case refused
        case denied
        case failed
    }
    let requestID: UUID
    let operationID: String
    let target: String?
    let disposition: Disposition
}

protocol NOWAPIAuditSink: Sendable {
    func record(_ event: NOWAPIAuditEvent) async
}

struct NOWAPINullAuditSink: NOWAPIAuditSink {
    func record(_ event: NOWAPIAuditEvent) async {}
}
