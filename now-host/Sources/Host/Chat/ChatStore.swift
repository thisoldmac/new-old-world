import Foundation

/* Where chats live between launches.

   Two properties drive the shape, and both are decisions rather than
   taste. Chats are PERSISTED: closing the window is not "throw the
   conversation away", which is what the single in-memory conversation
   did every time somebody pressed New. And transcripts are LAZY: the
   catalog a sidebar draws is metadata only — id, title, dates, which
   project it belongs to — so a hundred chats cost a hundred small
   records, and the megabytes (a tool result can carry a PNG of the
   guest's screen) are read on selection and only then.

   That laziness is the thing the tests assert against the ARTIFACT
   rather than the intent: an unreadable transcript file must not stop
   the catalog listing, because if listing read transcripts it could
   not.

   A project here is a FOLDER ON DISK that chats are filed under,
   optionally ASSOCIATED with a Projects-module project (a build target
   and its code). The association is a stored reference, not a copy —
   the Projects module stays the authority for anything buildable.

   Everything is local: this store never leaves the machine, and the
   transcripts inside it can contain what the connected Mac's screen
   looked like. */

struct ChatID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.count == 32,
              rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        self.rawValue = rawValue
    }

    static func mint() -> ChatID {
        ChatID(rawValue: UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased())!
    }
}

struct ChatProjectID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("chatproject-"), rawValue.count == 28,
              rawValue.dropFirst(12).allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              })
        else { return nil }
        self.rawValue = rawValue
    }

    static func mint() -> ChatProjectID {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(16)
        return ChatProjectID(rawValue: "chatproject-\(suffix)")!
    }
}

/// Where a chat was typed.
///
/// Optional on the record and absent-reads-as-host, because every chat
/// that existed before 2026-08-18 was typed at the modern Mac and a
/// stored record must not have to be rewritten to say so.
enum ChatOrigin: String, Codable, Equatable, Sendable {
    case host
    case guest
}

/// A chat as the sidebar knows it — metadata only, deliberately. Not
/// one byte of the conversation is in here.
struct ChatSummary: Codable, Equatable, Sendable, Identifiable {
    var id: ChatID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// The project this chat is filed under, or nil for loose chats.
    var projectID: ChatProjectID?
    /// How many turns the transcript holds, so a row can say "empty"
    /// without reading the transcript to find out.
    var turnCount: Int
    /// Where it was typed. Both faces list both, so a person opening a
    /// chat is told which machine they wrote it at.
    var origin: ChatOrigin?

    /// The reading a missing field gets: everything written before
    /// chats could be typed anywhere was typed here.
    var whereTyped: ChatOrigin { origin ?? .host }
}

/// A chat project: a folder this store owns, optionally pointing at a
/// Projects-module project for the code half.
struct ChatProjectRecord: Codable, Equatable, Sendable, Identifiable {
    var id: ChatProjectID
    var name: String
    var createdAt: Date
    /// The Projects-module project this one is associated with, if a
    /// person has associated one. A reference — never a copy.
    var linkedProjectID: ProjectID?
    /// Which machine the person said should hold the code, asked when
    /// the project was created.
    ///
    /// Separate from the linked project's OWN `home`, and deliberately:
    /// a guest-home project cannot be minted blank — `ProjectStore.
    /// create` requires a verified guest digest, because the
    /// authoritative copy is the one on the classic Mac and inventing
    /// one here would be a second minter of guest projects. So an
    /// answered "guest" is recorded as INTENT and realised by the
    /// existing stage-and-promote path; until then the linked project
    /// is host-home and the person is told so in the same breath.
    var intendedHome: ProjectHome?
}

/// One transcript row as persisted. The live `ChatDisplayRow` mints a
/// fresh UUID per row for SwiftUI's identity; that identity is a
/// property of one running window, so it is not written down.
struct StoredChatRow: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case person, model, tool, note
    }
    var kind: Kind
    var text: String
    /// Tool rows only.
    var toolName: String?
    var toolOK: Bool?
}

/// A chat's contents: what the page draws, and what the model is
/// re-sent. Both halves, because either alone loses something — the
/// rows carry tool decoration a turn list does not, and the turns
/// carry tool-call plumbing the rows never show.
struct StoredChatTranscript: Codable, Equatable, Sendable {
    var schema: String = ChatStore.transcriptSchema
    var rows: [StoredChatRow] = []
    var turns: [ChatTurn] = []

    var isEmpty: Bool { rows.isEmpty && turns.isEmpty }
}

enum ChatStoreError: Error, Equatable, LocalizedError {
    case chatNotFound
    case projectNotFound
    case invalidTitle(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .chatNotFound: return "That chat is no longer on disk."
        case .projectNotFound: return "That chat project is no longer on disk."
        case .invalidTitle(let why): return why
        case .unavailable(let why): return why
        }
    }
}

/// The host-owned authority for saved chats. Callers hold IDs; the
/// layout on disk is this type's business alone.
final class ChatStore {
    static let transcriptSchema = "now.chat-transcript/1"
    static let catalogSchema = "now.chat-record/1"

    let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private struct CatalogRecord: Codable {
        var schema: String = ChatStore.catalogSchema
        var summary: ChatSummary
    }

    private struct ProjectFile: Codable {
        var schema: String = "now.chat-project/1"
        var record: ChatProjectRecord
    }

    static func applicationSupportRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw ChatStoreError.unavailable(
                "Application Support is unavailable.")
        }
        return support.appendingPathComponent(
            "New Old World/Chats", isDirectory: true)
    }

    convenience init() throws {
        try self.init(root: Self.applicationSupportRoot())
    }

    init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        for directory in [chatsURL, transcriptsURL, projectsURL] {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    private var chatsURL: URL {
        root.appendingPathComponent("chats", isDirectory: true)
    }
    private var transcriptsURL: URL {
        root.appendingPathComponent("transcripts", isDirectory: true)
    }
    private var projectsURL: URL {
        root.appendingPathComponent("projects", isDirectory: true)
    }

    private func chatURL(_ id: ChatID) -> URL {
        chatsURL.appendingPathComponent("\(id.rawValue).json")
    }
    private func transcriptURL(_ id: ChatID) -> URL {
        transcriptsURL.appendingPathComponent("\(id.rawValue).json")
    }

    /// The project's own folder on disk. It exists from the moment the
    /// project does — that is what a project IS here.
    func folderURL(for id: ChatProjectID) -> URL {
        projectsURL.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    private func projectFileURL(_ id: ChatProjectID) -> URL {
        folderURL(for: id).appendingPathComponent("project.json")
    }

    // MARK: - Chats

    /// Every chat, newest activity first. Reads metadata records ONLY:
    /// no transcript file is opened here, which is why a corrupt or
    /// unreadable transcript cannot take the sidebar down with it.
    func list() throws -> [ChatSummary] {
        try fileManager.contentsOfDirectory(
            at: chatsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSummary? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(
                        CatalogRecord.self, from: data)
                else { return nil }
                return record.summary
            }
            .sorted { left, right in
                left.updatedAt == right.updatedAt
                    ? left.id.rawValue < right.id.rawValue
                    : left.updatedAt > right.updatedAt
            }
    }

    func summary(_ id: ChatID) throws -> ChatSummary {
        guard let data = try? Data(contentsOf: chatURL(id)),
              let record = try? decoder.decode(CatalogRecord.self, from: data)
        else { throw ChatStoreError.chatNotFound }
        return record.summary
    }

    @discardableResult
    func createChat(title: String = ChatStore.untitled,
                    in projectID: ChatProjectID? = nil,
                    origin: ChatOrigin = .host,
                    now: Date = Date()) throws -> ChatSummary {
        if let projectID { _ = try project(projectID) }
        let summary = ChatSummary(
            id: .mint(), title: try validated(title), createdAt: now,
            updatedAt: now, projectID: projectID, turnCount: 0,
            origin: origin)
        try write(summary)
        return summary
    }

    @discardableResult
    func rename(_ id: ChatID, to title: String) throws -> ChatSummary {
        var summary = try summary(id)
        summary.title = try validated(title)
        try write(summary)
        return summary
    }

    /// Files a chat under a project, or under none. The chat's
    /// transcript does not move: a project is where a chat is FILED,
    /// not where its bytes live.
    @discardableResult
    func move(_ id: ChatID, to projectID: ChatProjectID?) throws -> ChatSummary {
        if let projectID { _ = try project(projectID) }
        var summary = try summary(id)
        summary.projectID = projectID
        try write(summary)
        return summary
    }

    func delete(_ id: ChatID) throws {
        guard fileManager.fileExists(atPath: chatURL(id).path) else {
            throw ChatStoreError.chatNotFound
        }
        try fileManager.removeItem(at: chatURL(id))
        if fileManager.fileExists(atPath: transcriptURL(id).path) {
            try fileManager.removeItem(at: transcriptURL(id))
        }
    }

    // MARK: - Transcripts (the lazy half)

    /// Read one chat's contents. Called on SELECTION, never on list.
    /// A chat that has never been saved reads as empty rather than
    /// throwing — an empty new chat is a normal state, not a fault.
    func loadTranscript(_ id: ChatID) throws -> StoredChatTranscript {
        guard fileManager.fileExists(atPath: chatURL(id).path) else {
            throw ChatStoreError.chatNotFound
        }
        guard fileManager.fileExists(atPath: transcriptURL(id).path) else {
            return StoredChatTranscript()
        }
        let data = try Data(contentsOf: transcriptURL(id))
        return try decoder.decode(StoredChatTranscript.self, from: data)
    }

    /// Write one chat's contents, refreshing the metadata a sidebar
    /// draws so the catalog stays true without anybody reading this
    /// file back.
    @discardableResult
    func saveTranscript(_ transcript: StoredChatTranscript,
                        for id: ChatID,
                        now: Date = Date()) throws -> ChatSummary {
        var summary = try summary(id)
        try encoder.encode(transcript).write(
            to: transcriptURL(id), options: .atomic)
        summary.turnCount = transcript.turns.count
        summary.updatedAt = now
        try write(summary)
        return summary
    }

    // MARK: - Projects

    func listProjects() throws -> [ChatProjectRecord] {
        try fileManager.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil)
            .compactMap { folder -> ChatProjectRecord? in
                let file = folder.appendingPathComponent("project.json")
                guard let data = try? Data(contentsOf: file),
                      let stored = try? decoder.decode(
                        ProjectFile.self, from: data)
                else { return nil }
                return stored.record
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func project(_ id: ChatProjectID) throws -> ChatProjectRecord {
        guard let data = try? Data(contentsOf: projectFileURL(id)),
              let stored = try? decoder.decode(ProjectFile.self, from: data)
        else { throw ChatStoreError.projectNotFound }
        return stored.record
    }

    @discardableResult
    func createProject(name: String, linkedProjectID: ProjectID? = nil,
                       intendedHome: ProjectHome? = nil,
                       now: Date = Date()) throws -> ChatProjectRecord {
        let record = ChatProjectRecord(
            id: .mint(), name: try validated(name), createdAt: now,
            linkedProjectID: linkedProjectID, intendedHome: intendedHome)
        try fileManager.createDirectory(
            at: folderURL(for: record.id), withIntermediateDirectories: true)
        try write(record)
        return record
    }

    @discardableResult
    func renameProject(_ id: ChatProjectID, to name: String) throws
        -> ChatProjectRecord {
        var record = try project(id)
        record.name = try validated(name)
        try write(record)
        return record
    }

    /// Associate (or clear) the Projects-module project that holds this
    /// chat project's code. Passing nil un-associates; the folder and
    /// its chats are untouched either way.
    @discardableResult
    func associate(_ id: ChatProjectID, with linked: ProjectID?) throws
        -> ChatProjectRecord {
        var record = try project(id)
        record.linkedProjectID = linked
        try write(record)
        return record
    }

    /// Removes the project and its folder. Its chats survive as loose
    /// chats — deleting a folder is not a request to delete
    /// conversations, and there is no undo for the other reading.
    func deleteProject(_ id: ChatProjectID) throws {
        _ = try project(id)
        for chat in try list() where chat.projectID == id {
            try move(chat.id, to: nil)
        }
        try fileManager.removeItem(at: folderURL(for: id))
    }

    // MARK: - First launch

    /// The first-run adoption. If the catalog already holds chats this
    /// returns the most recent one and `live` is ignored. If it is
    /// empty, chat #1 is created — carrying `live` when a conversation
    /// was already on screen, because the alternative is that upgrading
    /// the app silently throws away whatever the person was doing.
    @discardableResult
    func bootstrap(adopting live: StoredChatTranscript? = nil,
                   now: Date = Date()) throws -> ChatSummary {
        if let existing = try list().first { return existing }
        let live = live ?? StoredChatTranscript()
        let summary = try createChat(
            title: Self.title(for: live), now: now)
        guard !live.isEmpty else { return summary }
        return try saveTranscript(live, for: summary.id, now: now)
    }

    /// A chat's name when nobody has typed one: the first thing the
    /// person said, trimmed to a sidebar's width.
    static func title(for transcript: StoredChatTranscript) -> String {
        guard let first = transcript.rows.first(where: { $0.kind == .person })
            ?? transcript.rows.first
        else { return untitled }
        return title(fromPrompt: first.text)
    }

    static func title(fromPrompt prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return untitled }
        guard trimmed.count > 48 else { return trimmed }
        return trimmed.prefix(47).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static let untitled = "New chat"

    // MARK: - Plumbing

    private func validated(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 120 else {
            throw ChatStoreError.invalidTitle(
                "A name must be 1-120 characters.")
        }
        return trimmed
    }

    private func write(_ summary: ChatSummary) throws {
        let data = try encoder.encode(CatalogRecord(summary: summary))
        try data.write(to: chatURL(summary.id), options: .atomic)
    }

    private func write(_ record: ChatProjectRecord) throws {
        let data = try encoder.encode(ProjectFile(record: record))
        try data.write(to: projectFileURL(record.id), options: .atomic)
    }
}
