import Foundation
import NOWAgentIntegration

/// The developer API route family. It owns ordinary HTTP resources and has
/// no MCP session or tool vocabulary; both adapters merely share the bounded
/// listener and parser beneath them.
final class NOWAPIHTTPRouter: @unchecked Sendable {
    static let maximumBodyBytes = 64 * 1024
    private static let renderedOperationIDs: Set<String> = [
        "api.identity", "commands.execute", "connections.disconnect", "connections.list",
        "files.get", "files.list", "files.mutate", "files.put", "files.stat",
        "guests.list", "guests.status", "listener.start",
        "listener.status", "listener.stop", "operations.list",
        "transfers.cancel", "transfers.commit", "transfers.content",
        "transfers.get", "transfers.list", "transfers.uploadChunk",
    ]

    private let apiKey: String
    private let contractDigest: String
    private let host: any NOWAPIHostServing
    private let audit: any NOWAPIAuditSink
    private let files: NOWAPIFileTransferService?

    init(apiKey: String, contractDigest: String,
         host: any NOWAPIHostServing,
         audit: any NOWAPIAuditSink = NOWAPINullAuditSink(),
         files: NOWAPIFileTransferService? = nil) {
        self.apiKey = apiKey
        self.contractDigest = contractDigest
        self.host = host
        self.audit = audit
        self.files = files
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
        case ("GET", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/files"):
            guard let files else { return unavailableFiles(requestID) }
            let id = String(value.dropFirst("/api/v1/guests/".count)
                .dropLast("/files".count))
            guard let query = Self.query(request.target) else {
                return invalidQuery(requestID)
            }
            let cursor = query["cursor"].flatMap(Int.init)
            do {
                let result = try await files.listFiles(
                    guestID: id, path: query["path"] ?? "", cursor: cursor)
                response = codable(200, requestID: requestID, result)
                await record(requestID, "files.list", id, .completed)
            } catch let problem {
                return fileProblem(problem, requestID)
            }
        case ("GET", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/files/stat"):
            guard let files else { return unavailableFiles(requestID) }
            let id = String(value.dropFirst("/api/v1/guests/".count)
                .dropLast("/files/stat".count))
            guard let query = Self.query(request.target) else {
                return invalidQuery(requestID)
            }
            do {
                let result = try await files.statFile(
                    guestID: id, path: query["path"] ?? "")
                response = codable(200, requestID: requestID, result)
                await record(requestID, "files.stat", id, .completed)
            } catch let problem {
                return fileProblem(problem, requestID)
            }
        case ("POST", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/files/mutations"):
            let id = String(value.dropFirst("/api/v1/guests/".count)
                .dropLast("/files/mutations".count))
            guard let files else {
                await record(requestID, "files.mutate", id, .failed)
                return unavailableFiles(requestID)
            }
            guard let requestValue = Self.mutation(request.body) else {
                await record(requestID, "files.mutate", id, .refused)
                return error(400, requestID: requestID,
                             code: "file_mutation_invalid",
                             message: "The file mutation shape is invalid.",
                             reach: "request")
            }
            do {
                let result = try await files.mutateFile(
                    guestID: id, request: requestValue)
                response = codable(200, requestID: requestID, result)
                await record(requestID, "files.mutate", id,
                             Self.auditDisposition(result))
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "files.mutate", id)
            }
        case ("POST", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/transfers/uploads"):
            let id = String(value.dropFirst("/api/v1/guests/".count)
                .dropLast("/transfers/uploads".count))
            guard let files else {
                await record(requestID, "files.put", id, .failed)
                return unavailableFiles(requestID)
            }
            guard let upload = try? JSONDecoder().decode(
                AgentIntegrationGuestFileUploadBegin.self,
                from: request.body) else {
                await record(requestID, "files.put", id, .refused)
                return error(400, requestID: requestID,
                             code: "upload_invalid",
                             message: "Upload metadata is invalid.",
                             reach: "request")
            }
            do {
                let transfer = try await files.beginUpload(
                    guestID: id, request: upload)
                response = codable(201, requestID: requestID, transfer)
                await record(requestID, "files.put", id,
                             Self.auditDisposition(transfer))
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "files.put", id)
            }
        case ("POST", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/transfers/downloads"):
            let id = String(value.dropFirst("/api/v1/guests/".count)
                .dropLast("/transfers/downloads".count))
            guard let files else {
                await record(requestID, "files.get", id, .failed)
                return unavailableFiles(requestID)
            }
            guard let object = try? JSONSerialization.jsonObject(
                    with: request.body) as? [String: Any],
                  object.count == 1, let filePath = object["path"] as? String
            else {
                await record(requestID, "files.get", id, .refused)
                return error(400, requestID: requestID,
                             code: "download_invalid",
                             message: "Download requires one path.",
                             reach: "request")
            }
            do {
                let transfer = try await files.download(
                    guestID: id, path: filePath)
                response = codable(200, requestID: requestID, transfer)
                await record(requestID, "files.get", id,
                             Self.auditDisposition(transfer))
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "files.get", id)
            }
        case ("GET", "/api/v1/transfers"):
            guard let files else { return unavailableFiles(requestID) }
            response = codable(200, requestID: requestID,
                               ["transfers": await files.listTransfers()])
        case ("PUT", let value)
            where value.hasPrefix("/api/v1/transfers/")
                && value.hasSuffix("/content"):
            let raw = String(value.dropFirst("/api/v1/transfers/".count)
                .dropLast("/content".count))
            let parsedID = UUID(uuidString: raw)
            let target = parsedID.map(Self.transferTarget)
            guard let files else {
                await record(requestID, "transfers.uploadChunk", target,
                             .failed)
                return unavailableFiles(requestID)
            }
            guard let query = Self.query(request.target) else {
                await record(requestID, "transfers.uploadChunk", target,
                             .refused)
                return invalidQuery(requestID)
            }
            guard let id = parsedID,
                  let offset = query["offset"].flatMap(Int.init) else {
                await record(requestID, "transfers.uploadChunk", target,
                             .refused)
                return error(400, requestID: requestID,
                             code: "upload_chunk_invalid",
                             message: "Upload content requires a transfer ID and offset.",
                             reach: "request")
            }
            do {
                let transfer = try await files.appendUpload(
                    transferID: id, offset: offset, bytes: request.body)
                response = codable(200, requestID: requestID, transfer)
                await record(requestID, "transfers.uploadChunk",
                             Self.transferTarget(id),
                             Self.auditDisposition(transfer))
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "transfers.uploadChunk",
                    Self.transferTarget(id))
            }
        case ("POST", let value)
            where value.hasPrefix("/api/v1/transfers/")
                && value.hasSuffix("/commit"):
            let raw = String(value.dropFirst("/api/v1/transfers/".count)
                .dropLast("/commit".count))
            let parsedID = UUID(uuidString: raw)
            let target = parsedID.map(Self.transferTarget)
            guard let files else {
                await record(requestID, "transfers.commit", target, .failed)
                return unavailableFiles(requestID)
            }
            guard let id = UUID(uuidString: raw) else {
                await record(requestID, "transfers.commit", nil, .refused)
                return error(400, requestID: requestID,
                             code: "transfer_id_invalid",
                             message: "Commit requires a transfer ID.",
                             reach: "request")
            }
            do {
                let transfer = try await files.commitUpload(transferID: id)
                response = codable(200, requestID: requestID, transfer)
                await record(requestID, "transfers.commit",
                             Self.transferTarget(id),
                             Self.auditDisposition(transfer))
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "transfers.commit",
                    Self.transferTarget(id))
            }
        case ("GET", let value)
            where value.hasPrefix("/api/v1/transfers/")
                && value.hasSuffix("/content"):
            guard let files else { return unavailableFiles(requestID) }
            let raw = String(value.dropFirst("/api/v1/transfers/".count)
                .dropLast("/content".count))
            guard let id = UUID(uuidString: raw) else {
                return error(400, requestID: requestID,
                             code: "transfer_id_invalid",
                             message: "Content requires a transfer ID.",
                             reach: "request")
            }
            do {
                let (url, byteCount, contentType) =
                    try await files.content(id: id)
                response = .init(status: 200, headers: [
                    "Content-Type": contentType,
                    "X-Request-Id": requestID.uuidString.lowercased(),
                    "Cache-Control": "no-store",
                ], bodyFileURL: url, bodyFileLength: byteCount)
            } catch let problem {
                return fileProblem(problem, requestID)
            }
        case ("DELETE", let value)
            where value.hasPrefix("/api/v1/transfers/"):
            let raw = String(value.dropFirst("/api/v1/transfers/".count))
            let parsedID = UUID(uuidString: raw)
            let target = parsedID.map(Self.transferTarget)
            guard let files else {
                await record(requestID, "transfers.cancel", target, .failed)
                return unavailableFiles(requestID)
            }
            guard let id = UUID(uuidString: raw) else {
                await record(requestID, "transfers.cancel", nil, .refused)
                return error(400, requestID: requestID,
                             code: "transfer_id_invalid",
                             message: "Cancel requires a transfer ID.",
                             reach: "request")
            }
            do {
                let transfer = try await files.cancel(id: id)
                response = codable(200, requestID: requestID, transfer)
                await record(requestID, "transfers.cancel",
                             Self.transferTarget(id), .completed)
            } catch let problem {
                return await auditedFileProblem(
                    problem, requestID, "transfers.cancel",
                    Self.transferTarget(id))
            }
        case ("GET", let value)
            where value.hasPrefix("/api/v1/transfers/"):
            guard let files else { return unavailableFiles(requestID) }
            let raw = String(value.dropFirst("/api/v1/transfers/".count))
            guard let id = UUID(uuidString: raw),
                  let transfer = await files.transfer(id: id) else {
                return error(404, requestID: requestID,
                             code: "transfer_not_found",
                             message: "No transfer has that ID.",
                             reach: "transfer")
            }
            response = codable(200, requestID: requestID, transfer)
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
        case ("POST", let value)
            where value.hasPrefix("/api/v1/guests/")
                && value.hasSuffix("/commands"):
            let prefix = "/api/v1/guests/"
            let id = String(value.dropFirst(prefix.count)
                .dropLast("/commands".count))
            guard !id.isEmpty, let guest = await host.apiGuest(id: id) else {
                await record(requestID, "commands.execute", id, .refused)
                return error(404, requestID: requestID,
                             code: "guest_not_found",
                             message: "No guest has that stable ID.",
                             reach: "guest")
            }
            let command: NOWAPIConsoleCommandRequest
            switch NOWAPIConsoleCommandHTTPCodec.parse(request.body) {
            case .success(let parsed): command = parsed
            case .failure(let problem):
                await record(requestID, "commands.execute", id, .refused)
                let outcome = NOWAPIConsoleCommandOutcome(
                    guestID: id, sessionID: guest.summary.sessionID,
                    disposition: .invalid, output: nil,
                    outputObjects: nil,
                    error: .init(code: problem.code,
                                 message: problem.message,
                                 reach: "request"))
                return json(400, requestID: requestID,
                            object: NOWAPIConsoleCommandHTTPCodec.render(
                                requestID, outcome))
            }
            let outcome = await executeCommand(guestID: id, request: command)
            response = json(200, requestID: requestID,
                            object: NOWAPIConsoleCommandHTTPCodec.render(
                                requestID, outcome))
            let auditDisposition: NOWAPIAuditEvent.Disposition
            switch outcome.disposition {
            case .completed: auditDisposition = .completed
            case .invalid, .unadvertised, .refused: auditDisposition = .refused
            case .timedOut, .disconnected, .failed: auditDisposition = .failed
            }
            await record(requestID, "commands.execute", id,
                         auditDisposition)
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

    private func executeCommand(
        guestID: String, request: NOWAPIConsoleCommandRequest
    ) async -> NOWAPIConsoleCommandOutcome {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                host.apiExecuteCommand(guestID: guestID, request: request) {
                    continuation.resume(returning: $0)
                }
            }
        }
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

    private func codable<Value: Encodable>(
        _ status: Int, requestID: UUID, _ value: Value
    ) -> MCPHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            return error(500, requestID: requestID,
                         code: "response_encoding_failed",
                         message: "The API response could not be encoded.",
                         reach: "host")
        }
        return .init(status: status, headers: [
            "Content-Type": "application/json",
            "X-Request-Id": requestID.uuidString.lowercased(),
            "Cache-Control": "no-store",
        ], body: body)
    }

    private func unavailableFiles(_ requestID: UUID) -> MCPHTTPResponse {
        error(503, requestID: requestID,
              code: "files_unavailable",
              message: "The host file service is unavailable.", reach: "host")
    }

    private func fileProblem(
        _ problem: NOWAPIFileTransferService.Problem, _ requestID: UUID
    ) -> MCPHTTPResponse {
        error(problem.status, requestID: requestID, code: problem.code,
              message: problem.message, reach: problem.reach)
    }

    private func auditedFileProblem(
        _ problem: NOWAPIFileTransferService.Problem,
        _ requestID: UUID, _ operationID: String, _ target: String?
    ) async -> MCPHTTPResponse {
        await record(requestID, operationID, target,
                     Self.auditDisposition(problem))
        return fileProblem(problem, requestID)
    }

    private func invalidQuery(_ requestID: UUID) -> MCPHTTPResponse {
        error(400, requestID: requestID, code: "query_invalid",
              message: "Query parameters must be well formed and unique.",
              reach: "request")
    }

    private static func query(_ target: String) -> [String: String]? {
        guard let marker = target.firstIndex(of: "?") else { return [:] }
        let rawQuery = target[target.index(after: marker)...]
        guard !rawQuery.isEmpty else { return nil }
        var result: [String: String] = [:]
        for field in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            guard !field.isEmpty,
                  let separator = field.firstIndex(of: "=") else { return nil }
            let rawName = field[..<separator]
            let rawValue = field[field.index(after: separator)...]
            guard let name = decodedQueryComponent(rawName), !name.isEmpty,
                  let value = decodedQueryComponent(rawValue),
                  result[name] == nil else { return nil }
            result[name] = value
        }
        return result
    }

    private static func decodedQueryComponent(_ raw: Substring) -> String? {
        let bytes = Array(raw.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      isHex(bytes[index + 1]), isHex(bytes[index + 2])
                else { return nil }
                index += 3
            } else {
                index += 1
            }
        }
        return String(raw).removingPercentEncoding
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }

    private static func auditDisposition<Value>(
        _ result: AgentIntegrationGuestFileResult<Value>
    ) -> NOWAPIAuditEvent.Disposition {
        switch result {
        case .hostUnavailable:
            return .failed
        case .completed(let receipt, _, _):
            switch receipt.outcome {
            case .success: return .completed
            case .failed, .unavailable: return .failed
            default: return .refused
            }
        }
    }

    private static func auditDisposition(
        _ transfer: NOWAPIFileTransferService.Transfer
    ) -> NOWAPIAuditEvent.Disposition {
        switch transfer.state {
        case .failed: return .failed
        case .cancelled, .expired: return .refused
        case .staging, .running, .completed: return .completed
        }
    }

    private static func auditDisposition(
        _ problem: NOWAPIFileTransferService.Problem
    ) -> NOWAPIAuditEvent.Disposition {
        problem.status >= 500 ? .failed : .refused
    }

    private static func transferTarget(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func mutation(_ body: Data)
        -> AgentIntegrationGuestFileMutationRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let mutation = object["mutation"] as? String,
              let path = object["path"] as? String else { return nil }
        switch mutation {
        case "move":
            guard let destination = object["destinationPath"] as? String,
                  object.keys.allSatisfy({
                      ["mutation", "path", "destinationPath"].contains($0)
                  }) else { return nil }
            return .move(path: path, toPath: destination)
        case "trash":
            guard object.count == 2 else { return nil }
            return .trash(path: path)
        case "restore":
            guard let trashedAs = object["trashedAs"] as? String,
                  object.keys.allSatisfy({
                      ["mutation", "path", "trashedAs"].contains($0)
                  }) else { return nil }
            return .restore(trashedAs: trashedAs, toPath: path)
        case "mkdir":
            guard object.count == 2 else { return nil }
            return .makeFolder(path: path)
        default: return nil
        }
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
