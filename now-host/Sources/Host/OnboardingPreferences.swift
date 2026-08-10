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

        return MacBinaryEncoder.data(name: classicName,
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
