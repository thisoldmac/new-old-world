import Darwin
import Foundation

struct MacBinaryFile: Equatable {
    let name: String
    let type: String
    let creator: String
    let finderFlags: UInt16
    let dataFork: Data
    let resourceFork: Data

    enum DecodeError: LocalizedError {
        case invalid
        case invalidName
        case couldNotWriteFork(String)
        case couldNotWriteFinderInfo

        var errorDescription: String? {
            switch self {
            case .invalid:
                return "The package is not a complete MacBinary file."
            case .invalidName:
                return "The package has no usable classic Mac file name."
            case .couldNotWriteFork(let name):
                return "The (name) fork could not be written to the setup image."
            case .couldNotWriteFinderInfo:
                return "The Finder type and creator could not be written to "
                    + "the setup image."
            }
        }
    }

    static func decode(_ data: Data) throws -> MacBinaryFile {
        guard data.count >= 128,
              OutboundFile.validMacBinaryHeader(
                Data(data.prefix(128)), totalBytes: data.count) else {
            throw DecodeError.invalid
        }
        let bytes = [UInt8](data)
        let nameLength = Int(bytes[1])
        guard let name = String(
            bytes: bytes[2..<(2 + nameLength)], encoding: .macOSRoman),
              !name.isEmpty else { throw DecodeError.invalidName }
        let dataLength = Int(bigEndianUInt32(bytes, at: 83))
        let resourceLength = Int(bigEndianUInt32(bytes, at: 87))
        let resourceStart = 128 + padded(dataLength)
        return MacBinaryFile(
            name: name,
            type: String(bytes: bytes[65..<69], encoding: .macOSRoman)
                ?? "????",
            creator: String(bytes: bytes[69..<73], encoding: .macOSRoman)
                ?? "????",
            finderFlags: UInt16(bytes[73]) << 8 | UInt16(bytes[101]),
            dataFork: Data(bytes[128..<(128 + dataLength)]),
            resourceFork: Data(bytes[resourceStart..<(resourceStart
                + resourceLength)]))
    }

    func write(to directory: URL, nameOverride: String? = nil,
               fileManager: FileManager = .default)
        throws -> URL {
        let destination = directory.appendingPathComponent(
            ClassicName.project(nameOverride ?? name), isDirectory: false)
        guard fileManager.createFile(atPath: destination.path,
                                     contents: dataFork) else {
            throw DecodeError.couldNotWriteFork("data")
        }
        if !resourceFork.isEmpty {
            let resourceURL = URL(fileURLWithPath:
                destination.path + "/..namedfork/rsrc")
            do {
                try resourceFork.write(to: resourceURL)
            } catch {
                throw DecodeError.couldNotWriteFork("resource")
            }
        }

        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo.replaceSubrange(0..<4,
            with: fourMacRomanBytes(type) ?? Array("????".utf8))
        finderInfo.replaceSubrange(4..<8,
            with: fourMacRomanBytes(creator) ?? Array("????".utf8))
        finderInfo[8] = UInt8(finderFlags >> 8)
        finderInfo[9] = UInt8(finderFlags & 0xff)
        let result = destination.path.withCString { path in
            "com.apple.FinderInfo".withCString { attribute in
                finderInfo.withUnsafeBytes { bytes in
                    setxattr(path, attribute, bytes.baseAddress,
                             bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw DecodeError.couldNotWriteFinderInfo
        }
        return destination
    }

    private static func bigEndianUInt32(_ bytes: [UInt8],
                                        at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func padded(_ count: Int) -> Int {
        (count + 127) / 128 * 128
    }

    private func fourMacRomanBytes(_ value: String) -> [UInt8]? {
        guard let data = value.data(using: .macOSRoman), data.count == 4
        else { return nil }
        return [UInt8](data)
    }
}
