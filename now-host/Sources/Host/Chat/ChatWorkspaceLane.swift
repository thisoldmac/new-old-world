import Foundation

/* The workspace lane: the one authority in this application that points
   a coding agent at a directory on the MODERN Mac.

   Everything else Chat can do goes through the host projection registry
   — one schema per capability, a consent tier, an audit line in the
   person's log. This does not, and the difference is the whole reason
   the lane is a deliberate, off-by-default grant with its own sentence
   in Settings rather than a flag: the spawned runtime brings its OWN
   file and shell tools, governed by its own permission mode and by
   whatever policy the chosen directory carries (a repository's hooks,
   for instance). The New Old World half of such a turn is audited
   exactly as before, because the runtime reaches those capabilities
   through this app's existing `--mcp-stdio` face; the file-and-shell
   half is not, and saying so is part of shipping it.

   Nothing here launches anything. It answers one question — may this
   turn have a workspace, and which — so the provider, the settings
   pane and the tests all read one answer. */

struct ChatWorkspaceLane: Equatable, Sendable {
    /// What the spawned runtime may do without being asked. It cannot be
    /// asked: `-p` has nobody at a keyboard, so an unanswerable prompt
    /// is a turn that stalls until the deadline and reports nothing.
    enum Permission: String, Equatable, Sendable, CaseIterable {
        /// File edits proceed; commands are declined. The default,
        /// because it is the tier where a mistake is still a diff.
        case acceptEdits
        /// Edits AND commands proceed — what a build, a test run or a
        /// deploy needs, and the tier a person opts into by name.
        case bypassPermissions

        var label: String {
            switch self {
            case .acceptEdits: return "Edit files"
            case .bypassPermissions: return "Edit files and run commands"
            }
        }
    }

    let root: URL
    let permission: Permission
    /// Whether the runtime is handed this app's own MCP face. On by
    /// default: a lane that can edit `chat_module.c` but cannot look at
    /// the machine it runs on is the smaller half of the point.
    let attachesNOWTools: Bool
    /// A build on a real toolchain outlives a chat deadline. The
    /// text-only ceiling is three minutes; this one is measured in the
    /// units of `scripts/build-guests`.
    let timeout: TimeInterval

    /// What the model is told it may touch, and what the popup shows.
    var summary: String {
        let where_ = root.lastPathComponent
        switch permission {
        case .acceptEdits: return "Reads and edits \(where_)"
        case .bypassPermissions: return "Full access to \(where_)"
        }
    }
}

/// Why a turn has no workspace, or which one it has. Three states and
/// not an optional, because "nobody asked for one" and "the directory
/// you named is gone" are different answers and only one of them is
/// worth putting in front of a person.
enum ChatWorkspaceLaneState: Equatable, Sendable {
    case off
    case unusable(reason: String)
    case ready(ChatWorkspaceLane)

    var lane: ChatWorkspaceLane? {
        if case .ready(let lane) = self { return lane }
        return nil
    }
}

/// The lane's settings, read fresh every turn — a person can point the
/// lane somewhere new without relaunching, and a turn composed from a
/// remembered answer would be acting on the old directory.
final class ChatWorkspaceLaneStore: @unchecked Sendable {
    static let rootKey = "chat.workspace.root"
    static let permissionKey = "chat.workspace.permission"
    static let nowToolsKey = "chat.workspace.attachesNOWTools"
    /* Not lane state — the person's own standing instructions, carried
       into every turn whatever the provider. They live in this store
       because it is the one place chat settings already read and write,
       and a second store would be a second thing to isolate per run. */
    static let instructionsKey = "chat.instructions"
    static let defaultTimeout: TimeInterval = 900

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        defaults: UserDefaults = ProductIdentity.defaults,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func state() -> ChatWorkspaceLaneState {
        guard let path = defaults.string(forKey: Self.rootKey),
              !path.isEmpty else {
            return .off
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        else {
            return .unusable(
                reason: "The chat workspace folder is missing: \(path)")
        }
        guard isDirectory.boolValue else {
            return .unusable(
                reason: "The chat workspace is not a folder: \(path)")
        }
        let permission = ChatWorkspaceLane.Permission(
            rawValue: defaults.string(forKey: Self.permissionKey) ?? "")
            ?? .acceptEdits
        /* Absent means ON. The key is written when a person chooses, and
           the choice a person who has never opened the row would make is
           the one that makes the lane worth having. */
        let attaches = defaults.object(forKey: Self.nowToolsKey) as? Bool
            ?? true
        return .ready(ChatWorkspaceLane(
            root: URL(fileURLWithPath: path, isDirectory: true),
            permission: permission,
            attachesNOWTools: attaches,
            timeout: Self.defaultTimeout))
    }

    func setRoot(_ url: URL?) {
        if let url {
            defaults.set(url.path, forKey: Self.rootKey)
        } else {
            defaults.removeObject(forKey: Self.rootKey)
        }
    }

    func setPermission(_ permission: ChatWorkspaceLane.Permission) {
        defaults.set(permission.rawValue, forKey: Self.permissionKey)
    }

    func setAttachesNOWTools(_ attaches: Bool) {
        defaults.set(attaches, forKey: Self.nowToolsKey)
    }

    /// Read fresh every turn, like the lane itself.
    func instructions() -> String {
        (defaults.string(forKey: Self.instructionsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setInstructions(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.instructionsKey)
        } else {
            defaults.set(text, forKey: Self.instructionsKey)
        }
    }
}

/// The MCP configuration handed to a lane runtime: this same executable,
/// in the `--mcp-stdio` mode it already has, so the runtime reaches the
/// running app's capabilities through the face that already owns
/// consent and audit. No second server, no second copy of the registry.
enum ChatWorkspaceMCPConfig {
    static let serverName = "now"

    /// Nil when the executable cannot be found — the lane then runs
    /// without New Old World's tools rather than with a broken server
    /// the runtime would spend its turn retrying.
    static func json(executable: URL?) -> String? {
        guard let executable else { return nil }
        let object: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": executable.path,
                    "args": ["--mcp-stdio"],
                ],
            ],
        ]
        /* Slashes unescaped: this string is read by a person in a log or
           a crash report as often as by the runtime, and `\/Apps\/New Old
           World` is the kind of detail that sends somebody looking for a
           quoting bug that is not there. */
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
