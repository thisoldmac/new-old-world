import Darwin
import Foundation

/// Reads and writes the pieces of one classic file without pretending its
/// resource fork or Finder identity are Unix path attributes. Project.ckp is
/// the portable declaration; these are the host working-copy adapters.
enum ClassicProjectFile {
    struct Identity: Equatable, Sendable {
        let type: String
        let creator: String
        let finderFlags: UInt16
    }

    static func resourceFork(at url: URL) throws -> Data {
        let fork = URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
        do { return try Data(contentsOf: fork) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError { return Data() }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && error.code == ENOENT { return Data() }
    }

    static func writeResourceFork(_ data: Data, to url: URL) throws {
        let fork = URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
        try data.write(to: fork)
    }

    static func identity(at url: URL) -> Identity? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = url.path.withCString { path in
            "com.apple.FinderInfo".withCString { name in
                bytes.withUnsafeMutableBytes { value in
                    getxattr(path, name, value.baseAddress, value.count, 0, 0)
                }
            }
        }
        guard count >= 10 else { return nil }
        let type = String(bytes: bytes[0..<4], encoding: .macOSRoman) ?? "????"
        let creator = String(bytes: bytes[4..<8], encoding: .macOSRoman) ?? "????"
        return Identity(type: type, creator: creator,
                        finderFlags: UInt16(bytes[8]) << 8 | UInt16(bytes[9]))
    }

    static func setIdentity(_ identity: Identity, at url: URL) throws {
        guard let type = identity.type.data(using: .macOSRoman), type.count == 4,
              let creator = identity.creator.data(using: .macOSRoman),
              creator.count == 4 else {
            throw ProjectStoreError.invalidProject(
                "Classic file type and creator must each be four MacRoman bytes.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.replaceSubrange(0..<4, with: type)
        bytes.replaceSubrange(4..<8, with: creator)
        bytes[8] = UInt8(identity.finderFlags >> 8)
        bytes[9] = UInt8(identity.finderFlags & 0xff)
        let result = url.path.withCString { path in
            "com.apple.FinderInfo".withCString { name in
                bytes.withUnsafeBytes { value in
                    setxattr(path, name, value.baseAddress, value.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw ProjectStoreError.unavailable(
                "Finder metadata could not be written for \(url.lastPathComponent).")
        }
    }
}
