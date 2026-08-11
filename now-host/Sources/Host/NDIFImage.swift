import Foundation

/// A minimal, uncompressed New Disk Image Format carrier for Disk Copy 6.
/// NDIF keeps the raw disk in the data fork and its block map in a `bcem`
/// resource. The whole native image is then wrapped in MacBinary for HTTP.
enum NDIFImage {
    static func macBinary(name: String, volumeName: String,
                          disk: Data) -> Data? {
        guard !disk.isEmpty, disk.count % 512 == 0,
              disk.count <= UInt32.max,
              let blockMap = blockMap(volumeName: volumeName,
                                      byteCount: disk.count),
              let resourceFork = ResourceFork.single(
                type: "bcem", id: 128, name: volumeName,
                payload: blockMap) else { return nil }

        return MacBinaryEncoder.data(
            name: name, type: "rohd", creator: "ddsk",
            dataFork: disk, resourceFork: resourceFork)
    }

    private static func blockMap(volumeName: String,
                                 byteCount: Int) -> Data? {
        guard let name = volumeName.data(using: .macOSRoman),
              !name.isEmpty, name.count <= 63 else { return nil }
        let sectors = UInt32(byteCount / 512)
        var map = [UInt8](repeating: 0, count: 128)
        put(UInt16(11), at: 0, in: &map)
        map[4] = UInt8(name.count)
        map.replaceSubrange(5..<(5 + name.count), with: name)
        put(sectors, at: 68, in: &map)
        put(UInt32(0x201), at: 72, in: &map)
        put(UInt32(2), at: 124, in: &map)

        // One verbatim chunk covers the complete disk. The end record starts
        // at the first sector after it. NDIF offsets are data-fork offsets.
        appendChunk(firstSector: 0, type: 0x02,
                    offset: 0, length: UInt32(byteCount), to: &map)
        appendChunk(firstSector: sectors, type: 0xff,
                    offset: 0, length: 0, to: &map)
        return Data(map)
    }

    private static func appendChunk(firstSector: UInt32, type: UInt8,
                                    offset: UInt32, length: UInt32,
                                    to map: inout [UInt8]) {
        append((firstSector << 8) | UInt32(type), to: &map)
        append(offset, to: &map)
        append(length, to: &map)
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func put(_ value: UInt16, at offset: Int,
                            in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }

    private static func put(_ value: UInt32, at offset: Int,
                            in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xff)
        bytes[offset + 2] = UInt8((value >> 8) & 0xff)
        bytes[offset + 3] = UInt8(value & 0xff)
    }
}

private enum ResourceFork {
    static func single(type: String, id: Int16, name: String,
                       payload: Data) -> Data? {
        guard let typeBytes = type.data(using: .ascii), typeBytes.count == 4,
              let nameBytes = name.data(using: .macOSRoman),
              nameBytes.count <= 255,
              payload.count <= UInt32.max else { return nil }

        let dataOffset = 256
        var resourceData = Data()
        resourceData.append(bigEndian: UInt32(payload.count))
        resourceData.append(payload)
        let mapOffset = aligned(dataOffset + resourceData.count, to: 256)

        var map = Data(repeating: 0, count: 28)
        map.replaceSubrange(24..<26, with: UInt16(28).bigEndianData)
        let nameListOffset = 50
        map.replaceSubrange(26..<28,
                            with: UInt16(nameListOffset).bigEndianData)
        map.append(bigEndian: UInt16(0))
        map.append(typeBytes)
        map.append(bigEndian: UInt16(0))
        map.append(bigEndian: UInt16(10))
        map.append(bigEndian: UInt16(bitPattern: id))
        map.append(bigEndian: UInt16(0))
        map.append(0)
        map.append(contentsOf: [0, 0, 0])
        map.append(bigEndian: UInt32(0))
        map.append(UInt8(nameBytes.count))
        map.append(nameBytes)

        let header = resourceHeader(dataOffset: dataOffset,
                                    mapOffset: mapOffset,
                                    dataLength: resourceData.count,
                                    mapLength: map.count)
        map.replaceSubrange(0..<16, with: header)

        var fork = Data(header)
        fork.append(Data(repeating: 0,
                         count: dataOffset - fork.count))
        fork.append(resourceData)
        fork.append(Data(repeating: 0,
                         count: mapOffset - fork.count))
        fork.append(map)
        return fork
    }

    private static func resourceHeader(dataOffset: Int, mapOffset: Int,
                                       dataLength: Int,
                                       mapLength: Int) -> Data {
        var header = Data()
        header.append(bigEndian: UInt32(dataOffset))
        header.append(bigEndian: UInt32(mapOffset))
        header.append(bigEndian: UInt32(dataLength))
        header.append(bigEndian: UInt32(mapLength))
        return header
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
}

private extension FixedWidthInteger {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        append(value.bigEndianData)
    }
}
