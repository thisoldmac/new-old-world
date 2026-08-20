import Foundation

/// HTTP-only parsing and rendering for the neutral console operation. Keeping
/// it out of the router makes command grammar and byte limits independently
/// testable without giving the route table domain ownership.
enum NOWAPIConsoleCommandHTTPCodec {
    struct Problem: Error {
        let code: String
        let message: String
    }

    static func parse(_ data: Data)
        -> Result<NOWAPIConsoleCommandRequest, Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            return .failure(.init(code: "invalid_command_request",
                                  message: "The command body must be a JSON object."))
        }
        let allowed = Set(["command", "arguments", "argumentLine"])
        guard Set(fields.keys).isSubset(of: allowed),
              let command = fields["command"] as? String,
              isValidCommandName(command) else {
            return .failure(.init(code: "invalid_command",
                                  message: "Command names must be bounded ASCII identifiers."))
        }
        let hasArguments = fields.keys.contains("arguments")
        let hasLine = fields.keys.contains("argumentLine")
        guard !(hasArguments && hasLine) else {
            return .failure(.init(
                code: "ambiguous_command_arguments",
                message: "Use either arguments or argumentLine, not both."))
        }

        var arguments: [String: CommandArg]?
        if hasArguments {
            guard let raw = fields["arguments"] as? [String: Any],
                  raw.count <= NOWAPIConsoleCommandService.maximumArgumentCount
            else {
                return .failure(.init(code: "invalid_command_arguments",
                                      message: "Command arguments must be a bounded JSON object."))
            }
            var parsed: [String: CommandArg] = [:]
            for (name, value) in raw {
                guard !name.isEmpty,
                      name.utf8.count <= NOWAPIConsoleCommandService.maximumArgumentNameBytes
                else {
                    return .failure(.init(code: "invalid_command_arguments",
                                          message: "A command argument name is invalid or too long."))
                }
                if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() {
                        parsed[name] = .flag(number.boolValue)
                    } else {
                        let isFloatingPoint = ["f", "d"].contains(
                            String(cString: number.objCType))
                        guard !isFloatingPoint,
                              let integer = Int(number.stringValue) else {
                            return .failure(.init(
                                code: "invalid_command_arguments",
                                message: "Arguments accept bounded strings, integers, and booleans only."))
                        }
                        parsed[name] = .number(integer)
                    }
                } else if let text = value as? String,
                          text.utf8.count <= NOWAPIConsoleCommandService.maximumArgumentTextBytes {
                    parsed[name] = .text(text)
                } else {
                    return .failure(.init(
                        code: "invalid_command_arguments",
                        message: "Arguments accept bounded strings, integers, and booleans only."))
                }
            }
            arguments = parsed
        }
        var argumentLine: String?
        if hasLine {
            guard let line = fields["argumentLine"] as? String,
                  line.utf8.count <= NOWAPIConsoleCommandService.maximumArgumentLineBytes
            else {
                return .failure(.init(code: "invalid_argument_line",
                                      message: "The raw argument line is too long."))
            }
            argumentLine = line
        }
        return .success(.init(command: command, arguments: arguments,
                              argumentLine: argumentLine))
    }

    static func isValidCommandName(_ command: String) -> Bool {
        !command.isEmpty
            && command.utf8.count <= NOWAPIConsoleCommandService.maximumCommandNameBytes
            && command.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0)
                    || "._-".unicodeScalars.contains($0))
            }
    }

    static func render(_ requestID: UUID,
                       _ outcome: NOWAPIConsoleCommandOutcome) -> [String: Any] {
        var guest: [String: Any] = ["id": outcome.guestID]
        if let sessionID = outcome.sessionID { guest["sessionId"] = sessionID }
        var object: [String: Any] = [
            "requestId": requestID.uuidString.lowercased(),
            "operationId": "commands.execute",
            "guest": guest,
            "disposition": outcome.disposition.rawValue,
        ]
        if outcome.disposition == .completed {
            var value: [String: Any] = [:]
            if let output = outcome.output { value["output"] = output }
            if let outputObjects = outcome.outputObjects {
                value["outputObjects"] = outputObjects.mapValues(jsonValue)
            }
            object["value"] = value
        } else if let failure = outcome.error {
            object["error"] = [
                "code": failure.code,
                "message": failure.message,
                "reach": failure.reach,
            ]
        }
        return object
    }

    private static func jsonValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(jsonValue)
        case .object(let values): return values.mapValues(jsonValue)
        }
    }
}
