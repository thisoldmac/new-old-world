import Foundation

struct CodexAccount: Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?

    var isChatGPT: Bool { type == "chatgpt" }
}

struct CodexQuotaWindow: Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?
    let lifetimeTokens: Int?
    let currentStreakDays: Int?
}

struct CodexLoginStart: Equatable, Sendable {
    let loginID: String
    let authorizationURL: URL
}

enum CodexJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ChatFault.refuse(
                code: "provider-error", reason: "Unreadable Codex response")
        }
        return object
    }

    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func account(_ data: Data) throws -> CodexAccount? {
        let result = try object(data)
        guard let account = result["account"] as? [String: Any],
            let type = account["type"] as? String else { return nil }
        return CodexAccount(
            type: type, email: account["email"] as? String,
            planType: account["planType"] as? String)
    }

    static func models(_ data: Data) throws -> [ChatModel] {
        let rows = try object(data)["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row["hidden"] as? Bool != true,
                let model = (row["model"] as? String)
                    ?? (row["id"] as? String) else { return nil }
            return ChatModel(
                providerID: "codex", modelID: model,
                displayName: row["displayName"] as? String ?? model)
        }
    }

    static func login(_ data: Data) throws -> CodexLoginStart {
        let result = try object(data)
        guard result["type"] as? String == "chatgpt",
            let loginID = result["loginId"] as? String,
            let value = result["authUrl"] as? String,
            let url = URL(string: value) else {
            throw ChatFault.refuse(
                code: "provider-error",
                reason: "Codex did not return a browser sign-in URL")
        }
        return CodexLoginStart(loginID: loginID, authorizationURL: url)
    }

    static func usage(rateLimits: Data?, tokenUsage: Data?)
        -> CodexUsageSnapshot {
        let limits = rateLimits.flatMap { try? object($0) }
        let usage = tokenUsage.flatMap { try? object($0) }
        let snapshot = (limits?["rateLimits"] as? [[String: Any]])?.first
            ?? limits?["rateLimits"] as? [String: Any]
            ?? limits?["snapshot"] as? [String: Any]
        let summary = usage?["summary"] as? [String: Any]
        return CodexUsageSnapshot(
            primary: window(snapshot?["primary"]),
            secondary: window(snapshot?["secondary"]),
            lifetimeTokens: summary?["lifetimeTokens"] as? Int,
            currentStreakDays: summary?["currentStreakDays"] as? Int)
    }

    private static func window(_ value: Any?) -> CodexQuotaWindow? {
        guard let row = value as? [String: Any],
            let used = row["usedPercent"] as? Int else { return nil }
        return CodexQuotaWindow(
            usedPercent: used,
            resetsAt: (row["resetsAt"] as? TimeInterval).map(
                Date.init(timeIntervalSince1970:)),
            durationMinutes: row["windowDurationMins"] as? Int)
    }
}
