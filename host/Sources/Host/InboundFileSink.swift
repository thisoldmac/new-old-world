import Foundation

/// A file arriving over the bulk channel.
///
/// The wire is already chunked; this is the adapter that preserves that
/// bound on the host. Bytes go straight to a same-folder temporary file,
/// with only the current protocol frame resident in memory.
final class InboundFileSink {
    enum SinkError: LocalizedError {
        case invalidLength
        case insufficientSpace(available: Int64, needed: Int64)
        case tooManyBytes(expected: Int, received: Int)
        case truncated(expected: Int, received: Int)
        case corrupt(expected: UInt32, received: UInt32)

        var errorDescription: String? {
            switch self {
            case .invalidLength:
                return "the sender announced an invalid file length"
            case .insufficientSpace(let available, let needed):
                return "not enough disk space (\(available) bytes free, "
                    + "\(needed) needed)"
            case .tooManyBytes(let expected, let received):
                return "the file exceeded its announced length "
                    + "(\(received) of \(expected) bytes)"
            case .truncated(let expected, let received):
                return "the file arrived truncated "
                    + "(\(received) of \(expected) bytes)"
            case .corrupt(let expected, let received):
                return String(
                    format: "the checksum did not match "
                        + "(expected %08x, received %08x)",
                    expected, received)
            }
        }
    }

    /// Owns a completed temporary file until a consumer atomically moves
    /// or converts it. Dropping a delivery without consuming it cannot
    /// leave an orphan behind.
    final class StagedFile {
        let url: URL
        let byteCount: Int
        private var owned = true

        fileprivate init(url: URL, byteCount: Int) {
            self.url = url
            self.byteCount = byteCount
        }

        func relinquish() {
            owned = false
        }

        deinit {
            if owned {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    let temporaryURL: URL
    let expectedBytes: Int
    private var handle: FileHandle?
    private(set) var receivedBytes = 0
    private(set) var maximumAppendBytes = 0
    private var lastReportedBytes = 0
    private var crc32 = TransferIdentity.CRC32()
    private var ownsTemporaryFile = true

    init(directory: URL, expectedBytes: Int) throws {
        guard expectedBytes >= 0 else { throw SinkError.invalidLength }
        self.expectedBytes = expectedBytes

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        try Self.requireAvailableSpace(in: directory, bytes: expectedBytes)

        temporaryURL = directory.appendingPathComponent(
            ".now-\(UUID().uuidString).part")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let opened = try FileHandle(forWritingTo: temporaryURL)
            /* This establishes the promised length before the transfer.
               APFS may represent it sparsely, so the free-space check
               above remains the actual preflight. */
            try opened.truncate(atOffset: UInt64(expectedBytes))
            try opened.seek(toOffset: 0)
            handle = opened
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func append(_ bytes: Data) throws {
        guard bytes.count <= expectedBytes - receivedBytes else {
            let received = receivedBytes.addingReportingOverflow(bytes.count)
            let actual = received.overflow ? Int.max : received.partialValue
            abort()
            throw SinkError.tooManyBytes(expected: expectedBytes,
                                         received: actual)
        }
        let next = receivedBytes + bytes.count
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            abort()
            throw error
        }
        crc32.update(bytes)
        receivedBytes = next
        maximumAppendBytes = max(maximumAppendBytes, bytes.count)
    }

    /// Progress is advisory. Reporting every small wire frame wastes
    /// control traffic and UI work, while a final report must never be
    /// suppressed.
    func takeProgressReport() -> Int? {
        let interval = 32 * 1024
        guard receivedBytes == expectedBytes
                || receivedBytes - lastReportedBytes >= interval else {
            return nil
        }
        lastReportedBytes = receivedBytes
        return receivedBytes
    }

    func finish(expectedCRC32: UInt32?) throws -> StagedFile {
        guard receivedBytes == expectedBytes else {
            let error = SinkError.truncated(
                expected: expectedBytes, received: receivedBytes)
            abort()
            throw error
        }
        if let expectedCRC32, crc32.checksum != expectedCRC32 {
            let error = SinkError.corrupt(
                expected: expectedCRC32, received: crc32.checksum)
            abort()
            throw error
        }
        do {
            try handle?.synchronize()
            try handle?.close()
        } catch {
            abort()
            throw error
        }
        handle = nil
        ownsTemporaryFile = false
        return StagedFile(url: temporaryURL, byteCount: receivedBytes)
    }

    func abort() {
        try? handle?.close()
        handle = nil
        if ownsTemporaryFile {
            try? FileManager.default.removeItem(at: temporaryURL)
            ownsTemporaryFile = false
        }
    }

    deinit {
        abort()
    }

    static func requireAvailableSpace(in directory: URL, bytes: Int) throws {
        guard bytes >= 0 else { throw SinkError.invalidLength }
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: directory.path)
        if let available = (attributes[.systemFreeSize] as? NSNumber)?
            .int64Value {
            let needed = Int64(bytes)
            guard available >= needed else {
                throw SinkError.insufficientSpace(
                    available: available, needed: needed)
            }
        }
    }
}
