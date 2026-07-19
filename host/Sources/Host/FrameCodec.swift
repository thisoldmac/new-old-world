import Foundation

/// The 8-byte binary frame header from contract/asyncapi.yaml, big-endian:
/// channel (u8), flags (u8), transfer id (u16), payload length (u32).
struct FrameHeader: Equatable, Sendable {
    enum Channel: UInt8, Sendable {
        case control = 0
        case bulk = 1
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let end = Flags(rawValue: 1 << 0)
    }

    static let byteCount = 8
    static let maxPayloadLength = 32768

    let channel: Channel
    let flags: Flags
    let transfer: UInt16
    let length: UInt32
}

struct Frame: Equatable, Sendable {
    let header: FrameHeader
    let payload: Data
}

enum FrameCodecError: Error, Equatable {
    case payloadTooLarge(Int)
    case unknownChannel(UInt8)
    case oversizedFrame(declared: UInt32)
}

enum FrameCodec {
    static func encode(channel: FrameHeader.Channel,
                       flags: FrameHeader.Flags = [],
                       transfer: UInt16 = 0,
                       payload: Data) throws -> Data {
        guard payload.count <= FrameHeader.maxPayloadLength else {
            throw FrameCodecError.payloadTooLarge(payload.count)
        }
        var data = Data(capacity: FrameHeader.byteCount + payload.count)
        data.append(channel.rawValue)
        data.append(flags.rawValue)
        data.append(UInt8(transfer >> 8))
        data.append(UInt8(transfer & 0xFF))
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }
}

/// Incremental decoder: feed arbitrary byte chunks, complete frames come out.
/// A malformed header (bad channel, oversized declared length) is fatal to
/// the stream — the connection carries no resync point by design.
final class FrameDecoder {
    private var buffer = Data()

    func feed(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= FrameHeader.byteCount {
            let rawChannel = buffer[buffer.startIndex]
            guard let channel = FrameHeader.Channel(rawValue: rawChannel) else {
                throw FrameCodecError.unknownChannel(rawChannel)
            }
            let flags = FrameHeader.Flags(
                rawValue: buffer[buffer.startIndex + 1])
            let transfer = UInt16(buffer[buffer.startIndex + 2]) << 8
                | UInt16(buffer[buffer.startIndex + 3])
            let length = UInt32(buffer[buffer.startIndex + 4]) << 24
                | UInt32(buffer[buffer.startIndex + 5]) << 16
                | UInt32(buffer[buffer.startIndex + 6]) << 8
                | UInt32(buffer[buffer.startIndex + 7])
            guard length <= UInt32(FrameHeader.maxPayloadLength) else {
                throw FrameCodecError.oversizedFrame(declared: length)
            }
            let total = FrameHeader.byteCount + Int(length)
            guard buffer.count >= total else { break }
            let payload = Data(buffer[(buffer.startIndex + FrameHeader.byteCount)
                ..< (buffer.startIndex + total)])
            frames.append(Frame(
                header: FrameHeader(channel: channel, flags: flags,
                                    transfer: transfer, length: length),
                payload: payload))
            buffer.removeFirst(total)
        }
        return frames
    }
}
