import Foundation

public enum AgentIntegrationDevelopmentOperation: String, Codable, Sendable {
    case stage
    case stageStatus = "stage-status"
    case stageDiscard = "stage-discard"
    case promote
    case buildStart = "build-start"
    case buildStatus = "build-status"
    case buildCancel = "build-cancel"
    case run
    case openInCodeKitten = "open-in-codekitten"
}

/// The compact cross-domain Development lane. Every value is an opaque
/// identity minted by Projects or the guest; paths and command text have no
/// representation here.
public struct AgentIntegrationDevelopmentRequest: Codable, Equatable, Sendable {
    public let operation: AgentIntegrationDevelopmentOperation
    public let projectID: String?
    public let workspaceID: String?
    public let candidateID: String?
    public let productRef: String?

    public init(operation: AgentIntegrationDevelopmentOperation,
                projectID: String? = nil, workspaceID: String? = nil,
                candidateID: String? = nil, productRef: String? = nil) {
        self.operation = operation
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.candidateID = candidateID
        self.productRef = productRef
    }

    public var isWellFormed: Bool {
        let projectIsValid = projectID.map {
            $0.count == 32 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        } ?? true
        let productIsValid = productRef.map {
            $0.range(of: #"^product-[0-9a-f]{16}$"#,
                     options: .regularExpression) != nil
        } ?? true
        let workspaceIsValid = workspaceID.map {
            $0.range(of: #"^workspace-[0-9a-f]{16}$"#,
                     options: .regularExpression) != nil
        } ?? true
        let candidateIsValid = candidateID.map {
            $0.range(of: #"^candidate-[0-9a-f]{16}$"#,
                     options: .regularExpression) != nil
        } ?? true
        guard projectIsValid, productIsValid, workspaceIsValid,
              candidateIsValid else { return false }
        switch operation {
        case .stage:
            return projectID != nil && candidateID == nil && productRef == nil
        case .stageStatus, .stageDiscard, .promote:
            return candidateID != nil && projectID == nil
                && workspaceID == nil && productRef == nil
        case .buildStart:
            return (projectID != nil) != (candidateID != nil)
                && workspaceID == nil && productRef == nil
        case .openInCodeKitten:
            return projectID != nil && workspaceID == nil
                && candidateID == nil && productRef == nil
        case .buildStatus, .buildCancel:
            return projectID == nil && workspaceID == nil
                && candidateID == nil && productRef == nil
        case .run:
            return productRef != nil && projectID == nil
                && workspaceID == nil && candidateID == nil
        }
    }
}
