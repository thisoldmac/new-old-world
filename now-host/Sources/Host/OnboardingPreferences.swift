import Foundation

/// The smallest preference record the PPC guest accepts: connection only.
/// `prefs.c` deliberately keeps every newer setting at its compiled default
/// when it reads format 1, so this record does not have to duplicate the
/// guest's accretive preference layout.
enum OnboardingPreferences {
    static let classicName = "New Old World Prefs"

    static func macBinary(host: String, port: UInt16) -> Data? {
        guard isDottedIPv4(host),
              let hostBytes = host.data(using: .ascii),
              hostBytes.count < 64 else { return nil }

        var record = [UInt8]()
        record.append(contentsOf: Array("NOWp".utf8))
        appendBigEndian(UInt16(1), to: &record)
        appendBigEndian(port, to: &record)
        record.append(contentsOf: hostBytes)
        record.append(contentsOf: repeatElement(
            0, count: 64 - hostBytes.count))

        return MacBinary.data(name: classicName,
                              type: "pref",
                              creator: "NOWo",
                              dataFork: Data(record))
    }

    private static func appendBigEndian(_ value: UInt16,
                                        to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private static func isDottedIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".",
                                omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let number = UInt8(part) else { return false }
            return String(number) == part
        }
    }
}

/// MacBinary II keeps the preference file's classic name, Finder type and
/// creator intact across an HTTP download. The guest needs no resource fork
/// for this file.
private enum MacBinary {
    static func data(name: String, type: String, creator: String,
                     dataFork: Data) -> Data? {
        guard let nameBytes = name.data(using: .macOSRoman),
              !nameBytes.isEmpty, nameBytes.count <= 63,
              let typeBytes = fourBytes(type),
              let creatorBytes = fourBytes(creator),
              dataFork.count <= UInt32.max else { return nil }

        var header = [UInt8](repeating: 0, count: 128)
        header[1] = UInt8(nameBytes.count)
        header.replaceSubrange(2..<(2 + nameBytes.count), with: nameBytes)
        header.replaceSubrange(65..<69, with: typeBytes)
        header.replaceSubrange(69..<73, with: creatorBytes)
        putBigEndian(UInt32(dataFork.count), at: 83, in: &header)
        header[122] = 129
        header[123] = 129
        let checksum = crc16(header.prefix(124))
        header[124] = UInt8(checksum >> 8)
        header[125] = UInt8(checksum & 0xff)

        var result = Data(header)
        result.append(dataFork)
        let padding = (128 - dataFork.count % 128) % 128
        if padding > 0 {
            result.append(contentsOf: repeatElement(0, count: padding))
        }
        return result
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
