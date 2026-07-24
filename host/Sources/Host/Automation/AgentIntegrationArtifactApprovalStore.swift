import CryptoKit
import Darwin
import Foundation
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif

struct AgentIntegrationArtifactApprovalNotice: Equatable {
    let receipt: String
    let name: String
    let destination: String
    let expiresAt: Date
    let conversion: String?
}

enum AgentIntegrationArtifactApprovalError: Error, Equatable {
    case unavailable(String)
    case refused(String)
}

struct AgentIntegrationRedeemedArtifact {
    let sessionID: UUID
    let approvedAt: Date
    let redeemedAt: Date
    let destination: String
    let modified: Int?
    let source: AgentIntegrationArtifactEvidence
    let plan: OutboundFile.Plan
    let handedToNOW: AgentIntegrationArtifactEvidence
}

enum AgentIntegrationArtifactRedemption {
    case artifact(AgentIntegrationRedeemedArtifact)
    case expired(AgentIntegrationArtifactFailure)
    case refused(AgentIntegrationArtifactFailure)
    case failed(AgentIntegrationArtifactFailure)
}

/// Holds one-use approval authority inside the running NOW host.
///
/// The original path is deliberately never retained. Each record points only
/// at a private read-only copy whose identity and digest are checked again at
/// redemption.
@MainActor
final class AgentIntegrationArtifactApprovalStore {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
    }

    private struct Record {
        let receipt: String
        let sessionID: UUID
        let approvedAt: Date
        let expiresAt: Date
        let originalName: String
        let destination: String
        let convertText: Bool
        let modified: Int?
        let stagingURL: URL
        let identity: FileIdentity
        let sourceDigest: String
        let sourceBytes: Int
    }

    private static let maximumOutstandingApprovals = 16

    private let rootURL: URL
    private let expectedUID: uid_t
    private var records: [String: Record] = [:]
    private var consumed: [String] = []

    init(rootURL: URL? = nil, expectedUID: uid_t = geteuid()) throws {
        self.expectedUID = expectedUID
        if let rootURL {
            self.rootURL = rootURL
            try Self.createPrivateDirectory(rootURL, uid: expectedUID)
        } else {
            let endpoint = try AgentIntegrationEndpoint.currentUser(
                uid: expectedUID)
            try Self.createPrivateDirectory(
                endpoint.directoryURL, uid: expectedUID)
            self.rootURL = endpoint.directoryURL.appendingPathComponent(
                "approvals-\(UUID().uuidString.lowercased())",
                isDirectory: true)
            try Self.createPrivateDirectory(self.rootURL, uid: expectedUID)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func approve(
        sourceURL: URL,
        destination: String,
        convertText: Bool,
        sessionID: UUID,
        approvedAt: Date = Date()
    ) -> Result<AgentIntegrationArtifactApprovalNotice,
                AgentIntegrationArtifactApprovalError> {
        pruneExpired(at: approvedAt)
        guard Self.isValidDestination(destination) else {
            return .failure(.refused(
                "The selected guest destination is not a bounded share folder"))
        }
        guard records.count < Self.maximumOutstandingApprovals else {
            return .failure(.refused(
                "Too many artifact approvals are waiting to be redeemed"))
        }

        do {
            let source = try readStableRegularFile(sourceURL)
            let receipt = AgentIntegrationArtifactPolicy.makeReceipt()
            let stagingURL = rootURL.appendingPathComponent(
                UUID().uuidString.lowercased() + ".artifact")
            let identity = try writePrivateStage(
                source.data, to: stagingURL)
            let digest = Self.sha256(source.data)
            let plan = OutboundFile.plan(
                name: sourceURL.lastPathComponent,
                data: source.data,
                convertText: convertText)
            let expiresAt = approvedAt.addingTimeInterval(
                AgentIntegrationArtifactPolicy.maximumReceiptAge)
            records[receipt] = Record(
                receipt: receipt,
                sessionID: sessionID,
                approvedAt: approvedAt,
                expiresAt: expiresAt,
                originalName: sourceURL.lastPathComponent,
                destination: destination,
                convertText: convertText,
                modified: source.modified,
                stagingURL: stagingURL,
                identity: identity,
                sourceDigest: digest,
                sourceBytes: source.data.count)
            return .success(.init(
                receipt: receipt,
                name: plan.name,
                destination: destination,
                expiresAt: expiresAt,
                conversion: plan.note))
        } catch let error as AgentIntegrationArtifactApprovalError {
            return .failure(error)
        } catch {
            return .failure(.unavailable(
                "New Old World could not create a private artifact approval"))
        }
    }

    func redeem(
        receipt: String,
        sessionID: UUID,
        redeemedAt: Date = Date()
    ) -> AgentIntegrationArtifactRedemption {
        guard AgentIntegrationArtifactPolicy.isValidReceipt(receipt) else {
            return refused(
                "now-artifact-approval-invalid",
                "The artifact approval receipt is invalid")
        }
        if consumed.contains(receipt) {
            return refused(
                "now-artifact-already-redeemed",
                "The artifact approval receipt was already redeemed")
        }
        guard let record = records.removeValue(forKey: receipt) else {
            return refused(
                "now-artifact-approval-invalid",
                "The artifact approval receipt is not current")
        }
        rememberConsumed(receipt)
        defer { try? FileManager.default.removeItem(at: record.stagingURL) }

        guard redeemedAt <= record.expiresAt else {
            return .expired(.init(
                code: "now-artifact-approval-expired",
                message: "The artifact approval receipt has expired"))
        }
        guard record.sessionID == sessionID else {
            return .expired(.init(
                code: "now-artifact-session-expired",
                message:
                    "The artifact approval belongs to an earlier guest session"))
        }

        do {
            let data = try readAndValidateStage(record)
            let sourceDigest = Self.sha256(data)
            guard sourceDigest == record.sourceDigest,
                  data.count == record.sourceBytes else {
                return refused(
                    "now-artifact-staging-changed",
                    "The approved staged artifact changed before redemption")
            }
            let plan = OutboundFile.plan(
                name: record.originalName,
                data: data,
                convertText: record.convertText)
            return .artifact(.init(
                sessionID: sessionID,
                approvedAt: record.approvedAt,
                redeemedAt: redeemedAt,
                destination: record.destination,
                modified: record.modified,
                source: .init(
                    sha256: sourceDigest, bytes: record.sourceBytes),
                plan: plan,
                handedToNOW: .init(
                    sha256: Self.sha256(plan.bytes),
                    bytes: plan.bytes.count)))
        } catch let error as AgentIntegrationArtifactApprovalError {
            switch error {
            case .refused:
                return refused(
                    "now-artifact-staging-changed",
                    "The approved staged artifact changed before redemption")
            case .unavailable:
                return .failed(.init(
                    code: "now-artifact-staging-unavailable",
                    message:
                        "The approved staged artifact could not be opened"))
            }
        } catch {
            return .failed(.init(
                code: "now-artifact-staging-unavailable",
                message: "The approved staged artifact could not be opened"))
        }
    }

    func stagedURL(for receipt: String) -> URL? {
        records[receipt]?.stagingURL
    }

    private func readStableRegularFile(_ url: URL) throws
        -> (data: Data, modified: Int?) {
        let descriptor = open(
            url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "Only a directly selected regular file can be approved")
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <=
                AgentIntegrationArtifactPolicy.maximumSourceBytes else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "Artifact approval accepts one regular file up to 4 MiB")
        }
        let data = try Self.read(
            descriptor, expectedBytes: Int(before.st_size))
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              Self.sameStableFile(before, after),
              data.count == Int(before.st_size) else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The selected artifact changed while it was being approved")
        }
        let modified = ClassicDate.macSeconds(from: Date(
            timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec)
                + TimeInterval(before.st_mtimespec.tv_nsec) / 1_000_000_000))
        return (data, modified)
    }

    private func writePrivateStage(_ data: Data, to url: URL) throws
        -> FileIdentity {
        let descriptor = open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw AgentIntegrationArtifactApprovalError.unavailable(
                "The private artifact staging file could not be created")
        }
        var keep = false
        defer {
            close(descriptor)
            if !keep { unlink(url.path) }
        }
        try Self.write(data, descriptor: descriptor)
        guard fsync(descriptor) == 0,
              fchmod(descriptor, 0o400) == 0 else {
            throw AgentIntegrationArtifactApprovalError.unavailable(
                "The private artifact staging file could not be sealed")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == expectedUID,
              status.st_nlink == 1,
              status.st_mode & 0o222 == 0,
              status.st_size == data.count else {
            throw AgentIntegrationArtifactApprovalError.unavailable(
                "The private artifact staging file was not safely sealed")
        }
        keep = true
        return .init(
            device: status.st_dev,
            inode: status.st_ino,
            size: status.st_size)
    }

    private func readAndValidateStage(_ record: Record) throws -> Data {
        let descriptor = open(
            record.stagingURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The staged artifact is no longer a direct regular file")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == expectedUID,
              before.st_nlink == 1,
              before.st_mode & 0o222 == 0,
              FileIdentity(
                device: before.st_dev,
                inode: before.st_ino,
                size: before.st_size) == record.identity else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The staged artifact identity changed")
        }
        let data = try Self.read(
            descriptor, expectedBytes: Int(before.st_size))
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              Self.sameStableFile(before, after),
              data.count == Int(before.st_size) else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The staged artifact changed while it was opened")
        }
        return data
    }

    private func pruneExpired(at date: Date) {
        let expired = records.values.filter { $0.expiresAt < date }
        for record in expired {
            records.removeValue(forKey: record.receipt)
            try? FileManager.default.removeItem(at: record.stagingURL)
        }
    }

    private func rememberConsumed(_ receipt: String) {
        consumed.append(receipt)
        if consumed.count > 32 {
            consumed.removeFirst(consumed.count - 32)
        }
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationArtifactRedemption {
        .refused(.init(code: code, message: message))
    }

    private static func createPrivateDirectory(
        _ url: URL,
        uid: uid_t
    ) throws {
        let result = mkdir(url.path, 0o700)
        guard result == 0 || errno == EEXIST else {
            throw AgentIntegrationArtifactApprovalError.unavailable(
                "The private artifact staging directory could not be created")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == uid,
              status.st_mode & 0o077 == 0 else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The private artifact staging directory is unsafe")
        }
    }

    private static func isValidDestination(_ path: String) -> Bool {
        if path.isEmpty { return true }
        let components = path.split(
            separator: ":", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0.count <= 31 && !$0.contains("/")
        }
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func read(_ descriptor: Int32, expectedBytes: Int) throws
        -> Data {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < expectedBytes {
            let count = Darwin.read(
                descriptor, &buffer, min(buffer.count,
                                         expectedBytes - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw AgentIntegrationArtifactApprovalError.unavailable(
                    "The artifact could not be read completely")
            }
            data.append(contentsOf: buffer[..<count])
        }
        var byte: UInt8 = 0
        let extra = Darwin.read(descriptor, &byte, 1)
        guard extra == 0 else {
            throw AgentIntegrationArtifactApprovalError.refused(
                "The artifact grew while it was being read")
        }
        return data
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw AgentIntegrationArtifactApprovalError.unavailable(
                        "The artifact staging copy could not be written")
                }
                offset += count
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
