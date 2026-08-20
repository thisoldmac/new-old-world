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
}

struct NOWAPIAuditEvent: Equatable, Sendable {
    enum Disposition: String, Sendable { case completed, refused, failed }
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
