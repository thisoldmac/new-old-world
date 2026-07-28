import CryptoKit
import Darwin
import Foundation
import NOWAgentIntegration

/// Private disk staging for caller-supplied upload bytes.
///
/// The caller never supplies a host path. It gets an opaque ID, writes
/// sequential bounded chunks, and can commit only after the declared size and
/// SHA-256 match. Disk allocation is reserved up front; the policy leaves five
/// percent of currently available capacity untouched instead of imposing an
/// arbitrary file-size ceiling.
actor GuestUploadStagingStore {
    struct Capacity: Equatable {
        let availableBytes: Int64
        let policyHeadroomBytes: Int64

        var usableBytes: Int64 {
            max(0, availableBytes - policyHeadroomBytes)
        }
    }

    struct Status: Equatable {
        let uploadID: UUID
        let expectedBytes: Int
        let receivedBytes: Int
        let maximumChunkBytes: Int
        let expiresAt: Date
        let hostAvailableBytesAtStart: Int64
        let hostReservedBytes: Int
        let sealed: Bool
    }

    struct SealedUpload {
        let status: Status
        let source: OutboundFileSource
    }

    struct StoreFailure: Error, Equatable {
        let code: String
        let message: String
    }

    enum CleanupDisposition: String, Equatable, Sendable {
        case removed = "removed-after-attempt"
        case cleanupNeeded = "cleanup-needed"
        case alreadyMissing = "already-missing"
    }

    static let maximumChunkBytes =
        AgentIntegrationGuestFilePolicy.maximumUploadChunkBytes
    static let lifetime: TimeInterval = 10 * 60
    static let maximumWireBytes = Int(Int32.max)

    private struct Record {
        let id: UUID
        let url: URL
        let expectedBytes: Int
        let expectedSHA256: String
        let createdAt: Date
        let expiresAt: Date
        let hostAvailableBytesAtStart: Int64
        var receivedBytes: Int
        var sha256: SHA256
        var crc32: TransferIdentity.CRC32
        var sealedSource: OutboundFileSource?
    }

    private let rootURL: URL
    private let expectedUID: uid_t
    private let clock: () -> Date
    private let capacity: () throws -> Capacity
    private let removeItem: (URL) throws -> Void
    private var records: [UUID: Record] = [:]
    private var consumed: [UUID] = []
    nonisolated let recoveredOrphanCount: Int

    init(
        rootURL: URL? = nil,
        expectedUID: uid_t = geteuid(),
        clock: @escaping () -> Date = Date.init,
        capacity: (() throws -> Capacity)? = nil,
        removeItem: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) throws {
        self.expectedUID = expectedUID
        self.clock = clock
        self.removeItem = removeItem
        if let rootURL {
            self.rootURL = rootURL
            self.recoveredOrphanCount = 0
        } else {
            let endpoint = try AgentIntegrationEndpoint.currentUser(
                uid: expectedUID)
            try Self.createPrivateDirectory(
                endpoint.directoryURL, uid: expectedUID)
            self.recoveredOrphanCount =
                Self.removeOrphanedUploadDirectories(
                    in: endpoint.directoryURL,
                    uid: expectedUID)
            self.rootURL = endpoint.directoryURL.appendingPathComponent(
                "uploads-\(getpid())-\(UUID().uuidString.lowercased())",
                isDirectory: true)
        }
        try Self.createPrivateDirectory(self.rootURL, uid: expectedUID)
        if let capacity {
            self.capacity = capacity
        } else {
            let root = self.rootURL
            self.capacity = {
                let values = try root.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey,
                ])
                guard let available =
                    values.volumeAvailableCapacityForImportantUsage,
                      available >= 0 else {
                    throw StoreFailure(
                        code: "now-files-host-space-unknown",
                        message:
                            "NOW could not determine private staging capacity")
                }
                let headroom = available / 20
                return Capacity(
                    availableBytes: available,
                    policyHeadroomBytes: headroom)
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func begin(expectedBytes: Int, expectedSHA256: String)
        -> Result<Status, StoreFailure> {
        pruneExpired()
        guard expectedBytes >= 0,
              expectedBytes <= Self.maximumWireBytes else {
            return .failure(.init(
                code: "now-files-size-invalid",
                message:
                    "Upload size is outside the guest wire representation"))
        }
        guard AgentIntegrationGuestFilePolicy.isCanonicalSHA256(
                expectedSHA256) else {
            return .failure(.init(
                code: "now-files-digest-invalid",
                message: "Upload SHA-256 must be 64 lowercase hex digits"))
        }

        do {
            let disk = try capacity()
            let outstanding = records.values.reduce(Int64(0)) {
                $0 + Int64($1.expectedBytes)
            }
            guard Int64(expectedBytes)
                    <= max(0, disk.usableBytes - outstanding) else {
                return .failure(.init(
                    code: "now-files-insufficient-host-space",
                    message:
                        "Private staging cannot reserve the declared upload"))
            }
            let id = UUID()
            let url = rootURL.appendingPathComponent(
                id.uuidString.lowercased() + ".upload")
            try createReservedFile(url, bytes: expectedBytes)
            let now = clock()
            let record = Record(
                id: id,
                url: url,
                expectedBytes: expectedBytes,
                expectedSHA256: expectedSHA256,
                createdAt: now,
                expiresAt: now.addingTimeInterval(Self.lifetime),
                hostAvailableBytesAtStart: disk.availableBytes,
                receivedBytes: 0,
                sha256: SHA256(),
                crc32: TransferIdentity.CRC32(),
                sealedSource: nil)
            records[id] = record
            return .success(status(record))
        } catch let failure as StoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.init(
                code: "now-files-staging-unavailable",
                message: "NOW could not reserve private upload staging"))
        }
    }

    func append(uploadID: UUID, offset: Int, bytes: Data)
        -> Result<Status, StoreFailure> {
        pruneExpired()
        guard var record = records[uploadID] else {
            return missing(uploadID)
        }
        guard record.sealedSource == nil else {
            return .failure(.init(
                code: "now-files-upload-sealed",
                message: "The staged upload is already sealed"))
        }
        guard !bytes.isEmpty,
              bytes.count <= Self.maximumChunkBytes else {
            return .failure(.init(
                code: "now-files-chunk-invalid",
                message:
                    "Upload chunks must contain 1 through \(Self.maximumChunkBytes) bytes"))
        }
        guard offset == record.receivedBytes else {
            return .failure(.init(
                code: "now-files-upload-offset-conflict",
                message:
                    "The upload chunk offset does not match the staged receipt"))
        }
        guard bytes.count <= record.expectedBytes - record.receivedBytes
        else {
            return .failure(.init(
                code: "now-files-upload-overflow",
                message: "The upload chunk exceeds the declared size"))
        }
        do {
            try write(
                bytes, to: record.url, offset: record.receivedBytes)
            record.sha256.update(data: bytes)
            record.crc32.update(bytes)
            record.receivedBytes += bytes.count
            records[uploadID] = record
            return .success(status(record))
        } catch let failure as StoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.init(
                code: "now-files-staging-unavailable",
                message: "NOW could not write the private upload stage"))
        }
    }

    func seal(uploadID: UUID) -> Result<SealedUpload, StoreFailure> {
        pruneExpired()
        guard var record = records[uploadID] else {
            return missing(uploadID)
        }
        if let source = record.sealedSource {
            return .success(.init(
                status: status(record), source: source))
        }
        guard record.receivedBytes == record.expectedBytes else {
            return .failure(.init(
                code: "now-files-upload-incomplete",
                message:
                    "The staged upload has not received its declared bytes"))
        }
        let digest = record.sha256.finalize()
            .map { String(format: "%02x", $0) }.joined()
        guard digest == record.expectedSHA256 else {
            _ = discard(uploadID)
            return .failure(.init(
                code: "now-files-integrity-failed",
                message: "The staged upload SHA-256 did not match"))
        }
        do {
            let source = try sealFile(
                record.url,
                byteCount: record.expectedBytes,
                crc32: record.crc32.checksum,
                sha256: digest)
            record.sealedSource = source
            records[uploadID] = record
            return .success(.init(
                status: status(record), source: source))
        } catch let failure as StoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.init(
                code: "now-files-staging-unavailable",
                message: "NOW could not seal the private upload stage"))
        }
    }

    func finish(uploadID: UUID) -> CleanupDisposition {
        let cleanup = discard(uploadID)
        consumed.append(uploadID)
        if consumed.count > 64 {
            consumed.removeFirst(consumed.count - 64)
        }
        return cleanup
    }

    @discardableResult
    func discard(_ uploadID: UUID) -> CleanupDisposition {
        guard let record = records[uploadID] else {
            return .alreadyMissing
        }
        do {
            try removeItem(record.url)
            records.removeValue(forKey: uploadID)
            return .removed
        } catch CocoaError.fileNoSuchFile {
            records.removeValue(forKey: uploadID)
            return .alreadyMissing
        } catch {
            return .cleanupNeeded
        }
    }

    private func missing<T>(_ uploadID: UUID) -> Result<T, StoreFailure> {
        if consumed.contains(uploadID) {
            return .failure(.init(
                code: "now-files-upload-replayed",
                message: "The staged upload was already committed"))
        }
        return .failure(.init(
            code: "now-files-upload-expired",
            message: "The staged upload is missing or expired"))
    }

    private func status(_ record: Record) -> Status {
        .init(
            uploadID: record.id,
            expectedBytes: record.expectedBytes,
            receivedBytes: record.receivedBytes,
            maximumChunkBytes: Self.maximumChunkBytes,
            expiresAt: record.expiresAt,
            hostAvailableBytesAtStart: record.hostAvailableBytesAtStart,
            hostReservedBytes: record.expectedBytes,
            sealed: record.sealedSource != nil)
    }

    private func pruneExpired() {
        let now = clock()
        let expired = records.values.filter { $0.expiresAt < now }
        for record in expired {
            _ = discard(record.id)
        }
    }

    private func createReservedFile(_ url: URL, bytes: Int) throws {
        let descriptor = open(
            url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw StoreFailure(
                code: "now-files-staging-unavailable",
                message: "NOW could not create private upload staging")
        }
        var keep = false
        defer {
            close(descriptor)
            if !keep { unlink(url.path) }
        }
        if bytes > 0 {
            var allocation = fstore_t(
                fst_flags: UInt32(F_ALLOCATEALL),
                fst_posmode: F_PEOFPOSMODE,
                fst_offset: 0,
                fst_length: off_t(bytes),
                fst_bytesalloc: 0)
            guard fcntl(descriptor, F_PREALLOCATE, &allocation) != -1,
                  ftruncate(descriptor, off_t(bytes)) == 0 else {
                throw StoreFailure(
                    code: "now-files-insufficient-host-space",
                    message:
                        "Private staging could not reserve the declared bytes")
            }
        }
        keep = true
    }

    private func write(_ data: Data, to url: URL, offset: Int) throws {
        let descriptor = open(
            url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StoreFailure(
                code: "now-files-staging-unavailable",
                message: "The private upload stage is unavailable")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == expectedUID,
              status.st_nlink == 1,
              status.st_mode & 0o222 != 0 else {
            throw StoreFailure(
                code: "now-files-staging-changed",
                message: "The private upload stage changed")
        }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = pwrite(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    buffer.count - written,
                    off_t(offset + written))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw StoreFailure(
                        code: "now-files-staging-unavailable",
                        message:
                            "The private upload stage could not be written")
                }
                written += count
            }
        }
    }

    private func sealFile(
        _ url: URL,
        byteCount: Int,
        crc32: UInt32,
        sha256: String
    ) throws -> OutboundFileSource {
        let descriptor = open(
            url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StoreFailure(
                code: "now-files-staging-unavailable",
                message: "The private upload stage cannot be sealed")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0,
              fchmod(descriptor, 0o400) == 0 else {
            throw StoreFailure(
                code: "now-files-staging-unavailable",
                message: "The private upload stage cannot be sealed")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == expectedUID,
              status.st_nlink == 1,
              status.st_mode & 0o222 == 0,
              status.st_size == byteCount else {
            throw StoreFailure(
                code: "now-files-staging-changed",
                message: "The sealed upload identity changed")
        }
        return OutboundFileSource(
            url: url,
            byteCount: byteCount,
            crc32: crc32,
            sha256: sha256,
            identity: .init(
                device: status.st_dev,
                inode: status.st_ino,
                size: status.st_size),
            expectedUID: expectedUID)
    }

    private static func createPrivateDirectory(
        _ url: URL,
        uid: uid_t
    ) throws {
        let result = mkdir(url.path, 0o700)
        guard result == 0 || errno == EEXIST else {
            throw StoreFailure(
                code: "now-files-staging-unavailable",
                message: "NOW could not create private upload staging")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == uid,
              status.st_mode & 0o077 == 0 else {
            throw StoreFailure(
                code: "now-files-staging-unsafe",
                message: "The private upload staging directory is unsafe")
        }
    }

    /// Removes only private upload directories whose owning process no longer
    /// exists. PID reuse deliberately leaves an orphan behind; retaining a
    /// private stage is safer than deleting a live one.
    static func removeOrphanedUploadDirectories(
        in parent: URL,
        uid: uid_t
    ) -> Int {
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return 0
        }
        var removed = 0
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("uploads-") else { continue }
            let remainder = name.dropFirst("uploads-".count)
            guard let separator = remainder.firstIndex(of: "-"),
                  let pid = pid_t(remainder[..<separator]),
                  pid != getpid(),
                  kill(pid, 0) == -1,
                  errno == ESRCH,
                  isSafeOrphanDirectory(candidate, uid: uid),
                  let children =
                    try? FileManager.default.contentsOfDirectory(
                        at: candidate,
                        includingPropertiesForKeys: nil),
                  children.allSatisfy({
                      isSafeUploadFile($0, uid: uid)
                  })
            else {
                continue
            }
            for child in children {
                _ = unlink(child.path)
            }
            if rmdir(candidate.path) == 0 {
                removed += 1
            }
        }
        return removed
    }

    private static func isSafeOrphanDirectory(
        _ url: URL,
        uid: uid_t
    ) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == uid
            && status.st_mode & 0o077 == 0
    }

    private static func isSafeUploadFile(
        _ url: URL,
        uid: uid_t
    ) -> Bool {
        guard url.pathExtension == "upload" else { return false }
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == uid
            && status.st_nlink == 1
    }

}
