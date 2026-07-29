import Foundation

/// The host console: a **dumb shell** into the connected Mac.
///
/// It does not know what commands the other machine has, and must not. There
/// are two guests, serving different tables, so any list kept here would be
/// wrong for one of them and wrong again the next time either grows a verb.
///
/// So the line a human types goes across **exactly as typed** — the whole
/// line, verb included, as `exec.request` — and what comes back is the text
/// that machine's own console would have shown, rendered as text. Not
/// re-derived from structured rows: the same bytes, from the same renderer,
/// on the same machine. See the "Exec" section of contract/asyncapi.yaml.
///
/// The property that buys, stated as the thing to protect: **a verb added to
/// a guest is typeable from here with no change to this file, this binary, or
/// the contract.** `ConsoleShellTests` asserts it with a verb that exists
/// nowhere else.
///
/// The typed `command.request` plane is still here and still right for what
/// it is for — a caller that KNOWS the command and wants columns. Exactly one
/// thing in this file uses it: Tab completion, which reads `help`'s first
/// column. That is an enhancement, and it may be absent or wrong without
/// affecting a single pixel of output.
///
/// What that leaves host-side, deliberately small and explicit:
///
/// - **`/`-verbs**, and the test for belonging there is that **no guest could
///   answer them**: `/clear`, `/save` and `/help` act on this console;
///   `/swpage` drives the `software.list` family, which is a wire family this
///   side implements rather than a command anyone serves; `/cancel` stops a
///   request THIS side made and holds the id for, which a guest has no word
///   for. The prefix is the whole rule — a bare word is always the far
///   machine's, so a command added to either guest tomorrow needs no edit
///   here and can never be shadowed by something local.
/// - **Answering a prompt.** While a command is running, a typed line goes as
///   `exec.input` instead of starting a second one. See `submit()`.
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
        case cancel

        var summary: String {
            switch self {
            case .clear: return "clear this console's scrollback"
            case .save:
                return "write this scrollback to a file (/save [path])"
            case .help:
                return "these local verbs; type \"help\" for the guest's"
            case .swpage:
                return "page software.list directly (/swpage [domain] [cursor])"
            case .cancel:
                return "stop the command now running on the other Mac"
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
        /* While a command is running, a typed line can only be an ANSWER to
           it — a second command would be refused `exec-busy`, because both
           guests dispatch synchronously. So it goes as exec.input rather
           than as a new exec.request.

           The host deliberately does not try to tell a prompt from ordinary
           output; it has no way to and does not need one. If the guest was
           not waiting it DROPS the line rather than buffering it, so the
           cost of guessing wrong is that nothing happens — never that a
           stale answer lands in the next prompt. */
        if let running = listener.runningExecId {
            listener.provideExecInput(id: running, text: command)
            return
        }
        send(command)
    }

    /// Sends the line. The WHOLE line, verb and all, with no parsing at all.
    ///
    /// This used to split at the first run of spaces and send the name and
    /// the remainder as two fields. That split was the last piece of command
    /// grammar living on this side, and it was load-bearing in the wrong
    /// direction: "a verb ends at the first space" is a rule about a command
    /// set, this Mac serves no commands, and a line whose verb does not end
    /// at a space could not survive it.
    ///
    /// Removing it is what the exec plane is for: nothing in this file, in
    /// this binary, or in the contract has to change when a guest grows a
    /// verb. The guest splits, interprets and renders; this console shows
    /// what came back.
    private func send(_ command: String) {
        listener.exec(command) { [weak self] outcome in
            self?.render(outcome)
        }
    }

    /// The menu's "Ask the Guest What It Serves", and the console's own way
    /// in. Shown in the scrollback exactly as if typed, because a reply that
    /// appears with no request above it reads like an error.
    ///
    /// Goes through exec like any other typed line — it IS a typed line, and
    /// routing it specially would mean the menu item and the word `help`
    /// could show different things. Completion is fetched separately, on the
    /// typed plane, because it needs columns rather than text; see
    /// requestCompletions.
    func runHelp() {
        append(.input(guest: connectedName), "help")
        send("help")
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
        case .cancel:
            runCancel()
        }
    }

    /// Stops a running exec. Local because it acts on a request THIS side
    /// made and holds the id for — a guest has no word for "the thing you
    /// asked me a moment ago". The guest answers a cancel either way, so the
    /// exec still settles exactly once and this prints nothing on success:
    /// the terminal result will say what happened.
    private func runCancel() {
        guard let id = listener.runningExecId else {
            append(.notice, "Nothing is running.")
            return
        }
        listener.cancelExec(id: id)
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

    // MARK: - Which machine this console is a console for

    /// One machine's session at the console: what was typed, what came
    /// back, and what that machine said it serves.
    ///
    /// This is the model whose state MOST wants keeping. A scrollback is
    /// not a cache of something the guest could be asked again — it is the
    /// record of a conversation, and there is no re-fetching it. Someone
    /// who runs a long command on the 68K Mac, switches to the PowerPC one
    /// to compare, and comes back, must find their output where they left
    /// it; anything else makes the picker a thing you avoid using.
    ///
    /// The completions go with it rather than being re-asked, because they
    /// are already per machine for the reason `forgetGuest` states: NOW-68K
    /// serves three commands where the Carbon guest serves fifteen. The
    /// history is here too — it is this console's own, but "this console"
    /// now means one per machine, and recalling the other Mac's paths with
    /// ↑ is exactly the confusion the whole slice is about.
    struct Snapshot {
        var lines: [Line] = []
        var history: [String] = []
        var completions: [String] = []
        var completionsRequested = false
    }

    private let cache = GuestStateCache<Snapshot>()

    /// Points the console at another machine. Nil (a disconnect) leaves
    /// everything on screen: the scrollback is what a person reads to find
    /// out WHY the wire dropped, and clearing it then would be the single
    /// most annoying possible moment to do it.
    func focus(on connection: GuestConnectionState) {
        // The FIRST machine to connect inherits what is on screen rather
        // than clearing it: those lines were typed before there was a
        // machine, and this is the machine they were typed at.
        let firstEver = cache.focused == nil
        guard case .switched(let restored) =
            cache.focus(connection.key, parking: snapshot()) else { return }
        if firstEver { return }
        let fresh = restored ?? Snapshot()
        lines = fresh.lines
        history = fresh.history
        historyPos = fresh.history.count
        completions = fresh.completions
        completionsRequested = fresh.completionsRequested
        if lines.isEmpty {
            append(.notice, "Console — every line runs on "
                + "\(connection.peerLabel). Type \"help\" to ask it what it "
                + "serves; \"/help\" for what this side does.")
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(lines: lines, history: history, completions: completions,
                 completionsRequested: completionsRequested)
    }

    // MARK: - Rendering

    /// Shows what the guest printed. That is the whole renderer now, and the
    /// shrinkage is the point.
    ///
    /// It used to rebuild the display from the contract's [label, value]
    /// rows: pad the first column, group the second, skip anything that was
    /// not a pair. Three things were wrong with that, and only the first was
    /// obvious. It could not show anything that was not two columns, so
    /// `rows.count >= 2` silently DROPPED any row a guest sent with one — a
    /// missing line rather than an ugly one. It reconstructed a layout the
    /// guest had already decided, so a listing lined up one way on the
    /// PowerBook's own screen and another way here. And it meant a new
    /// output shape needed a host change, which is the drift this plane was
    /// built to end.
    ///
    /// Now the guest renders and this prints. The two consoles show the same
    /// bytes because they come from the same renderer on the same machine
    /// (now-guest-68k/src/commands/n68_exec.c), which is a property no amount of careful
    /// re-implementation here could have bought.
    private func render(_ outcome: GuestListener.ExecOutcome) {
        if outcome.gap {
            append(.failure, "(some output was lost in transit)")
        }
        // Guests separate lines with CR (n68_cmdresult.h). Splitting on
        // both terminators rather than translating: a guest that one day
        // sends LF is not wrong, and neither is one that sends both.
        let body = outcome.text.split(omittingEmptySubsequences: false,
                                      whereSeparator: { $0.isNewline })
        for line in body where !(line.isEmpty && body.count == 1) {
            append(.output, String(line))
        }
        if !outcome.ok {
            // The guest has usually said this already, in its own words, in
            // the text above — "! unknown-command: frobnicate". This is the
            // machine-readable half, and it is shown only when it adds
            // something a reader does not already have.
            let detail = outcome.message ?? "the command did not succeed"
            let code = outcome.code ?? "failed"
            if outcome.text.isEmpty {
                append(.failure, "\(detail) [\(code)]")
            }
        } else if outcome.text.isEmpty {
            append(.output, "(ok)")
        }
    }

    private func append(_ kind: Line.Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
        if lines.count > Self.scrollbackLimit {
            lines.removeFirst(lines.count - Self.scrollbackLimit)
        }
    }
}
