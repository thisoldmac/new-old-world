import Darwin
import Foundation

/// One sealed, file-backed source for the existing guest transfer lane.
///
/// The URL is private command state. Callers receive only an opaque upload
/// ID, and the source revalidates its inode, size, owner, link count and
/// read-only mode before the first bulk frame is read.
struct OutboundFileSource {
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
    }

    enum SourceError: Error {
        case changed
        case unreadable
    }

    let url: URL
    let byteCount: Int
    let crc32: UInt32
    let sha256: String
    let identity: Identity
    let expectedUID: uid_t

    func openReader() throws -> Reader {
        try Reader(source: self)
    }

    final class Reader: @unchecked Sendable {
        let byteCount: Int
        let crc32: UInt32
        private let descriptor: Int32

        fileprivate init(source: OutboundFileSource) throws {
            let descriptor = open(
                source.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw SourceError.unreadable
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == source.expectedUID,
                  status.st_nlink == 1,
                  status.st_mode & 0o222 == 0,
                  status.st_size == source.byteCount,
                  Identity(
                    device: status.st_dev,
                    inode: status.st_ino,
                    size: status.st_size) == source.identity else {
                close(descriptor)
                throw SourceError.changed
            }
            self.descriptor = descriptor
            byteCount = source.byteCount
            crc32 = source.crc32
        }

        deinit {
            close(descriptor)
        }

        func read(offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0,
                  offset <= byteCount,
                  count <= byteCount - offset else {
                throw SourceError.unreadable
            }
            var data = Data(count: count)
            var completed = 0
            while completed < count {
                let readCount = data.withUnsafeMutableBytes { bytes in
                    pread(
                        descriptor,
                        bytes.baseAddress!.advanced(by: completed),
                        count - completed,
                        off_t(offset + completed))
                }
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else {
                    throw SourceError.changed
                }
                completed += readCount
            }
            return data
        }

        func readAsync(offset: Int, count: Int) async throws -> Data {
            try await Task.detached {
                try self.read(offset: offset, count: count)
            }.value
        }
    }
}
