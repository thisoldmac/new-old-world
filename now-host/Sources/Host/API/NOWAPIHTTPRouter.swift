import Foundation
import NOWAgentIntegration

/// The developer API route family. It owns ordinary HTTP resources and has
/// no MCP session or tool vocabulary; both adapters merely share the bounded
/// listener and parser beneath them.
final class NOWAPIHTTPRouter: @unchecked Sendable {
    static let maximumBodyBytes = 64 * 1024
    private static let renderedOperationIDs: Set<String> = [
        "api.identity", "connections.disconnect", "connections.list",
        "guests.list", "guests.status", "listener.start",
        "listener.status", "listener.stop", "operations.list",
    ]

    private let apiKey: String
    private let contractDigest: String
    private let host: any NOWAPIHostServing
    private let audit: any NOWAPIAuditSink

    init(apiKey: String, contractDigest: String,
         host: any NOWAPIHostServing,
         audit: any NOWAPIAuditSink = NOWAPINullAuditSink()) {
        self.apiKey = apiKey
        self.contractDigest = contractDigest
        self.host = host
        self.audit = audit
    }

    func respond(to request: MCPHTTPRequest) async -> MCPHTTPResponse {
        let requestID = Self.requestID(request.headers["x-request-id"])
        guard Self.constantTimeEqual(request.headers["x-api-key"] ?? "", apiKey)
        else {
            return error(401, requestID: requestID, code: "unauthorized",
                         message: "A valid X-API-Key header is required.",
                         reach: "request",
                         headers: ["WWW-Authenticate": "ApiKey"])
        }
        let path = request.target.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? request.target
        let response: MCPHTTPResponse
        switch (request.method, path) {
        case ("GET", "/api/v1"):
            response = json(200, requestID: requestID, object: [
                "name": "New Old World API",
                "apiMajor": NOWAPIOperationIDs.apiMajor,
                "schemaRevision": NOWAPIOperationIDs.schemaRevision,
                "contractDigest": contractDigest,
                "operations": "/api/v1/operations",
                "limits": [
                    "maximumHeaderBytes": 16 * 1024,
                    "maximumRequestBodyBytes": Self.maximumBodyBytes,
                ],
            ])
        case ("GET", "/api/v1/operations"):
            let rows = Self.renderedOperationIDs.sorted().map { id in
                ["operationId": id, "available": true] as [String: Any]
            }
            response = json(200, requestID: requestID,
                            object: ["operations": rows])
        case ("GET", "/api/v1/guests"):
            let guests = await host.apiGuests().map(Self.guestJSON)
            response = json(200, requestID: requestID,
                            object: ["guests": guests])
        case ("GET", let value) where value.hasPrefix("/api/v1/guests/"):
            let id = String(value.dropFirst("/api/v1/guests/".count))
            guard !id.isEmpty, let guest = await host.apiGuest(id: id) else {
                return error(404, requestID: requestID,
                             code: "guest_not_found",
                             message: "No guest has that stable ID.",
                             reach: "guest")
            }
            response = json(200, requestID: requestID,
                            object: Self.guestDetailJSON(guest))
        case ("GET", "/api/v1/listener"):
            response = json(200, requestID: requestID,
                            object: Self.listenerJSON(await host.apiListener()))
        case ("PUT", "/api/v1/listener"):
            let value = await host.apiStartListener()
            response = json(200, requestID: requestID,
                            object: Self.listenerJSON(value))
            await record(requestID, "listener.start", nil, .completed)
        case ("DELETE", "/api/v1/listener"):
            let value = await host.apiStopListener()
            response = json(200, requestID: requestID,
                            object: Self.listenerJSON(value))
            await record(requestID, "listener.stop", nil, .completed)
        case ("GET", "/api/v1/connections"):
            let values = await host.apiConnections().map(Self.connectionJSON)
            response = json(200, requestID: requestID,
                            object: ["connections": values])
        case ("DELETE", let value)
            where value.hasPrefix("/api/v1/connections/"):
            let sessionID = String(value.dropFirst(
                "/api/v1/connections/".count))
            guard GuestKey.parse(sessionID) != nil else {
                await record(requestID, "connections.disconnect", sessionID,
                             .refused)
                return error(400, requestID: requestID,
                             code: "invalid_session_id",
                             message: "Disconnect requires an exact session ID.",
                             reach: "session")
            }
            guard await host.apiDisconnect(sessionID: sessionID) else {
                await record(requestID, "connections.disconnect", sessionID,
                             .refused)
                return error(404, requestID: requestID,
                             code: "session_not_found",
                             message: "That exact session is not connected.",
                             reach: "session")
            }
            response = json(200, requestID: requestID, object: [
                "requestId": requestID.uuidString.lowercased(),
                "operationId": "connections.disconnect",
                "disposition": "completed",
                "value": ["sessionId": sessionID],
            ])
            await record(requestID, "connections.disconnect", sessionID,
                         .completed)
        default:
            response = error(404, requestID: requestID, code: "not_found",
                             message: "No API route matches this request.",
                             reach: "request")
        }
        return response
    }

    private func record(_ requestID: UUID, _ operationID: String,
                        _ target: String?,
                        _ disposition: NOWAPIAuditEvent.Disposition) async {
        await audit.record(.init(requestID: requestID,
                                 operationID: operationID,
                                 target: target,
                                 disposition: disposition))
    }

    private func error(_ status: Int, requestID: UUID, code: String,
                       message: String, reach: String,
                       headers: [String: String] = [:]) -> MCPHTTPResponse {
        json(status, requestID: requestID, object: [
            "requestId": requestID.uuidString.lowercased(),
            "error": ["code": code, "message": message, "reach": reach],
        ], headers: headers)
    }

    private func json(_ status: Int, requestID: UUID,
                      object: [String: Any],
                      headers: [String: String] = [:]) -> MCPHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        return .init(status: status, headers: headers.merging([
            "Content-Type": "application/json",
            "X-Request-Id": requestID.uuidString.lowercased(),
            "Cache-Control": "no-store",
        ], uniquingKeysWith: { first, _ in first }), body: body)
    }

    private static func requestID(_ raw: String?) -> UUID {
        raw.flatMap(UUID.init(uuidString:)) ?? UUID()
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,
                                   .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func guestJSON(_ guest: NOWAPIGuestSummary)
        -> [String: Any] {
        var object: [String: Any] = [
            "id": guest.id, "displayName": guest.displayName,
            "connected": guest.connected,
        ]
        object["sessionId"] = guest.sessionID
        object["connectedAt"] = guest.connectedAt.map(dateString)
        return object
    }

    private static func guestDetailJSON(_ guest: NOWAPIGuestDetail)
        -> [String: Any] {
        var object = guestJSON(guest.summary)
        object["name"] = guest.name
        object["version"] = guest.version
        object["build"] = guest.build
        object["operatingSystem"] = guest.operatingSystem
        object["agentAccess"] = guest.agentAccess
        object["capabilities"] = guest.capabilities
        return object
    }

    private static func listenerJSON(_ listener: NOWAPIListenerSummary)
        -> [String: Any] {
        var object: [String: Any] = [
            "state": listener.state,
            "desiredPorts": listener.desiredPorts.map(Int.init),
            "boundPorts": listener.boundPorts.map(Int.init),
        ]
        object["failure"] = listener.failure
        return object
    }

    private static func connectionJSON(_ connection: NOWAPIConnectionSummary)
        -> [String: Any] {
        ["guest": ["id": connection.guestID,
                    "sessionId": connection.sessionID],
         "connectedAt": dateString(connection.connectedAt)]
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0)
                ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}
