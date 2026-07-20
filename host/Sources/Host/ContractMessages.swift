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
    case fileList(FileList)
    case fileListing(FileListing)
    case fileGet(FileGet)
    case fileOffer(FileOffer)
    case fileAccept(FileAccept)
    case fileDone(FileDone)
    case fileProgress(FileProgress)
    case fileRefuse(FileRefuse)
    case fileMove(FileMove)
    case fileTrash(FileTrash)
    case fileRestore(FileRestore)
    case fileMkdir(FileMkdir)
    case fileResult(FileResult)
    case fileBegin(FileBegin)
    case fileEnd(FileEnd)
    case fileCancel(FileCancel)
    case streamRequest(StreamRequest)
    case streamStart(StreamStart)
    case streamStop(StreamStop)
    case streamRefresh(StreamRefresh)
    case streamStopped(StreamStopped)
    case captureOffer(CaptureOffer)
    case captureAccept(CaptureAccept)
    case captureRefuse(CaptureRefuse)
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
    var chunkKb: Int?
    var paceMs: Int?
    var pack: Bool?
}

/// The guest's file share. Paths are relative to the guest's chosen
/// share root ("" is the root, segments joined with ":"), so nothing
/// outside the share is expressible.
struct FileList: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var cursor: Int?
}

struct FileEntry: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var kind: String
    var fileType: String?
    var creator: String?
    var dataBytes: Int?
    var rsrcBytes: Int?
    /// Classic Mac epoch: seconds since 1904-01-01.
    var modified: Int?

    var id: String { name }
    var isFolder: Bool { kind == "folder" }
}

struct FileListing: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var entries: [FileEntry]
    var more: Bool
    var cursor: Int?
}

struct FileGet: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var container: String?
}

/// A push into the guest's share. The share bounds what the guest may
/// reach unbidden, never what a human deliberately sends — so the
/// source is any file, and only `path` must lie inside the share.
struct FileOffer: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var path: String
    var container: String
    var bytes: Int
    var fileType: String?
    var creator: String?
    var modified: Int?
    var overwrite: Bool?
}

struct FileAccept: Codable, Equatable, Sendable {
    var id: Int
}

struct FileDone: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var code: String?
    var reason: String?
}

/// What the guest has actually taken off the wire during a put. Advisory:
/// the guest drops these rather than delaying the messages that carry
/// meaning, so treat it as a floor that may skip, and its absence as an
/// older guest rather than a stalled one.
struct FileProgress: Codable, Equatable, Sendable {
    var id: Int
    var received: Int
}

/// Changing the share. A rename and a move are the same operation —
/// `toPath` carries the whole destination including the new name — and
/// missing parents are not invented, because a typo in a folder name
/// should fail rather than quietly create one.
struct FileMove: Codable, Equatable, Sendable {
    var id: Int
    var path: String
    var toPath: String
    var overwrite: Bool?
}

/// Delete means the Trash, not unlink: it is what a human expects on
/// this machine, and it is the only honest basis for an undo.
struct FileTrash: Codable, Equatable, Sendable {
    var id: Int
    var path: String
}

/// Puts a trashed item back. Both halves are names — what it is called
/// in the Trash, and where in the share it belongs — so an undo survives
/// a restart of either side. The Trash is a real folder; a name in it is
/// as durable a way to say "that item" as a path anywhere else.
struct FileRestore: Codable, Equatable, Sendable {
    var id: Int
    var trashedAs: String
    var toPath: String
}

struct FileMkdir: Codable, Equatable, Sendable {
    var id: Int
    var path: String
}

struct FileResult: Codable, Equatable, Sendable {
    var id: Int
    var ok: Bool
    var path: String?
    /// Answering file.trash: the name it landed under in the Trash,
    /// which is not always the name it had — the Trash may already hold
    /// one, and the second delete must not fail.
    var trashedAs: String?
    var code: String?
    var reason: String?
}

struct FileRefuse: Codable, Equatable, Sendable {
    var id: Int
    var code: String
    var reason: String?
}

struct FileBegin: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var name: String
    var container: String
    var bytes: Int
    var dataBytes: Int?
    var rsrcBytes: Int?
    var fileType: String?
    var creator: String?
    var modified: Int?
}

struct FileEnd: Codable, Equatable, Sendable {
    var id: Int
    var transfer: Int
    var ok: Bool
    var sendMs: Int?
}

struct FileCancel: Codable, Equatable, Sendable {
    var transfer: Int
}

/// Live-stream bracket: between stream.start and the guest's
/// stream.stopped, frames arrive as ordinary capture transfers whose
/// begin id is the stream id. stream.stopped is always the last word —
/// it acks the host's stop and reports guest-side aborts.
struct StreamRequest: Codable, Equatable, Sendable {
    var depth: Int
}

struct StreamStart: Codable, Equatable, Sendable {
    var id: Int
    var depth: Int
    var minIntervalMs: Int?
    var chunkKb: Int?
    var paceMs: Int?
    var pack: Bool?
    var predictive: Bool?
    var interlace: Bool?
}

struct StreamStop: Codable, Equatable, Sendable {
    var id: Int
}

struct StreamRefresh: Codable, Equatable, Sendable {
    var id: Int
}

struct StreamStopped: Codable, Equatable, Sendable {
    var id: Int
    var reason: String?
}

/// Guest-initiated push: the guest has already captured and encoded, so the
/// byte counts are exact; the host answers accept or refuse.
struct CaptureOffer: Codable, Equatable, Sendable {
    var id: Int
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

struct CaptureAccept: Codable, Equatable, Sendable {
    var id: Int
}

struct CaptureRefuse: Codable, Equatable, Sendable {
    var id: Int
    var reason: String?
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
    /// Stream frames only: "key", "delta", or "empty" (absent = one-shot).
    var frame: String?
    /// Delta frames: [row, nRows, colByteOffset, colBytes] per dirty rect.
    var rects: [[Int]]?
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
        case "file.list":
            return .fileList(try decoder.decode(FileList.self, from: data))
        case "file.listing":
            return .fileListing(
                try decoder.decode(FileListing.self, from: data))
        case "file.get":
            return .fileGet(try decoder.decode(FileGet.self, from: data))
        case "file.offer":
            return .fileOffer(try decoder.decode(FileOffer.self, from: data))
        case "file.accept":
            return .fileAccept(
                try decoder.decode(FileAccept.self, from: data))
        case "file.done":
            return .fileDone(try decoder.decode(FileDone.self, from: data))
        case "file.progress":
            return .fileProgress(
                try decoder.decode(FileProgress.self, from: data))
        case "file.move":
            return .fileMove(try decoder.decode(FileMove.self, from: data))
        case "file.trash":
            return .fileTrash(try decoder.decode(FileTrash.self, from: data))
        case "file.restore":
            return .fileRestore(
                try decoder.decode(FileRestore.self, from: data))
        case "file.mkdir":
            return .fileMkdir(try decoder.decode(FileMkdir.self, from: data))
        case "file.result":
            return .fileResult(
                try decoder.decode(FileResult.self, from: data))
        case "file.refuse":
            return .fileRefuse(
                try decoder.decode(FileRefuse.self, from: data))
        case "file.begin":
            return .fileBegin(try decoder.decode(FileBegin.self, from: data))
        case "file.end":
            return .fileEnd(try decoder.decode(FileEnd.self, from: data))
        case "file.cancel":
            return .fileCancel(
                try decoder.decode(FileCancel.self, from: data))
        case "stream.request":
            return .streamRequest(
                try decoder.decode(StreamRequest.self, from: data))
        case "stream.start":
            return .streamStart(
                try decoder.decode(StreamStart.self, from: data))
        case "stream.stop":
            return .streamStop(try decoder.decode(StreamStop.self, from: data))
        case "stream.refresh":
            return .streamRefresh(
                try decoder.decode(StreamRefresh.self, from: data))
        case "stream.stopped":
            return .streamStopped(
                try decoder.decode(StreamStopped.self, from: data))
        case "capture.offer":
            return .captureOffer(
                try decoder.decode(CaptureOffer.self, from: data))
        case "capture.accept":
            return .captureAccept(
                try decoder.decode(CaptureAccept.self, from: data))
        case "capture.refuse":
            return .captureRefuse(
                try decoder.decode(CaptureRefuse.self, from: data))
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
        case .fileList(let m): return try tagged("file.list", m)
        case .fileListing(let m): return try tagged("file.listing", m)
        case .fileGet(let m): return try tagged("file.get", m)
        case .fileOffer(let m): return try tagged("file.offer", m)
        case .fileAccept(let m): return try tagged("file.accept", m)
        case .fileDone(let m): return try tagged("file.done", m)
        case .fileProgress(let m): return try tagged("file.progress", m)
        case .fileRefuse(let m): return try tagged("file.refuse", m)
        case .fileMove(let m): return try tagged("file.move", m)
        case .fileTrash(let m): return try tagged("file.trash", m)
        case .fileRestore(let m): return try tagged("file.restore", m)
        case .fileMkdir(let m): return try tagged("file.mkdir", m)
        case .fileResult(let m): return try tagged("file.result", m)
        case .fileBegin(let m): return try tagged("file.begin", m)
        case .fileEnd(let m): return try tagged("file.end", m)
        case .fileCancel(let m): return try tagged("file.cancel", m)
        case .streamRequest(let m): return try tagged("stream.request", m)
        case .streamStart(let m): return try tagged("stream.start", m)
        case .streamStop(let m): return try tagged("stream.stop", m)
        case .streamRefresh(let m): return try tagged("stream.refresh", m)
        case .streamStopped(let m): return try tagged("stream.stopped", m)
        case .captureOffer(let m): return try tagged("capture.offer", m)
        case .captureAccept(let m): return try tagged("capture.accept", m)
        case .captureRefuse(let m): return try tagged("capture.refuse", m)
        case .captureCancel(let m): return try tagged("capture.cancel", m)
        case .captureBegin(let m): return try tagged("capture.begin", m)
        case .captureEnd(let m): return try tagged("capture.end", m)
        }
    }
}
