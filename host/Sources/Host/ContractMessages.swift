import Foundation

/// Control-channel messages from contract/asyncapi.yaml. One JSON object per
/// control frame, discriminated by `type`.
enum Contract {
    /// x-contract-revision from contract/asyncapi.yaml. Unequal => refuse.
    static let revision = 1
    static let defaultChunk = 8192
}

enum ControlMessage: Equatable, Sendable {
    case hello(Hello)
    case refuse(Refuse)
    case ping(id: Int)
    case pong(id: Int)
    case bye(Bye)
    case error(ErrorMessage)
    case commandRequest(CommandRequest)
    case commandResult(CommandResult)
    case captureRequest(CaptureRequest)
    case captureCancel(CaptureCancel)
    case captureBegin(CaptureBegin)
    case captureEnd(CaptureEnd)
}

struct Hello: Codable, Equatable, Sendable {
    var contract: Int
    var side: String
    var version: String
    var name: String?
    var os: String?
    var chunk: Int?
}

struct Refuse: Codable, Equatable, Sendable {
    var contract: Int
    var reason: String
}

struct Bye: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case normal
        case shuttingDown = "shutting-down"
        case protocolError = "protocol-error"
    }

    var code: Code
    var reason: String?
}

struct ErrorMessage: Codable, Equatable, Sendable {
    var id: Int?
    var code: String
    var message: String
}

struct CommandRequest: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var args: [String: String]?
}

struct CommandResult: Codable, Equatable, Sendable {
    struct CommandError: Codable, Equatable, Sendable {
        var code: String
        var message: String
    }

    var id: Int
    var ok: Bool
    /// Grouped, ordered rows: group name -> [[label, value], ...]. gestalt
    /// returns snapshot/cpu/memory/os/network/hw; the console shows a slice.
    var output: [String: [[String]]]?
    var error: CommandError?
}

struct CaptureRequest: Codable, Equatable, Sendable {
    var id: Int
    var depth: Int
}

struct CaptureCancel: Codable, Equatable, Sendable {
    var transfer: Int
}

struct CaptureBegin: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var width: Int
    var height: Int
    var depth: Int
    var rowBytes: Int
    var bytes: Int
    var paletteBytes: Int?
    var encoding: String?
    var captureMs: Int?
    var encodeMs: Int?
}

struct CaptureEnd: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var ok: Bool
    var sendMs: Int?
}

enum ControlMessageError: Error, Equatable {
    case notAnObject
    case missingType
    case unknownType(String)
}

enum ControlMessageCodec {
    private struct TypeProbe: Codable {
        var type: String
    }

    private struct IdOnly: Codable {
        var type: String
        var id: Int
    }

    static func decode(_ data: Data) throws -> ControlMessage {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            else { throw ControlMessageError.notAnObject }
            throw ControlMessageError.missingType
        }
        switch probe.type {
        case "hello":
            return .hello(try decoder.decode(Hello.self, from: data))
        case "refuse":
            return .refuse(try decoder.decode(Refuse.self, from: data))
        case "ping":
            return .ping(id: try decoder.decode(IdOnly.self, from: data).id)
        case "pong":
            return .pong(id: try decoder.decode(IdOnly.self, from: data).id)
        case "bye":
            return .bye(try decoder.decode(Bye.self, from: data))
        case "error":
            return .error(try decoder.decode(ErrorMessage.self, from: data))
        case "command.request":
            return .commandRequest(
                try decoder.decode(CommandRequest.self, from: data))
        case "command.result":
            return .commandResult(
                try decoder.decode(CommandResult.self, from: data))
        case "capture.request":
            return .captureRequest(
                try decoder.decode(CaptureRequest.self, from: data))
        case "capture.cancel":
            return .captureCancel(
                try decoder.decode(CaptureCancel.self, from: data))
        case "capture.begin":
            return .captureBegin(
                try decoder.decode(CaptureBegin.self, from: data))
        case "capture.end":
            return .captureEnd(try decoder.decode(CaptureEnd.self, from: data))
        default:
            throw ControlMessageError.unknownType(probe.type)
        }
    }

    static func encode(_ message: ControlMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func tagged<T: Encodable>(_ type: String, _ value: T) throws -> Data {
            var object = try JSONSerialization.jsonObject(
                with: encoder.encode(value)) as? [String: Any] ?? [:]
            object["type"] = type
            return try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        }
        switch message {
        case .hello(let hello): return try tagged("hello", hello)
        case .refuse(let refuse): return try tagged("refuse", refuse)
        case .ping(let id): return try tagged("ping", ["id": id])
        case .pong(let id): return try tagged("pong", ["id": id])
        case .bye(let bye): return try tagged("bye", bye)
        case .error(let error): return try tagged("error", error)
        case .commandRequest(let m): return try tagged("command.request", m)
        case .commandResult(let m): return try tagged("command.result", m)
        case .captureRequest(let m): return try tagged("capture.request", m)
        case .captureCancel(let m): return try tagged("capture.cancel", m)
        case .captureBegin(let m): return try tagged("capture.begin", m)
        case .captureEnd(let m): return try tagged("capture.end", m)
        }
    }
}
