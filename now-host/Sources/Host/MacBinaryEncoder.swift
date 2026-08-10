import Foundation

/// MacBinary II is the browser-safe delivery envelope for classic files. It
/// carries both forks plus Finder type/creator through a data-only HTTP path.
enum MacBinaryEncoder {
    static func data(name: String, type: String, creator: String,
                     finderFlags: UInt16 = 0,
                     dataFork: Data, resourceFork: Data = Data()) -> Data? {
        guard let nameBytes = name.data(using: .macOSRoman),
              !nameBytes.isEmpty, nameBytes.count <= 63,
              let typeBytes = fourBytes(type),
              let creatorBytes = fourBytes(creator),
              dataFork.count <= UInt32.max,
              resourceFork.count <= UInt32.max else { return nil }

        var header = [UInt8](repeating: 0, count: 128)
        header[1] = UInt8(nameBytes.count)
        header.replaceSubrange(2..<(2 + nameBytes.count), with: nameBytes)
        header.replaceSubrange(65..<69, with: typeBytes)
        header.replaceSubrange(69..<73, with: creatorBytes)
        header[73] = UInt8(finderFlags >> 8)
        header[101] = UInt8(finderFlags & 0xff)
        putBigEndian(UInt32(dataFork.count), at: 83, in: &header)
        putBigEndian(UInt32(resourceFork.count), at: 87, in: &header)
        header[122] = 129
        header[123] = 129
        let checksum = crc16(header.prefix(124))
        header[124] = UInt8(checksum >> 8)
        header[125] = UInt8(checksum & 0xff)

        var result = Data(header)
        appendPadded(dataFork, to: &result)
        appendPadded(resourceFork, to: &result)
        return result
    }

    private static func appendPadded(_ fork: Data, to result: inout Data) {
        result.append(fork)
        let padding = (128 - fork.count % 128) % 128
        if padding > 0 {
            result.append(contentsOf: repeatElement(0, count: padding))
        }
    }

    private static func fourBytes(_ value: String) -> [UInt8]? {
        let bytes = Array(value.utf8)
        return bytes.count == 4 ? bytes : nil
    }

    private static func putBigEndian(_ value: UInt32, at offset: Int,
                                     in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xff)
        bytes[offset + 2] = UInt8((value >> 8) & 0xff)
        bytes[offset + 3] = UInt8(value & 0xff)
    }

    private static func crc16<S: Sequence>(_ bytes: S) -> UInt16
        where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }
}
