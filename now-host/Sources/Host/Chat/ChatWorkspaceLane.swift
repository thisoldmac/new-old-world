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

/// The lane nobody had to configure: NOW's own folder under Application
/// Support, created on first grant, with the shipped skills staged where
/// the spawned runtime discovers them natively (`.claude/skills`) — so a
/// person who has never opened Settings gets an agent that can build,
/// with craft knowledge loaded, after ONE click.
///
/// Why one click survives the frictionless mandate: the spawned
/// runtime's shell is real shell on the modern Mac, unaudited by this
/// app's per-tool consent, and any connected classic machine can start
/// a turn. The click is that Mac's owner saying yes once — not
/// choosing folders, not naming tiers. Everything else defaults.
enum ChatWorkspaceDefault {
    static let folderName = "Chat Workspace"

    /// `support` overrides Application Support — the tests' seam, so
    /// provisioning never writes into the machine's real folder.
    static func root(fileManager: FileManager = .default,
                     support: URL? = nil) -> URL? {
        guard let base = support ?? fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent(
            "New Old World/\(folderName)", isDirectory: true)
    }

    /// Creates the folder, stages the shipped skills into
    /// `.claude/skills`, and writes a starter CLAUDE.md. Idempotent and
    /// cheap on the happy path: read per turn, it re-copies the skills
    /// only when the staged marker names a different app version, and
    /// never rewrites a CLAUDE.md the person edited.
    static func provision(fileManager: FileManager = .default,
                          support: URL? = nil) -> URL? {
        guard let root = root(fileManager: fileManager, support: support)
        else { return nil }
        do {
            try fileManager.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        stageSkills(into: root, fileManager: fileManager)
        let claudeMD = root.appendingPathComponent("CLAUDE.md")
        if !fileManager.fileExists(atPath: claudeMD.path) {
            try? starterInstructions.data(using: .utf8)?
                .write(to: claudeMD)
        }
        return root
    }

    /// The runtime reads skills from the workspace the same way it
    /// reads any repository's — no slash command, no catalogue trip.
    /// Restaged when the app version moves, never touched otherwise, so
    /// a person's own edits to a staged skill survive a relaunch but
    /// not an upgrade (the upgrade IS new skill text).
    private static func stageSkills(
        into root: URL, fileManager: FileManager
    ) {
        let destination = root.appendingPathComponent(
            ".claude/skills", isDirectory: true)
        let marker = destination.appendingPathComponent(".now-staged")
        let stamp = ProductIdentity.displayVersion
        if let existing = try? String(contentsOf: marker, encoding: .utf8),
           existing == stamp {
            return
        }
        var source: URL?
        if let bundled = Bundle.main.url(forResource: "skills",
                                         withExtension: nil) {
            source = bundled
        } else if let repo = ChatSkillLibrary.repositoryRoot() {
            source = repo.appendingPathComponent("skills")
        }
        guard let source,
              fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            try stamp.data(using: .utf8)?.write(to: marker)
        } catch {
            /* A workspace without staged skills is still a workspace;
               the prompt's catalogue remains the fallback route. */
        }
    }

    private static let starterInstructions = """
        # New Old World's chat workspace

        This folder belongs to New Old World's chat: source, builds and \
        scratch for software written for the connected classic \
        Macintosh live here. The `now_*` tools observe and act on that \
        machine; building ON it goes through the `now_development` \
        family (the classic machine's own registered toolchain), and a \
        cross-build done here needs a toolchain on this Mac (Retro68).

        Move a finished binary to the classic machine with \
        `now_guest_files_upload_file`, launch it with \
        `now_launch_software`, and look at the result with \
        `now_capture_screen`.
        """
}

/// The lane's settings, read fresh every turn — a person can point the
/// lane somewhere new without relaunching, and a turn composed from a
/// remembered answer would be acting on the old directory.
final class ChatWorkspaceLaneStore: @unchecked Sendable {
    static let rootKey = "chat.workspace.root"
    static let permissionKey = "chat.workspace.permission"
    static let nowToolsKey = "chat.workspace.attachesNOWTools"
    /* The one click: with no folder chosen, true means the lane
       self-provisions NOW's own workspace. Off by default because the
       spawned runtime's shell is the one power this app cannot audit —
       see ChatWorkspaceDefault's header for why it is ONE click and
       not a configuration. */
    static let grantKey = "chat.workspace.grant"
    /* Not lane state — the person's own standing instructions, carried
       into every turn whatever the provider. They live in this store
       because it is the one place chat settings already read and write,
       and a second store would be a second thing to isolate per run. */
    static let instructionsKey = "chat.instructions"
    static let defaultTimeout: TimeInterval = 900

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let provision: @Sendable () -> URL?

    init(
        defaults: UserDefaults = ProductIdentity.defaults,
        fileManager: FileManager = .default,
        provision: @escaping @Sendable () -> URL?
            = { ChatWorkspaceDefault.provision() }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.provision = provision
    }

    func state() -> ChatWorkspaceLaneState {
        guard let path = defaults.string(forKey: Self.rootKey),
              !path.isEmpty else {
            /* No folder chosen. Granted, the lane provisions NOW's own
               workspace — full tier, because "build software" is the
               sentence the grant used and a build runs commands. The
               person's chosen tier still wins once they have chosen
               one. */
            guard defaults.bool(forKey: Self.grantKey) else {
                return .off
            }
            guard let root = provision() else {
                return .unusable(reason:
                    "NOW's own chat workspace could not be created "
                    + "under Application Support")
            }
            let permission = ChatWorkspaceLane.Permission(
                rawValue: defaults.string(forKey: Self.permissionKey) ?? "")
                ?? .bypassPermissions
            let attaches = defaults.object(forKey: Self.nowToolsKey) as? Bool
                ?? true
            return .ready(ChatWorkspaceLane(
                root: root,
                permission: permission,
                attachesNOWTools: attaches,
                timeout: Self.defaultTimeout))
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

    func setGranted(_ granted: Bool) {
        defaults.set(granted, forKey: Self.grantKey)
    }

    func granted() -> Bool {
        defaults.bool(forKey: Self.grantKey)
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
    ///
    /// `workspaceRoot` is the lane's granted folder, pinned onto the
    /// companion's command line so `now_guest_files_upload_file` can read
    /// files out of it. Spawn-time and explicit on purpose: the companion
    /// must never discover a readable root ambiently, and nil keeps the
    /// bare single-argument mode for a lane with no folder to grant.
    static func json(executable: URL?, workspaceRoot: URL?) -> String? {
        guard let executable else { return nil }
        var args = ["--mcp-stdio"]
        if let workspaceRoot {
            args += ["--workspace-root", workspaceRoot.path]
        }
        let object: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": executable.path,
                    "args": args,
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
