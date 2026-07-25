import Foundation

/// The host console: a **dumb shell** into the connected Mac.
///
/// It does not know what commands the other machine has, and must not. There
/// are two guests now — the PowerPC Carbon guest serves fifteen commands, and
/// NOW-68K serves three — so any list kept here would be wrong for one of
/// them, and wrong again the next time either grows a verb. So: the line a
/// human types is relayed as it was typed (`command.request` with `line`), and
/// whatever comes back is rendered, including the guest's own
/// `unknown-command` for something it does not have. Every argument grammar
/// lives on the machine that serves the command; see CommandRequest.line and
/// each command's `x-line` in contract/asyncapi.yaml.
///
/// What that leaves host-side, deliberately small and explicit:
///
/// - **`/`-verbs**, and the test for belonging there is that **no guest could
///   answer them**: `/clear`, `/save` and `/help` act on this console;
///   `/swpage` drives the `software.list` family, which is a wire family this
///   side implements rather than a command anyone serves. The prefix is the
///   whole rule — a bare word is always the far machine's, so a command added
///   to either guest tomorrow needs no edit here and can never be shadowed by
///   something local.
/// - **History** is this console's own (↑ / ↓). It needs no command set.
/// - **Completion** (Tab) comes from the guest, at runtime, by asking it
///   `help` — the same command a human can type. It is fetched on the first
///   Tab rather than on connect, so the console sends nothing nobody asked
///   for, and a guest that answers `unknown-command` to `help` simply has no
///   completion. Discovery being a wire request is the point: a machine that
///   serves three commands says three.
@MainActor
final class ConsoleModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case input(guest: String)
            case output
            case failure
            case notice
        }

        let id = UUID()
        let kind: Kind
        let text: String

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// The only verbs this side implements. Each one acts on this console or
    /// this Mac and has no meaning on the wire; anything a guest could serve
    /// is absent by design. Kept as data so `/help` cannot drift from it.
    enum LocalVerb: String, CaseIterable {
        case clear
        case save
        case help
        case swpage

        var summary: String {
            switch self {
            case .clear: return "clear this console's scrollback"
            case .save:
                return "write this scrollback to a file (/save [path])"
            case .help:
                return "these local verbs; type \"help\" for the guest's"
            case .swpage:
                return "page software.list directly (/swpage [domain] [cursor])"
            }
        }
    }

    /// The prefix that marks a verb as this side's. Anything without it is
    /// the other machine's, whatever it is.
    static let localPrefix = "/"

    @Published private(set) var lines: [Line] = []
    @Published var input = ""

    /// Command names the guest told us it serves, for Tab completion. Empty
    /// until asked, and emptied when the guest goes — a stale list is a list
    /// from a different machine.
    @Published private(set) var completions: [String] = []
    private var completionsRequested = false

    /// Newest last. Host-local: recalling a line needs no notion of what the
    /// line means.
    private(set) var history: [String] = []
    private var historyPos = 0
    private static let historyLimit = 64

    private let listener: GuestListener
    private static let scrollbackLimit = 400

    init(listener: GuestListener) {
        self.listener = listener
        append(.notice, "Console — every line runs on the connected Mac. "
            + "Type \"help\" to ask it what it serves; \"/help\" for what "
            + "this side does.")
    }

    // MARK: - Submitting

    func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        guard !command.isEmpty else { return }
        historyAdd(command)

        let guestName: String
        if case .connected(let name) = listener.state {
            guestName = name
        } else {
            guestName = "—"
        }
        append(.input(guest: guestName), command)

        if command.hasPrefix(Self.localPrefix) {
            runLocal(String(command.dropFirst()))
            return
        }
        send(command)
    }

    /// Splits at the first run of spaces and sends the rest verbatim. This is
    /// the whole of the host's parsing, and it stops here on purpose: the
    /// remainder may be a path with spaces, a flag, a quoted name or nothing,
    /// and only the machine that serves the command knows which.
    private func send(_ command: String) {
        let name = String(command.prefix { $0 != " " })
        let line = String(command.dropFirst(name.count))
            .trimmingCharacters(in: .whitespaces)
        listener.runCommand(name, line: line) { [weak self] result in
            self?.render(name, result)
        }
    }

    /// The menu's "Ask the Guest What It Serves", and the console's own way
    /// in. Shown in the scrollback exactly as if typed, because a reply that
    /// appears with no request above it reads like an error.
    func runHelp() {
        append(.input(guest: connectedName), "help")
        listener.runCommand("help", line: "") { [weak self] result in
            self?.render("help", result)
            self?.absorbCompletions(result)
        }
    }

    private var connectedName: String {
        if case .connected(let name) = listener.state { return name }
        return "—"
    }

    // MARK: - Host-local verbs

    private func runLocal(_ command: String) {
        let name = String(command.prefix { $0 != " " })
        let rest = String(command.dropFirst(name.count))
            .trimmingCharacters(in: .whitespaces)

        guard let verb = LocalVerb(rawValue: name) else {
            append(.failure, "/\(name): not a local verb (try \"/help\"). "
                + "Without the slash it would run on the other Mac.")
            return
        }
        switch verb {
        case .clear:
            lines = []
        case .save:
            save(to: rest)
        case .help:
            showLocalHelp()
        case .swpage:
            runSwPage(rest)
        }
    }

    private func showLocalHelp() {
        append(.notice, "This side, and only this side:")
        for verb in LocalVerb.allCases {
            let name = "/\(verb.rawValue)"
            append(.notice,
                   "  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                   + verb.summary)
        }
        append(.notice, "Everything else is sent to the connected Mac as "
            + "typed — this console keeps no list of its commands, because "
            + "the two guests do not serve the same ones. \"help\" asks it; "
            + "Tab completes from that answer.")
    }

    /// Replaces `gestalt --save`, which only worked because the host used to
    /// know what gestalt returns. Command-agnostic instead: it writes what is
    /// on screen, which is the thing a human actually wanted to keep.
    private func save(to path: String) {
        let url: URL
        if path.isEmpty {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/NOW console.txt")
        } else if path.hasPrefix("/") || path.hasPrefix("~") {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop").appendingPathComponent(path)
        }
        guard !lines.isEmpty else {
            append(.failure, "Nothing to save: the scrollback is empty")
            return
        }
        let body = lines.map(\.text).joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            append(.notice, "Saved \(lines.count) lines to \(url.path)")
        } catch {
            append(.failure, "Save failed: \(error.localizedDescription)")
        }
    }

    /// Not a command — a driver for the `software.list` family, which the
    /// host implements itself. It stays because it is the only way to watch
    /// that family page without the Software module's view in the way, and it
    /// is local for the same reason `/clear` is: no guest can serve it, so it
    /// cannot collide with one. `swpage [domain] [cursor]`.
    private func runSwPage(_ rest: String) {
        let words = rest.split(separator: " ").map(String.init)
        let domain = words.first { Int($0) == nil && !$0.hasPrefix("-") }
            ?? "apps"
        let cursor = words.compactMap { Int($0) }.first
        listener.listSoftware(domain: domain, cursor: cursor) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.append(.failure,
                            "/swpage: \(failure.message) [\(failure.code)]")
            case .success(let listing):
                if let note = listing.note {
                    self.append(.notice, "  (\(note))")
                }
                for e in listing.entries {
                    var states: [String] = []
                    if e.off == true { states.append("off") }
                    if e.running == true { states.append("running") }
                    let suffix = states.isEmpty
                        ? "" : "  (\(states.joined(separator: ", ")))"
                    self.append(.output,
                                "  \(e.name)  \(e.type ?? "?")/"
                                + "\(e.creator ?? "?") \(e.sizeK ?? -1)K"
                                + "\(suffix)  \(e.path)")
                }
                self.append(.notice,
                            "  \(listing.entries.count) entries"
                            + (listing.more
                               ? "; more (/swpage \(listing.domain) "
                                 + "\(listing.cursor ?? 0))"
                               : "; end"))
            }
        }
    }

    // MARK: - History

    private func historyAdd(_ command: String) {
        if history.last != command {
            history.append(command)
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
        }
        historyPos = history.count
    }

    /// -1 walks back, +1 forward. Past the newest is the empty line being
    /// edited, which is how every shell behaves.
    func recallHistory(_ delta: Int) -> String? {
        guard !history.isEmpty else { return nil }
        let position = min(max(historyPos + delta, 0), history.count)
        historyPos = position
        return position == history.count ? "" : history[position]
    }

    // MARK: - Completion, from the guest

    /// The completion for what is typed so far, or nil. Fetches the guest's
    /// command list the first time it is asked and returns nil for that press
    /// — the answer crosses a wire that measures in tens of milliseconds at
    /// best, and blocking the field on it would feel like a hang.
    func complete(_ prefix: String) -> String? {
        guard !prefix.contains(" "), !prefix.hasPrefix(Self.localPrefix) else {
            // Only the command name completes. Arguments are the guest's
            // grammar, which this side does not know and will not guess.
            return nil
        }
        if completions.isEmpty {
            requestCompletions()
            return nil
        }
        let matches = completions.filter { $0.hasPrefix(prefix) }
        if matches.count == 1 {
            return matches[0]
        }
        guard !matches.isEmpty else { return nil }
        append(.notice, "  " + matches.joined(separator: "  "))
        return commonPrefix(of: matches)
    }

    private func commonPrefix(of names: [String]) -> String? {
        guard var shared = names.first else { return nil }
        for name in names.dropFirst() {
            shared = String(shared.commonPrefix(with: name))
        }
        return shared.isEmpty ? nil : shared
    }

    /// Discovery is a request, not a constant. Quiet on the way out and on
    /// the way back: nothing is printed, because nobody typed it.
    private func requestCompletions() {
        guard !completionsRequested, case .connected = listener.state else {
            return
        }
        completionsRequested = true
        listener.runCommand("help", line: "") { [weak self] result in
            self?.absorbCompletions(result)
        }
    }

    /// The first column of `help`'s list form is the command names — the one
    /// structural promise that output makes (see the contract's `help`
    /// entry). Anything else in there is prose for a human.
    private func absorbCompletions(_ result: CommandResult) {
        guard result.ok, let rows = result.output?["help"] else { return }
        let names = rows.compactMap { $0.first }
            .filter { name in
                !name.isEmpty && name != "..."
                    && name.allSatisfy { $0.isLetter || $0.isNumber }
            }
        guard !names.isEmpty else { return }
        completions = names.sorted()
    }

    /// A new machine has its own commands, so the old list goes. Called by
    /// HostAppState when the wire changes.
    func forgetGuest() {
        completions = []
        completionsRequested = false
    }

    // MARK: - Rendering

    /// One renderer for every command, which is what a dumb shell can have:
    /// the contract's command output is grouped [label, value] rows for all
    /// of them, so a command added to either guest renders here with no host
    /// change at all. A failure — including `unknown-command` — is the
    /// guest's own words, not a local guess at them.
    private func render(_ command: String, _ result: CommandResult) {
        if let error = result.error {
            append(.failure, "\(command): \(error.message) [\(error.code)]")
            return
        }
        guard let output = result.output, !output.isEmpty else {
            append(.output, "(ok)")
            return
        }
        for key in output.keys.sorted() {
            let rows = output[key] ?? []
            // Aligned per group, not across the whole reply: gestalt --full
            // returns several groups whose labels have nothing to do with
            // each other, and one shared width indents the short ones off
            // the page.
            let width = rows.map { $0.first?.count ?? 0 }.max() ?? 0
            if output.count > 1 {
                append(.notice, "[\(key)]")
            }
            for row in rows where row.count >= 2 {
                let label = row[0].padding(toLength: width, withPad: " ",
                                           startingAt: 0)
                append(.output, "  \(label)  \(row[1])")
            }
        }
    }

    private func append(_ kind: Line.Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
        if lines.count > Self.scrollbackLimit {
            lines.removeFirst(lines.count - Self.scrollbackLimit)
        }
    }
}
