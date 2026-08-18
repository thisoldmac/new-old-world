import Foundation

/// A freshly-formatted HFS **Standard** volume, written from scratch.
///
/// System 7.1 predates HFS+ by six years, so the 68K flavor's setup disk
/// must be the filesystem that OS generation can mount - and macOS lost
/// the ability to write (10.6) and then read (10.15) HFS Standard, so no
/// system tool can make one. This writer covers exactly the volume the
/// setup image needs and nothing more: one flat root directory, a handful
/// of files with both forks and Finder info, fixed floppy-sized capacity,
/// built once and never modified. No growth, no deletion, no hierarchy -
/// which collapses each B*-tree to a header node plus at most one leaf.
///
/// Layout facts are Inside Macintosh: Files ("Data Organization on
/// Volumes"). hfsutils is deliberately NOT a source of code - it is the
/// independent oracle the tests read this volume back with, so the codec
/// is never grading its own homework. The one table below that is not
/// prose-derivable is Apple's case-insensitive name-ordering table, taken
/// from machfs 1.3 (MIT License, Copyright (c) Elliot Nunn) rather than
/// from GPL text.
enum HFSStandardVolume {
    struct File {
        let name: String
        let type: String
        let creator: String
        let finderFlags: UInt16
        let dataFork: Data
        let resourceFork: Data
    }

    enum Capacity: CaseIterable {
        case floppy800K
        case floppy1440K

        var totalSectors: Int {
            switch self {
            case .floppy800K: return 1_600
            case .floppy1440K: return 2_880
            }
        }
    }

    static let sectorSize = 512
    /// Boot pair, MDB, VBM, alternate MDB, spare - the sectors that are
    /// not allocation blocks at these capacities (one VBM sector covers
    /// up to 4096 allocation blocks, more than either floppy holds).
    private static let overheadSectors = 6
    private static let extentsBlocks = 1
    private static let rootCNID: UInt32 = 2
    private static let firstFileCNID: UInt32 = 16

    /// The smallest capacity that holds the files, or nil when even the
    /// largest cannot - the caller turns that into its own named error.
    static func fittingCapacity(for files: [File],
                                volumeName: String = "NOW Setup")
        -> Capacity? {
        Capacity.allCases.first { capacity in
            blocksNeeded(for: files, volumeName: volumeName)
                <= availableBlocks(in: capacity)
        }
    }

    static func build(volumeName: String, files: [File],
                      capacity: Capacity, at date: Date = Date()) -> Data? {
        guard let nameBytes = pascal(volumeName, max: 27),
              files.count <= 20,
              blocksNeeded(for: files, volumeName: volumeName)
                  <= availableBlocks(in: capacity),
              files.allSatisfy({ pascal($0.name, max: 31) != nil })
        else { return nil }

        let totalSectors = capacity.totalSectors
        let allocationBlocks = totalSectors - overheadSectors
        let stamp = macDate(date)
        var disk = Data(count: totalSectors * sectorSize)
        let catalogBlocks = catalogNodeCount(
            for: files, volumeName: volumeName)

        // Fork placement: contiguous, in catalog order is not required -
        // extent records say where each fork lives - but writing them in
        // input order keeps the builder auditable.
        var nextBlock = extentsBlocks + catalogBlocks
        var placements: [(dataStart: Int, dataBlocks: Int,
                          rsrcStart: Int, rsrcBlocks: Int)] = []
        for file in files {
            let dataBlocks = blocks(file.dataFork.count)
            let rsrcBlocks = blocks(file.resourceFork.count)
            placements.append((nextBlock, dataBlocks,
                               nextBlock + dataBlocks, rsrcBlocks))
            write(file.dataFork, toBlock: nextBlock, in: &disk)
            write(file.resourceFork, toBlock: nextBlock + dataBlocks,
                  in: &disk)
            nextBlock += dataBlocks + rsrcBlocks
        }
        let usedBlocks = nextBlock

        // --- Master Directory Block (sector 2), IM:F 2-60 ---
        var mdb = [UInt8](repeating: 0, count: sectorSize)
        put16(0x4244, &mdb, 0)                       // drSigWord 'BD'
        put32(stamp, &mdb, 2)                        // drCrDate
        put32(stamp, &mdb, 6)                        // drLsMod
        put16(0x0100, &mdb, 10)                      // drAtrb: unmounted cleanly
        put16(UInt16(files.count), &mdb, 12)         // drNmFls
        put16(3, &mdb, 14)                           // drVBMSt
        put16(UInt16(usedBlocks), &mdb, 16)          // drAllocPtr
        put16(UInt16(allocationBlocks), &mdb, 18)    // drNmAlBlks
        put32(UInt32(sectorSize), &mdb, 20)          // drAlBlkSiz
        put32(UInt32(4 * sectorSize), &mdb, 24)      // drClpSiz
        put16(4, &mdb, 28)                           // drAlBlSt
        put32(firstFileCNID + UInt32(files.count), &mdb, 30) // drNxtCNID
        put16(UInt16(allocationBlocks - usedBlocks), &mdb, 34) // drFreeBks
        mdb.replaceSubrange(36..<(36 + nameBytes.count), with: nameBytes)
        put32(0, &mdb, 64)                           // drVolBkUp
        put32(1, &mdb, 70)                           // drWrCnt
        put32(UInt32(4 * sectorSize), &mdb, 74)      // drXTClpSiz
        put32(UInt32(4 * sectorSize), &mdb, 78)      // drCTClpSiz
        put32(UInt32(files.count), &mdb, 84)         // drFilCnt
        put32(UInt32(extentsBlocks * sectorSize), &mdb, 130) // drXTFlSize
        put16(0, &mdb, 134); put16(UInt16(extentsBlocks), &mdb, 136)
        put32(UInt32(catalogBlocks * sectorSize), &mdb, 146) // drCTFlSize
        put16(UInt16(extentsBlocks), &mdb, 150)
        put16(UInt16(catalogBlocks), &mdb, 152)
        disk.replaceSubrange(2 * sectorSize..<(3 * sectorSize),
                             with: mdb)
        // Alternate MDB, second-to-last sector.
        disk.replaceSubrange((totalSectors - 2) * sectorSize
                                ..< (totalSectors - 1) * sectorSize,
                             with: mdb)

        // --- Volume bitmap (sector 3): one bit per allocation block ---
        var vbm = [UInt8](repeating: 0, count: sectorSize)
        for block in 0..<usedBlocks {
            vbm[block / 8] |= 0x80 >> (block % 8)
        }
        disk.replaceSubrange(3 * sectorSize..<(4 * sectorSize), with: vbm)

        // --- Extents overflow file: an empty tree is a header node ---
        let extentsNode = bTreeHeaderNode(
            depth: 0, root: 0, records: 0, firstLeaf: 0, lastLeaf: 0,
            keyLength: 7, nodes: extentsBlocks, free: 0)
        write(extentsNode, toBlock: 0, in: &disk)

        // --- Catalog file: header node, leaf chain, index if needed ---
        let records = catalogRecords(volumeName: volumeName, files: files,
                                     placements: placements, date: stamp)
        let leaves = packIntoLeaves(records)
        let leafCount = leaves.count
        let hasIndex = leafCount > 1
        // Node numbering within the catalog file: 0 header, 1..L leaves,
        // then the index root when the leaf chain needs one.
        for (position, leafRecords) in leaves.enumerated() {
            var node = Data(count: sectorSize)
            writeNode(records: leafRecords, type: 0xFF, height: 1,
                      forwardLink: position + 1 < leafCount
                          ? UInt32(position + 2) : 0,
                      backwardLink: position > 0 ? UInt32(position) : 0,
                      into: &node)
            write(node, toBlock: extentsBlocks + 1 + position, in: &disk)
        }
        if hasIndex {
            var index = Data(count: sectorSize)
            let pointers = leaves.enumerated().map { position, leafRecords in
                indexRecord(firstRecord: leafRecords[0],
                            node: UInt32(position + 1))
            }
            writeNode(records: pointers, type: 0, height: 2,
                      forwardLink: 0, backwardLink: 0, into: &index)
            write(index, toBlock: extentsBlocks + 1 + leafCount, in: &disk)
        }
        let catalogHeader = bTreeHeaderNode(
            depth: hasIndex ? 2 : 1,
            root: hasIndex ? leafCount + 1 : 1,
            records: records.count,
            firstLeaf: 1, lastLeaf: leafCount, keyLength: 37,
            nodes: catalogBlocks, free: 0)
        write(catalogHeader, toBlock: extentsBlocks, in: &disk)

        return disk
    }

    private static func catalogRecords(
        volumeName: String, files: [File],
        placements: [(dataStart: Int, dataBlocks: Int,
                      rsrcStart: Int, rsrcBlocks: Int)],
        date: UInt32) -> [Data] {
        var records: [Data] = []
        // Root directory record, keyed under the pseudo-parent CNID 1.
        records.append(catalogRecord(
            parent: 1, name: volumeName,
            payload: directoryRecord(id: rootCNID,
                                     valence: UInt16(files.count),
                                     date: date)))
        // Root thread, keyed (rootCNID, empty name).
        records.append(catalogRecord(
            parent: rootCNID, name: "",
            payload: threadRecord(parent: 1, name: volumeName)))
        // Files, sorted the way the File Manager searches.
        let sorted = files.enumerated().sorted { left, right in
            orderedBefore(left.element.name, right.element.name)
        }
        for (index, file) in sorted {
            records.append(catalogRecord(
                parent: rootCNID, name: file.name,
                payload: fileRecord(
                    file: file, id: firstFileCNID + UInt32(index),
                    date: date, placement: placements[index])))
        }
        return records
    }

    /// Greedy packing under the node's real arithmetic: descriptor (14),
    /// the records, and the offset stack (2 per record plus the free-space
    /// entry) all share 512 bytes.
    private static func packIntoLeaves(_ records: [Data]) -> [[Data]] {
        var leaves: [[Data]] = [[]]
        var used = 14 + 2
        for record in records {
            let cost = record.count + 2
            if used + cost > sectorSize {
                leaves.append([])
                used = 14 + 2
            }
            leaves[leaves.count - 1].append(record)
            used += cost
        }
        return leaves
    }

    /// An index record: the leaf's first key at the FIXED catalog key
    /// length (0x25 + pad), then the leaf's node number.
    private static func indexRecord(firstRecord: Data,
                                    node: UInt32) -> Data {
        var key = [UInt8](repeating: 0, count: 38)
        key[0] = 0x25
        let keyLength = Int(firstRecord[firstRecord.startIndex])
        for offset in 1...keyLength {
            key[offset] = firstRecord[firstRecord.startIndex + offset]
        }
        var record = Data(key)
        var pointer = [UInt8]()
        append32(node, &pointer)
        record.append(contentsOf: pointer)
        return record
    }

    private static func catalogNodeCount(for files: [File],
                                         volumeName: String) -> Int {
        let placeholder = files.map { _ in (0, 0, 0, 0) }
        let records = catalogRecords(
            volumeName: volumeName, files: files,
            placements: placeholder, date: 0)
        let leafCount = packIntoLeaves(records).count
        return 1 + leafCount + (leafCount > 1 ? 1 : 0)
    }

    // MARK: - Sizing

    private static func blocks(_ byteCount: Int) -> Int {
        (byteCount + sectorSize - 1) / sectorSize
    }

    private static func blocksNeeded(for files: [File],
                                     volumeName: String) -> Int {
        extentsBlocks + catalogNodeCount(for: files, volumeName: volumeName)
            + files.reduce(0) {
                $0 + blocks($1.dataFork.count)
                    + blocks($1.resourceFork.count)
            }
    }

    private static func availableBlocks(in capacity: Capacity) -> Int {
        capacity.totalSectors - overheadSectors
    }

    // MARK: - Catalog records (IM:F 2-70)

    private static func catalogRecord(parent: UInt32, name: String,
                                      payload: [UInt8]) -> Data {
        let nameBytes = pascal(name, max: 31) ?? [0]
        var key = [UInt8]()
        key.append(UInt8(5 + nameBytes.count))   // ckrKeyLen: bytes after it
        key.append(0)                            // ckrResrv1
        append32(parent, &key)
        key.append(contentsOf: nameBytes)
        if key.count % 2 != 0 { key.append(0) }  // records start even
        return Data(key + payload)
    }

    private static func directoryRecord(id: UInt32, valence: UInt16,
                                        date: UInt32) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 70)
        record[0] = 1                            // cdrType: directory
        put16(valence, &record, 4)               // dirVal
        put32(id, &record, 6)                    // dirDirID
        put32(date, &record, 10)                 // dirCrDat
        put32(date, &record, 14)                 // dirMdDat
        return record
    }

    private static func threadRecord(parent: UInt32,
                                     name: String) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 46)
        record[0] = 3                            // cdrType: dir thread
        put32(parent, &record, 10)               // thdParID
        let nameBytes = pascal(name, max: 31) ?? [0]
        record.replaceSubrange(14..<(14 + nameBytes.count),
                               with: nameBytes)
        return record
    }

    private static func fileRecord(
        file: File, id: UInt32, date: UInt32,
        placement: (dataStart: Int, dataBlocks: Int,
                    rsrcStart: Int, rsrcBlocks: Int)) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 102)
        record[0] = 2                            // cdrType: file
        // filUsrWds: the FInfo the Finder reads.
        record.replaceSubrange(4..<8, with: fourMacRoman(file.type))
        record.replaceSubrange(8..<12, with: fourMacRoman(file.creator))
        put16(file.finderFlags, &record, 12)
        put32(id, &record, 20)                   // filFlNum
        put16(UInt16(placement.dataStart), &record, 24)  // filStBlk
        put32(UInt32(file.dataFork.count), &record, 26)  // filLgLen
        put32(UInt32(placement.dataBlocks * sectorSize), &record, 30)
        put16(UInt16(placement.rsrcStart), &record, 34)  // filRStBlk
        put32(UInt32(file.resourceFork.count), &record, 36)
        put32(UInt32(placement.rsrcBlocks * sectorSize), &record, 40)
        put32(date, &record, 44)                 // filCrDat
        put32(date, &record, 48)                 // filMdDat
        // filExtRec / filRExtRec: first extent carries the whole fork.
        put16(UInt16(placement.dataStart), &record, 74)
        put16(UInt16(placement.dataBlocks), &record, 76)
        put16(UInt16(placement.rsrcStart), &record, 86)
        put16(UInt16(placement.rsrcBlocks), &record, 88)
        return record
    }

    // MARK: - B*-tree nodes (IM:F 2-64)

    private static func bTreeHeaderNode(depth: Int, root: Int, records: Int,
                                        firstLeaf: Int, lastLeaf: Int,
                                        keyLength: Int, nodes: Int,
                                        free: Int) -> Data {
        var node = Data(count: sectorSize)
        var header = [UInt8](repeating: 0, count: 106)
        put16(UInt16(depth), &header, 0)
        put32(UInt32(root), &header, 2)
        put32(UInt32(records), &header, 6)
        put32(UInt32(firstLeaf), &header, 10)
        put32(UInt32(lastLeaf), &header, 14)
        put16(UInt16(sectorSize), &header, 18)
        put16(UInt16(keyLength), &header, 20)
        put32(UInt32(nodes), &header, 22)
        put32(UInt32(free), &header, 26)
        var map = [UInt8](repeating: 0, count: 256)
        for used in 0..<(nodes - free) { map[used / 8] |= 0x80 >> (used % 8) }
        writeNode(records: [Data(header),
                            Data(repeating: 0, count: 128),
                            Data(map)],
                  type: 1, height: 0, forwardLink: 0, backwardLink: 0,
                  into: &node)
        return node
    }

    /// Node descriptor, records packed from offset 14, and the offset
    /// stack growing back from the node's end - the shape every HFS
    /// B*-tree node shares.
    private static func writeNode(records: [Data], type: UInt8,
                                  height: UInt8, forwardLink: UInt32,
                                  backwardLink: UInt32,
                                  into node: inout Data) {
        node[0] = UInt8(forwardLink >> 24)
        node[1] = UInt8((forwardLink >> 16) & 0xff)
        node[2] = UInt8((forwardLink >> 8) & 0xff)
        node[3] = UInt8(forwardLink & 0xff)
        node[4] = UInt8(backwardLink >> 24)
        node[5] = UInt8((backwardLink >> 16) & 0xff)
        node[6] = UInt8((backwardLink >> 8) & 0xff)
        node[7] = UInt8(backwardLink & 0xff)
        node[8] = type
        node[9] = height
        node[10] = UInt8(records.count >> 8)
        node[11] = UInt8(records.count & 0xff)
        var offset = 14
        var offsets: [Int] = []
        for record in records {
            offsets.append(offset)
            node.replaceSubrange(offset..<(offset + record.count),
                                 with: record)
            offset += record.count
        }
        offsets.append(offset)
        for (index, value) in offsets.enumerated() {
            let position = node.count - 2 * (index + 1)
            node[position] = UInt8(value >> 8)
            node[position + 1] = UInt8(value & 0xff)
        }
    }

    // MARK: - Name ordering

    /// Apple's HFS relative-ordering table: case-insensitive with the
    /// classic diacritic rules, byte-indexed over MacRoman. Via machfs 1.3
    /// (MIT License, Copyright (c) Elliot Nunn); the values are Apple's.
    private static let relativeOrder: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x22, 0x23, 0x28,
        0x29, 0x2A, 0x2B, 0x2C, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42,
        0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x58, 0x5A, 0x5E, 0x60, 0x67, 0x69,
        0x6B, 0x6D, 0x73, 0x75, 0x77, 0x79, 0x7B, 0x7F, 0x8D, 0x8F, 0x91, 0x93,
        0x96, 0x98, 0x9F, 0xA1, 0xA3, 0xA5, 0xA8, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE,
        0x54, 0x48, 0x58, 0x5A, 0x5E, 0x60, 0x67, 0x69, 0x6B, 0x6D, 0x73, 0x75,
        0x77, 0x79, 0x7B, 0x7F, 0x8D, 0x8F, 0x91, 0x93, 0x96, 0x98, 0x9F, 0xA1,
        0xA3, 0xA5, 0xA8, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3, 0x4C, 0x50, 0x5C, 0x62,
        0x7D, 0x81, 0x9A, 0x55, 0x4A, 0x56, 0x4C, 0x4E, 0x50, 0x5C, 0x62, 0x64,
        0x65, 0x66, 0x6F, 0x70, 0x71, 0x72, 0x7D, 0x89, 0x8A, 0x8B, 0x81, 0x83,
        0x9C, 0x9D, 0x9E, 0x9A, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0x95,
        0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0x52, 0x85, 0xC1, 0xC2, 0xC3, 0xC4,
        0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0x57, 0x8C, 0xCC, 0x52, 0x85,
        0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3, 0x26, 0x27, 0xD4, 0x20, 0x4A,
        0x4E, 0x83, 0x87, 0x87, 0xD5, 0xD6, 0x24, 0x25, 0x2D, 0x2E, 0xD7, 0xD8,
        0xA7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE2, 0xE3,
        0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF,
        0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB,
        0xFC, 0xFD, 0xFE, 0xFF,
    ]

    private static func orderedBefore(_ left: String,
                                      _ right: String) -> Bool {
        let a = (left.data(using: .macOSRoman) ?? Data())
            .map { relativeOrder[Int($0)] }
        let b = (right.data(using: .macOSRoman) ?? Data())
            .map { relativeOrder[Int($0)] }
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    // MARK: - Little helpers

    private static func pascal(_ text: String, max: Int) -> [UInt8]? {
        guard let bytes = text.data(using: .macOSRoman),
              bytes.count <= max else { return nil }
        return [UInt8(bytes.count)] + [UInt8](bytes)
    }

    private static func fourMacRoman(_ value: String) -> [UInt8] {
        let bytes = [UInt8](value.data(using: .macOSRoman) ?? Data())
        return bytes.count == 4 ? bytes : Array("????".utf8)
    }

    /// Seconds since 1904-01-01 00:00:00 GMT, the classic epoch.
    private static func macDate(_ date: Date) -> UInt32 {
        let epoch = Date(timeIntervalSince1970: -2_082_844_800)
        let seconds = date.timeIntervalSince(epoch)
        guard seconds > 0, seconds < Double(UInt32.max) else { return 0 }
        return UInt32(seconds)
    }

    private static func write(_ data: Data, toBlock block: Int,
                              in disk: inout Data) {
        guard !data.isEmpty else { return }
        let start = (4 + block) * sectorSize   // drAlBlSt = 4
        disk.replaceSubrange(start..<(start + data.count), with: data)
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

    private static func append32(_ value: UInt32, _ bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }
}
