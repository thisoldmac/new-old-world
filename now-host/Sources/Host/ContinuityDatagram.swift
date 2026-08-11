import Foundation

/// The UDP lane carries latest state, never commands. Its fixed-size,
/// big-endian representation is shared with contract/continuity_udp.h.
struct ContinuityStateDatagram: Equatable, Sendable {
    static let byteCount = 40
    static let magic: UInt32 = 0x4E57_4331 // NWC1
    static let version: UInt16 = 1

    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt16

        static let inside = Flags(rawValue: 1 << 0)
        static let primaryDown = Flags(rawValue: 1 << 1)
        static let keepalive = Flags(rawValue: 1 << 2)
        static let known: Flags = [.inside, .primaryDown, .keepalive]
    }

    var nonceHi: UInt32
    var nonceLo: UInt32
    var epoch: UInt32
    var positionSequence: UInt32
    var h: Int16
    var v: Int16
    var buttonGeneration: UInt32
    var flags: Flags
    var requestedHz: UInt16
    var hostStamp: UInt32
}

struct ContinuityAckDatagram: Equatable, Sendable {
    static let byteCount = 44
    static let magic: UInt32 = 0x4E57_4131 // NWA1

    enum State: UInt16, Sendable {
        case inactive = 0
        case armed = 1
        case active = 2
    }

    enum ExitReason: UInt16, Sendable {
        case none = 0
        case hostLeft = 1
        case guestInput = 2
        case leaseExpired = 3
        case disarmed = 4
    }

    var nonceHi: UInt32
    var nonceLo: UInt32
    var epoch: UInt32
    var positionSequence: UInt32
    var buttonGeneration: UInt32
    var arrivalTicks: UInt32
    var applyTicks: UInt32
    var rejectedPackets: UInt32
    var state: State
    var acceptedHz: UInt16
    var exitReason: ExitReason
}

enum ContinuityDatagramError: Error, Equatable {
    case wrongSize(expected: Int, actual: Int)
    case wrongMagic
    case wrongVersion(UInt16)
    case reservedFlags(UInt16)
    case reservedField(UInt16)
    case unknownAckState(UInt16)
    case unknownExitReason(UInt16)
}

enum ContinuityDatagramCodec {
    static func encode(_ packet: ContinuityStateDatagram) -> Data {
        var bytes = [UInt8](repeating: 0,
                            count: ContinuityStateDatagram.byteCount)
        put(packet: ContinuityStateDatagram.magic, at: 0, in: &bytes)
        put(packet: ContinuityStateDatagram.version, at: 4, in: &bytes)
        put(packet: packet.flags.rawValue, at: 6, in: &bytes)
        put(packet: packet.nonceHi, at: 8, in: &bytes)
        put(packet: packet.nonceLo, at: 12, in: &bytes)
        put(packet: packet.epoch, at: 16, in: &bytes)
        put(packet: packet.positionSequence, at: 20, in: &bytes)
        put(packet: UInt16(bitPattern: packet.h), at: 24, in: &bytes)
        put(packet: UInt16(bitPattern: packet.v), at: 26, in: &bytes)
        put(packet: packet.buttonGeneration, at: 28, in: &bytes)
        put(packet: packet.requestedHz, at: 32, in: &bytes)
        put(packet: UInt16(0), at: 34, in: &bytes)
        put(packet: packet.hostStamp, at: 36, in: &bytes)
        return Data(bytes)
    }

    static func decodeState(_ data: Data) throws -> ContinuityStateDatagram {
        let bytes = [UInt8](data)
        guard bytes.count == ContinuityStateDatagram.byteCount else {
            throw ContinuityDatagramError.wrongSize(
                expected: ContinuityStateDatagram.byteCount,
                actual: bytes.count)
        }
        guard getU32(bytes, 0) == ContinuityStateDatagram.magic else {
            throw ContinuityDatagramError.wrongMagic
        }
        let version = getU16(bytes, 4)
        guard version == ContinuityStateDatagram.version else {
            throw ContinuityDatagramError.wrongVersion(version)
        }
        let rawFlags = getU16(bytes, 6)
        let unknown = rawFlags & ~ContinuityStateDatagram.Flags.known.rawValue
        guard unknown == 0 else {
            throw ContinuityDatagramError.reservedFlags(unknown)
        }
        let reserved = getU16(bytes, 34)
        guard reserved == 0 else {
            throw ContinuityDatagramError.reservedField(reserved)
        }
        return ContinuityStateDatagram(
            nonceHi: getU32(bytes, 8), nonceLo: getU32(bytes, 12),
            epoch: getU32(bytes, 16), positionSequence: getU32(bytes, 20),
            h: Int16(bitPattern: getU16(bytes, 24)),
            v: Int16(bitPattern: getU16(bytes, 26)),
            buttonGeneration: getU32(bytes, 28),
            flags: .init(rawValue: rawFlags), requestedHz: getU16(bytes, 32),
            hostStamp: getU32(bytes, 36))
    }

    static func encode(_ packet: ContinuityAckDatagram) -> Data {
        var bytes = [UInt8](repeating: 0,
                            count: ContinuityAckDatagram.byteCount)
        put(packet: ContinuityAckDatagram.magic, at: 0, in: &bytes)
        put(packet: ContinuityStateDatagram.version, at: 4, in: &bytes)
        put(packet: packet.state.rawValue, at: 6, in: &bytes)
        put(packet: packet.nonceHi, at: 8, in: &bytes)
        put(packet: packet.nonceLo, at: 12, in: &bytes)
        put(packet: packet.epoch, at: 16, in: &bytes)
        put(packet: packet.positionSequence, at: 20, in: &bytes)
        put(packet: packet.buttonGeneration, at: 24, in: &bytes)
        put(packet: packet.acceptedHz, at: 28, in: &bytes)
        put(packet: packet.exitReason.rawValue, at: 30, in: &bytes)
        put(packet: packet.arrivalTicks, at: 32, in: &bytes)
        put(packet: packet.applyTicks, at: 36, in: &bytes)
        put(packet: packet.rejectedPackets, at: 40, in: &bytes)
        return Data(bytes)
    }

    static func decodeAck(_ data: Data) throws -> ContinuityAckDatagram {
        let bytes = [UInt8](data)
        guard bytes.count == ContinuityAckDatagram.byteCount else {
            throw ContinuityDatagramError.wrongSize(
                expected: ContinuityAckDatagram.byteCount,
                actual: bytes.count)
        }
        guard getU32(bytes, 0) == ContinuityAckDatagram.magic else {
            throw ContinuityDatagramError.wrongMagic
        }
        let version = getU16(bytes, 4)
        guard version == ContinuityStateDatagram.version else {
            throw ContinuityDatagramError.wrongVersion(version)
        }
        let rawState = getU16(bytes, 6)
        guard let state = ContinuityAckDatagram.State(rawValue: rawState) else {
            throw ContinuityDatagramError.unknownAckState(rawState)
        }
        let rawReason = getU16(bytes, 30)
        guard let reason = ContinuityAckDatagram.ExitReason(
            rawValue: rawReason) else {
            throw ContinuityDatagramError.unknownExitReason(rawReason)
        }
        return ContinuityAckDatagram(
            nonceHi: getU32(bytes, 8), nonceLo: getU32(bytes, 12),
            epoch: getU32(bytes, 16), positionSequence: getU32(bytes, 20),
            buttonGeneration: getU32(bytes, 24),
            arrivalTicks: getU32(bytes, 32), applyTicks: getU32(bytes, 36),
            rejectedPackets: getU32(bytes, 40), state: state,
            acceptedHz: getU16(bytes, 28), exitReason: reason)
    }

    private static func getU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func getU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func put(packet value: UInt16, at offset: Int,
                            in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func put(packet value: UInt32, at offset: Int,
                            in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
