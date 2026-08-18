import Foundation

/// A Disk Copy 4.2 container - the format a STOCK System 7 machine can
/// open with the Disk Copy it already has, and the reason the 68K setup
/// disk survives a fork-blind download: everything lives in the data
/// fork by design, so a browser that saves the transfer raw has still
/// delivered a valid image. (NDIF, by contrast, needs Disk Copy 6 and a
/// bcem resource that only a MacBinary-aware path can carry.)
enum DiskCopy42Image {
    /// The two capacities Disk Copy 4.2 knows that HFSStandardVolume
    /// emits. DC 4.2 is a floppy tool: the disk must be exactly one of
    /// its sizes, which is why the volume writer works in floppy sizes
    /// rather than fitting.
    static func data(name: String, disk: Data) -> Data? {
        guard let nameBytes = name.data(using: .macOSRoman),
              !nameBytes.isEmpty, nameBytes.count <= 63 else { return nil }
        let format: (disk: UInt8, low: UInt8)
        switch disk.count {
        case 800 * 1_024: format = (1, 0x22)
        case 1_440 * 1_024: format = (3, 0x24)
        default: return nil
        }

        var header = [UInt8](repeating: 0, count: 84)
        header[0] = UInt8(nameBytes.count)
        header.replaceSubrange(1..<(1 + nameBytes.count), with: nameBytes)
        put32(UInt32(disk.count), &header, 64)   // data size
        put32(0, &header, 68)                    // tag size: no tags
        put32(checksum(disk), &header, 72)
        put32(0, &header, 76)                    // tag checksum
        header[80] = format.disk
        header[81] = format.low
        put16(0x0100, &header, 82)               // the format's magic

        return Data(header) + disk
    }

    /// Disk Copy 4.2's checksum: big-endian 16-bit words, each added and
    /// then the running sum rotated right one bit.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        var index = data.startIndex
        while index < data.endIndex {
            let high = UInt32(data[index])
            let low = index + 1 < data.endIndex ? UInt32(data[index + 1]) : 0
            sum = sum &+ ((high << 8) | low)
            sum = (sum >> 1) | (sum << 31)
            index += 2
        }
        return sum
    }

    private static func put16(_ value: UInt16, _ bytes: inout [UInt8],
                              _ offset: Int) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }

    private static func put32(_ value: UInt32, _ bytes: inout [UInt8],
                              _ offset: Int) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xff)
        bytes[offset + 2] = UInt8((value >> 8) & 0xff)
        bytes[offset + 3] = UInt8(value & 0xff)
    }
}
