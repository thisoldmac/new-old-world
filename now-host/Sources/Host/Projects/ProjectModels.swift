import CryptoKit
import Foundation

struct ProjectID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.count == 32,
              rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func mint() -> ProjectID {
        ProjectID(rawValue: UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased())!
    }
}

struct ProjectWorkspaceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("workspace-"), rawValue.count == 26,
              rawValue.dropFirst(10).allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    static func mint() -> ProjectWorkspaceID {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(16)
        return ProjectWorkspaceID(rawValue: "workspace-\(suffix)")!
    }
}

struct ProjectCandidateID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("candidate-"), rawValue.count == 26,
              rawValue.dropFirst(10).allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    static func mint() -> ProjectCandidateID {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(16)
        return ProjectCandidateID(rawValue: "candidate-\(suffix)")!
    }
}

enum ProjectHome: String, Codable, Equatable, Sendable {
    case host
    case guest
}

enum ProjectWorkspaceLifecycle: String, Codable, Equatable, Sendable {
    case active
    case promoted
    case discarded
}

enum ProjectCandidateLifecycle: String, Codable, Equatable, Sendable {
    case hostStaged
    case guestTransferred
    case buildSucceeded
    case buildFailed
    case promoted
    case discarded
}

struct ProjectManifestEntry: Codable, Equatable, Sendable {
    let path: String
    let dataBytes: Int
    let resourceBytes: Int
    let type: String?
    let creator: String?
    let digest: String
}

struct ProjectCandidateReceipt: Codable, Equatable, Sendable {
    let schema = "ckproject.candidate-receipt/1"
    let candidateID: ProjectCandidateID
    let projectID: ProjectID
    let home: ProjectHome
    let sourceRevision: Int
    let sourceCommit: String
    let workspaceID: ProjectWorkspaceID?
    let baseGuestDigest: String?
    let contentDigest: String
    let manifest: [ProjectManifestEntry]
    let stagedAt: Date
}

struct ProjectCandidate: Codable, Equatable, Sendable {
    let receipt: ProjectCandidateReceipt
    var lifecycle: ProjectCandidateLifecycle
    var buildID: String?
    var updatedAt: Date
}

struct ProjectPromotionReceipt: Codable, Equatable, Sendable {
    let schema = "ckproject.promotion-receipt/1"
    let candidateID: ProjectCandidateID
    let projectID: ProjectID
    let home: ProjectHome
    let baseGuestDigest: String?
    let currentGuestDigest: String?
    let promotedRevision: Int
    let promotedCommit: String
    let contentDigest: String
    let promotedAt: Date
}

struct ProjectFileChange: Equatable, Sendable {
    let path: String
    let expectedDigest: String?
    /// `nil` deletes the file. A zero-byte `Data` creates an empty file.
    let contents: Data?

    init(path: String, expectedDigest: String? = nil, contents: Data?) {
        self.path = path
        self.expectedDigest = expectedDigest
        self.contents = contents
    }
}

struct ProjectRevisionReceipt: Codable, Equatable, Sendable {
    let schema = "ckproject.revision-receipt/1"
    let projectID: ProjectID
    let home: ProjectHome
    let revision: Int
    let commit: String
    let contentDigest: String
    let changedPaths: [String]
    let committedAt: Date
}

struct ProjectHistoryEntry: Codable, Equatable, Sendable {
    let revision: Int
    let commit: String
    let parent: String?
    let contentDigest: String
    let message: String
    let committedAt: Date
}

struct ProjectStatus: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let name: String
    let home: ProjectHome
    let formatVersion: Int
    let revision: Int
    let currentCommit: String
    let contentDigest: String
    let verifiedGuestDigest: String?
    let guestState: GuestProjectSyncState
    let activeWorkspaceID: ProjectWorkspaceID?
}

enum GuestProjectSyncState: String, Codable, Equatable, Sendable {
    case notApplicable
    case verified
    case stale
    case dirtyOnGuest
    case divergent
}

struct ProjectWorkspace: Codable, Equatable, Sendable {
    let workspaceID: ProjectWorkspaceID
    let projectID: ProjectID
    let baseRevision: Int
    let baseProjectCommit: String
    let baseGuestDigest: String?
    var currentCommit: String
    var contentDigest: String
    var lifecycle: ProjectWorkspaceLifecycle
    var promotedCommit: String?
    let createdAt: Date
    var updatedAt: Date
}

enum ProjectStoreError: Error, Equatable, LocalizedError {
    case invalidProject(String)
    case invalidPath(String)
    case linkEscape(String)
    case duplicatePath(String)
    case projectNotFound
    case workspaceNotFound
    case revisionConflict(expected: Int, current: Int)
    case commitConflict(expected: String, current: String)
    case digestConflict(path: String, expected: String, current: String?)
    case unpromotedWorkspace
    case candidateNotFound
    case candidateNotBuilt
    case guestDiverged(base: String, current: String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidProject(let reason): return "Invalid project: \(reason)"
        case .invalidPath(let path): return "Invalid project-relative path: \(path)"
        case .linkEscape(let path): return "A link leaves the project root: \(path)"
        case .duplicatePath(let path): return "The batch names \(path) more than once."
        case .projectNotFound: return "The project reference was not found."
        case .workspaceNotFound: return "The workspace reference was not found."
        case .revisionConflict(let expected, let current):
            return "Expected revision \(expected), but the project is at \(current)."
        case .commitConflict(let expected, let current):
            return "Expected commit \(expected), but the workspace is at \(current)."
        case .digestConflict(let path, let expected, let current):
            return "Expected \(path) to have digest \(expected), but it has \(current ?? "no file")."
        case .unpromotedWorkspace:
            return "The workspace contains the only copy of unpromoted commits."
        case .candidateNotFound: return "The candidate reference was not found."
        case .candidateNotBuilt:
            return "The candidate has not completed a successful build."
        case .guestDiverged(let base, let current):
            return "The guest changed from \(base) to \(current); promotion was refused."
        case .unavailable(let reason): return reason
        }
    }
}

enum ProjectDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func tree(at root: URL, fileManager: FileManager = .default) throws -> String {
        guard let walk = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw ProjectStoreError.invalidProject("The working tree cannot be read.")
        }
        var entries: [(String, String)] = []
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey])
            let relative = url.pathComponents.suffix(walk.level)
                .joined(separator: "/")
            if values.isSymbolicLink == true {
                throw ProjectStoreError.linkEscape(relative)
            }
            guard values.isRegularFile == true else { continue }
            entries.append((relative, sha256(try Data(contentsOf: url))))
        }
        var aggregate = Data()
        for (path, digest) in entries.sorted(by: { $0.0 < $1.0 }) {
            aggregate.append(Data(path.utf8))
            aggregate.append(0)
            aggregate.append(Data(digest.utf8))
            aggregate.append(10)
        }
        return sha256(aggregate)
    }
}
