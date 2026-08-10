import Foundation

public enum AgentIntegrationProjectOperation: String, Codable, Sendable {
    case list
    case create
    case status
    case read
    case apply
    case history
    case workspaceOpen = "workspace-open"
    case workspaceResume = "workspace-resume"
    case workspaceDiscard = "workspace-discard"
}

public enum AgentIntegrationProjectChangeAction: String, Codable, Sendable {
    case write
    case delete
}

public enum AgentIntegrationProjectFork: String, Codable, Sendable {
    case data
    case resource
}

public struct AgentIntegrationProjectChange: Codable, Equatable, Sendable {
    public let path: String
    public let fork: AgentIntegrationProjectFork?
    public let action: AgentIntegrationProjectChangeAction
    public let expectedDigest: String?
    public let contentsBase64: String?
    public let finderType: String?
    public let finderCreator: String?
    public let finderFlags: Int?

    public init(path: String, action: AgentIntegrationProjectChangeAction,
                fork: AgentIntegrationProjectFork? = nil,
                expectedDigest: String? = nil, contentsBase64: String? = nil,
                finderType: String? = nil, finderCreator: String? = nil,
                finderFlags: Int? = nil) {
        self.path = path
        self.fork = fork
        self.action = action
        self.expectedDigest = expectedDigest
        self.contentsBase64 = contentsBase64
        self.finderType = finderType
        self.finderCreator = finderCreator
        self.finderFlags = finderFlags
    }

    public var isWellFormed: Bool {
        guard path.count <= 1024,
              !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              expectedDigest.map(Self.isDigest) ?? true,
              finderType.map(Self.isFourCC) ?? true,
              finderCreator.map(Self.isFourCC) ?? true,
              finderFlags.map({ $0 >= 0 && $0 <= 0xffff }) ?? true,
              (finderType == nil && finderCreator == nil && finderFlags == nil)
                || (finderType != nil && finderCreator != nil && finderFlags != nil)
        else { return false }
        switch action {
        case .write:
            guard let contentsBase64,
                  let data = Data(base64Encoded: contentsBase64),
                  data.count <= 256 * 1024 else { return false }
        case .delete:
            guard contentsBase64 == nil else { return false }
        }
        return true
    }

    private static func isFourCC(_ value: String) -> Bool {
        value.utf8.count == 4
            && value.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public struct AgentIntegrationProjectRequest: Codable, Equatable, Sendable {
    public let operation: AgentIntegrationProjectOperation
    public var projectID: String?
    public var workspaceID: String?
    public var name: String?
    public var expectedRevision: Int?
    public var expectedCommit: String?
    public var path: String?
    public var fork: AgentIntegrationProjectFork?
    public var maximumBytes: Int?
    public var message: String?
    public var changes: [AgentIntegrationProjectChange]?

    public init(operation: AgentIntegrationProjectOperation,
                projectID: String? = nil, workspaceID: String? = nil,
                name: String? = nil, expectedRevision: Int? = nil,
                expectedCommit: String? = nil, path: String? = nil,
                fork: AgentIntegrationProjectFork? = nil,
                maximumBytes: Int? = nil, message: String? = nil,
                changes: [AgentIntegrationProjectChange]? = nil) {
        self.operation = operation
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.name = name
        self.expectedRevision = expectedRevision
        self.expectedCommit = expectedCommit
        self.path = path
        self.fork = fork
        self.maximumBytes = maximumBytes
        self.message = message
        self.changes = changes
    }

    public var isWellFormed: Bool {
        guard projectID.map(Self.isProjectID) ?? true,
              workspaceID.map(Self.isWorkspaceID) ?? true,
              name.map({ !$0.isEmpty && $0.count <= 64
                  && !$0.contains("\n") && !$0.contains("\r")
                  && !$0.contains("\0") }) ?? true,
              expectedRevision.map({ $0 >= 0 }) ?? true,
              expectedCommit.map(Self.isCommit) ?? true,
              maximumBytes.map({ $0 >= 1 && $0 <= 256 * 1024 }) ?? true,
              message.map({ !$0.isEmpty && $0.count <= 256 }) ?? true,
              changes.map({ !$0.isEmpty && $0.count <= 128
                  && $0.allSatisfy(\.isWellFormed) }) ?? true else { return false }
        switch operation {
        case .list:
            return projectID == nil && workspaceID == nil && name == nil
                && expectedRevision == nil && expectedCommit == nil
                && path == nil && maximumBytes == nil && message == nil
                && fork == nil
                && changes == nil
        case .create:
            let initialChangesAreWrites = changes?.allSatisfy {
                $0.action == .write && $0.path != "Project.ckp"
            } ?? false
            return name != nil && projectID == nil && workspaceID == nil
                && initialChangesAreWrites && expectedRevision == nil
                && expectedCommit == nil && path == nil
                && fork == nil
        case .status, .history, .workspaceOpen:
            return projectID != nil && workspaceID == nil && name == nil
                && expectedRevision == nil && expectedCommit == nil
                && path == nil && maximumBytes == nil && message == nil
                && fork == nil
                && changes == nil
        case .read:
            return projectID != nil && path != nil && workspaceID == nil
                && changes == nil && message == nil
        case .apply:
            let projectApply = projectID != nil && expectedRevision != nil
                && workspaceID == nil && expectedCommit == nil
            let workspaceApply = workspaceID != nil && expectedCommit != nil
                && projectID == nil && expectedRevision == nil
            return (projectApply || workspaceApply) && changes != nil
                && message != nil && path == nil && name == nil
                && fork == nil
        case .workspaceResume, .workspaceDiscard:
            return workspaceID != nil && projectID == nil && name == nil
                && expectedRevision == nil && expectedCommit == nil
                && path == nil && maximumBytes == nil && message == nil
                && fork == nil
                && changes == nil
        }
    }

    private static func isProjectID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isWorkspaceID(_ value: String) -> Bool {
        value.hasPrefix("workspace-") && value.count == 26
            && value.dropFirst(10).allSatisfy(\.isHexDigit)
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public struct AgentIntegrationProjectSummary: Codable, Equatable, Sendable {
    public let projectID: String
    public let name: String
    public let home: String
    public let revision: Int
    public let commit: String
    public let contentDigest: String
    public let guestState: String
    public let workspaceID: String?

    public init(projectID: String, name: String, home: String, revision: Int,
                commit: String, contentDigest: String, guestState: String,
                workspaceID: String?) {
        self.projectID = projectID
        self.name = name
        self.home = home
        self.revision = revision
        self.commit = commit
        self.contentDigest = contentDigest
        self.guestState = guestState
        self.workspaceID = workspaceID
    }
}

public struct AgentIntegrationProjectRevision: Codable, Equatable, Sendable {
    public let revision: Int
    public let commit: String
    public let parent: String?
    public let contentDigest: String
    public let message: String
    public let committedAt: Date

    public init(revision: Int, commit: String, parent: String?,
                contentDigest: String, message: String, committedAt: Date) {
        self.revision = revision
        self.commit = commit
        self.parent = parent
        self.contentDigest = contentDigest
        self.message = message
        self.committedAt = committedAt
    }
}

public struct AgentIntegrationProjectWorkspace: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let projectID: String
    public let baseRevision: Int
    public let baseGuestDigest: String?
    public let currentCommit: String
    public let contentDigest: String
    public let lifecycle: String

    public init(workspaceID: String, projectID: String, baseRevision: Int,
                baseGuestDigest: String?, currentCommit: String,
                contentDigest: String, lifecycle: String) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.baseRevision = baseRevision
        self.baseGuestDigest = baseGuestDigest
        self.currentCommit = currentCommit
        self.contentDigest = contentDigest
        self.lifecycle = lifecycle
    }
}

public struct AgentIntegrationProjectResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let projects: [AgentIntegrationProjectSummary]?
    public let project: AgentIntegrationProjectSummary?
    public let revision: AgentIntegrationProjectRevision?
    public let workspace: AgentIntegrationProjectWorkspace?
    public let history: [AgentIntegrationProjectRevision]?
    public let contentsBase64: String?
    public let fork: String?
    public let finderType: String?
    public let finderCreator: String?
    public let finderFlags: Int?
    public let failure: AgentIntegrationUnavailable?

    public init(projects: [AgentIntegrationProjectSummary]? = nil,
                project: AgentIntegrationProjectSummary? = nil,
                revision: AgentIntegrationProjectRevision? = nil,
                workspace: AgentIntegrationProjectWorkspace? = nil,
                history: [AgentIntegrationProjectRevision]? = nil,
                contentsBase64: String? = nil,
                fork: String? = nil, finderType: String? = nil,
                finderCreator: String? = nil, finderFlags: Int? = nil,
                failure: AgentIntegrationUnavailable? = nil) {
        self.ok = failure == nil
        self.projects = projects
        self.project = project
        self.revision = revision
        self.workspace = workspace
        self.history = history
        self.contentsBase64 = contentsBase64
        self.fork = fork
        self.finderType = finderType
        self.finderCreator = finderCreator
        self.finderFlags = finderFlags
        self.failure = failure
    }

    public static var hostUnavailable: Self {
        .init(failure: .init(code: "now-projects-host-unavailable",
                            message: "The running NOW host does not expose its Projects service."))
    }
}
