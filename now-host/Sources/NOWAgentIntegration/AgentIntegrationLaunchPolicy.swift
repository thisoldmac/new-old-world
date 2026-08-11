import Foundation

public enum AgentIntegrationLaunchPolicy {
    public static let maximumCatalogEntries = 512
    public static let maximumCandidates = 8
    public static let maximumNameScalars = 31
    public static let maximumVersionScalars = 32
    public static let maximumFailureCodeScalars = 48
    public static let maximumMessageScalars = 160
    public static let referencePrefix = "now-software-"
    public static let referencePattern =
        "^now-software-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

    public static func makeReference() -> String {
        referencePrefix + UUID().uuidString.lowercased()
    }

    public static func isValidReference(_ value: String) -> Bool {
        guard value == value.lowercased(),
              value.hasPrefix(referencePrefix),
              value.count == referencePrefix.count + 36 else {
            return false
        }
        return UUID(uuidString: String(value.dropFirst(referencePrefix.count)))
            != nil
    }
}
