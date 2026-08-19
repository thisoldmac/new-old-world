import Foundation

/* The skills a chat can be given, and the slash commands that give them.

   **Why this exists.** The chat harness could always reach the machine
   and, since the workspace lane, its own source — and it was told
   nothing about the platform that source is FOR. A model in Build mode
   will write a UPP as a cast, skip pumping the wire inside a nested
   Toolbox loop, and hand back code that compiles and misbehaves on a
   68030: the exact lessons this project has already paid for and written
   down. Those lessons live in `skills/`, and until now they reached a
   turn only by accident — the workspace lane's spawned runtime happens
   to discover whatever skill tree the machine's owner has installed.
   Accidental capability is what this branch has spent its time ending.

   **The shape is deliberately small.** A skill is a folder with a
   `SKILL.md`; the front matter is the listing, the body is the
   instruction. A conversation loads one by name and the body joins the
   system prompt from then on. There is no execution, no tool, and no
   second registry — a skill is TEXT a person chose to put in front of
   the model, and calling it anything grander would invite it to become
   a capability nobody audited. */

/// One skill as the chat knows it.
struct ChatSkill: Equatable, Sendable, Identifiable {
    let name: String
    let description: String
    /// The instruction body, front matter removed.
    let body: String

    var id: String { name }

    /// What a person types to load it.
    var command: String { "/" + name }
}

/// What a leading slash in a prompt meant.
enum ChatSlashCommand: Equatable, Sendable {
    /// `/skills` — the listing, answered here with no model turn.
    case list
    /// `/name rest` — load the skill, then send `rest` if there is any.
    case load(name: String, rest: String)
    /// A slash the library does not recognise. It is NOT sent to the
    /// model: somebody who mistyped a command wants to hear so, not to
    /// watch a model improvise an answer to `/carbn`.
    case unknown(name: String)

    /// Nil when the prompt is ordinary text. A prompt beginning with a
    /// slash is a command by definition — the console's own rule, and
    /// `chat -- <text>` is how a person forces text that starts with
    /// one.
    static func parse(_ prompt: String, known: [String]) -> ChatSlashCommand? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let split = body.firstIndex(of: " ")
        let name = String(split.map { body[..<$0] } ?? body)
            .lowercased()
        let rest = split.map {
            String(body[body.index(after: $0)...])
                .trimmingCharacters(in: .whitespaces)
        } ?? ""
        if name == "skills" { return .list }
        guard known.contains(name) else { return .unknown(name: name) }
        return .load(name: name, rest: rest)
    }
}

/// The skills on disk, read once.
struct ChatSkillLibrary: Sendable {
    let skills: [ChatSkill]

    init(skills: [ChatSkill]) {
        self.skills = skills.sorted { $0.name < $1.name }
    }

    /// The shipped tree, then the source checkout.
    ///
    /// Bundle FIRST because that is what a person who installed the app
    /// has; the repository path is the development convenience, and if
    /// it won the app would read a tree that is not the one it ships.
    init(fileManager: FileManager = .default,
         bundle: Bundle = .main,
         repositoryRoot: URL? = ChatSkillLibrary.repositoryRoot()) {
        var roots: [URL] = []
        if let resource = bundle.url(forResource: "skills",
                                     withExtension: nil) {
            roots.append(resource)
        }
        if let repositoryRoot {
            roots.append(repositoryRoot.appendingPathComponent("skills"))
        }
        for root in roots {
            let found = ChatSkillLibrary.read(root, fileManager: fileManager)
            if !found.isEmpty {
                self.init(skills: found)
                return
            }
        }
        self.init(skills: [])
    }

    subscript(name: String) -> ChatSkill? {
        skills.first { $0.name == name }
    }

    var names: [String] { skills.map(\.name) }

    /// Every skill's name and sentence, cheap enough to carry in every
    /// prompt: a model that cannot see what it may ask for will never
    /// ask, and a person should not have to know the list by heart.
    var catalogue: String {
        guard !skills.isEmpty else { return "" }
        let rows = skills.map { "- \($0.command) — \($0.description)" }
        /* "Never a precondition" is measured, not stylistic: the first
           live Build turn through the wire (2026-08-19) answered a
           build-upload-launch request with "type /x and I will proceed"
           and did nothing. A skill deepens a turn that already
           happened; it must not gate one. */
        return """
            Skills this conversation can load, by typing the command on \
            its own line. You cannot load one yourself. Do the work \
            asked of you with what you have, and mention — once, \
            briefly — a skill that would deepen it; never make loading \
            one a precondition for acting.
            \(rows.joined(separator: "\n"))
            """
    }

    static func read(_ root: URL, fileManager: FileManager = .default)
        -> [ChatSkill] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { folder -> ChatSkill? in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8)
            else { return nil }
            return parse(text, fallbackName: folder.lastPathComponent)
        }
    }

    /// Front matter, then body. A file whose front matter is missing or
    /// unreadable still becomes a skill named after its folder: the
    /// instruction is the valuable half, and refusing to load it over a
    /// missing sentence would lose the thing a person wanted.
    static func parse(_ text: String, fallbackName: String) -> ChatSkill? {
        var name = fallbackName
        var description = ""
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            for line in lines[1..<end] {
                let parts = line.split(separator: ":", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "name", !value.isEmpty { name = value }
                if key == "description" { description = value }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ChatSkill(name: name, description: description, body: trimmed)
    }

    /// The checkout this build was compiled from, when there is one.
    /// Nil in a shipped app, which is the point of trying the bundle
    /// first.
    ///
    /// It WALKS UP looking for the repository rather than counting
    /// directories from `#filePath`, and the counting version is worth
    /// remembering: a default `#filePath` argument binds at the CALL
    /// SITE, so the same function answered from a source file and from
    /// a test file started in two different directories and only one of
    /// them landed anywhere. Anchoring on a pair of things only this
    /// repository has cannot drift that way.
    static func repositoryRoot(
        startingAt start: URL = URL(fileURLWithPath: #filePath),
        fileManager: FileManager = .default
    ) -> URL? {
        var url = start.deletingLastPathComponent()
        for _ in 0..<8 {
            let skills = url.appendingPathComponent("skills")
            let contract = url.appendingPathComponent("contract/asyncapi.yaml")
            if fileManager.fileExists(atPath: skills.path),
               fileManager.fileExists(atPath: contract.path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }
}
