import Foundation

/// The host console: a shell into the connected guest. Every line typed is
/// one command.request; the guest's command.result renders as output. The
/// command set is the contract's x-commands registry — closed and typed.
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

    /// Declared commands (contract x-commands) plus console built-ins.
    static let commands = ["gestalt", "screenshot", "vprobe", "ls"]

    /// Per-command docs, mirroring the contract's x-commands descriptions.
    /// help and --help render from here — documentation never hits the wire.
    struct CommandInfo {
        let summary: String
        let help: [String]
    }

    static let catalog: [String: CommandInfo] = [
        "gestalt": .init(
            summary: "report the Mac: system, model, RAM, CarbonLib",
            help: ["gestalt — report the connected Mac's identity",
                   "  Usage: gestalt",
                   "  Reports the running system version, the Gestalt",
                   "  machine type, physical RAM, and the installed",
                   "  CarbonLib version."]),
        "screenshot": .init(
            summary: "capture the guest's screen to its desktop",
            help: ["screenshot — capture the connected Mac's screen",
                   "  Usage: screenshot [--depth {1,2,4,8,16,32}] [--no-save]",
                   "  The other Mac captures and saves a packed PICT to its own",
                   "  desktop (pixels do not cross the wire yet) and returns",
                   "  size / compression / timing measurements.",
                   "  --no-save measures without writing a file."]),
        "vprobe": .init(
            summary: "measure the guest's VRAM read cost by method",
            help: ["vprobe — measure VRAM read cost on the guest",
                   "  Usage: vprobe",
                   "  Times raw framebuffer reads (8/16/32/64-bit) against",
                   "  the CopyBits baseline, checks reread caching,",
                   "  partial-read scaling, and pixel fidelity. Takes ~3 s;",
                   "  keep its screen still during the run."]),
        "ls": .init(
            summary: "list a folder in the guest's shared files",
            help: ["ls — list a folder the classic Mac shares",
                   "  Usage: ls [path]",
                   "  Paths are relative to the shared folder's root, with",
                   "  colons between folders: \"Lab:Code\". No path lists",
                   "  the root. The root is chosen on that Mac in",
                   "  File > File Sharing...; nothing outside it is",
                   "  reachable. The Files module browses the same share."]),
        "help": .init(
            summary: "show this list (\"help <cmd>\" for details)",
            help: ["help — list commands, or \"help <cmd>\" for one"]),
        "clear": .init(
            summary: "clear the console scrollback",
            help: ["clear — clear the console scrollback"])
    ]

    @Published private(set) var lines: [Line] = []
    @Published var input = ""

    private let listener: GuestListener
    private static let scrollbackLimit = 400

    init(listener: GuestListener) {
        self.listener = listener
        append(.notice, "Console — commands run on the connected Mac. "
            + "Type \"help\" for the list.")
    }

    func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        guard !command.isEmpty else { return }

        let guestName: String
        if case .connected(let name) = listener.state {
            guestName = name
        } else {
            guestName = "—"
        }
        append(.input(guest: guestName), command)

        let tokens = command.split(separator: " ").map(String.init)
        let name = tokens[0]
        let rest = Array(tokens.dropFirst())
        let wantsHelp = rest.contains("-h") || rest.contains("--help")

        if name == "help" {
            if let target = rest.first(where: { !$0.hasPrefix("-") }) {
                showHelp(for: target)
            } else {
                showHelpList()
            }
            return
        }
        if wantsHelp {
            showHelp(for: name)
            return
        }
        if name == "clear" {
            lines = []
            return
        }
        if name == "gestalt" {
            runGestalt(rest)
            return
        }
        if name == "screenshot" {
            runScreenshot(rest)
            return
        }
        if name == "ls" {
            runLs(rest)
            return
        }
        run(name)
    }

    private func runScreenshot(_ rest: [String]) {
        var args: [String: String] = [:]
        if let i = rest.firstIndex(of: "--depth"), i + 1 < rest.count {
            args["depth"] = rest[i + 1]
        }
        if rest.contains("--no-save") {
            args["save"] = "false"
        }
        listener.runCommand("screenshot",
                            args: args.isEmpty ? nil : args) { [weak self] result in
            self?.renderRows(result, command: "screenshot")
        }
    }

    /// Generic grouped-rows renderer for commands whose output is
    /// group -> [[label, value]] (everything except gestalt's sliced view).
    private func renderRows(_ result: CommandResult, command: String) {
        guard result.ok, let output = result.output else {
            let error = result.error
            append(.failure, "\(command): \(error?.message ?? "failed") "
                + "[\(error?.code ?? "error")]")
            return
        }
        for group in output.keys.sorted() {
            guard let rows = output[group] else { continue }
            let width = rows.map { $0.first?.count ?? 0 }.max() ?? 0
            for row in rows where row.count >= 2 {
                let label = row[0].padding(toLength: width, withPad: " ",
                                           startingAt: 0)
                append(.output, "  \(label)  \(row[1])")
            }
        }
    }

    private static let fullGroups = ["cpu", "memory", "os", "network", "hw"]

    private static func flagToGroup(_ flag: String) -> String? {
        switch flag {
        case "--cpu": return "cpu"
        case "--memory": return "memory"
        case "--os": return "os"
        case "--network": return "network"
        case "--hardware": return "hw"
        default: return nil
        }
    }

    private func runGestalt(_ rest: [String]) {
        let full = rest.contains("--full")
        let save = rest.contains("--save")
        let group = rest.compactMap(Self.flagToGroup).first
        // The command always returns every group; the console shows a slice.
        listener.runCommand("gestalt") { [weak self] result in
            self?.renderGestalt(result, group: group, full: full, save: save)
        }
    }

    private func renderGestalt(_ result: CommandResult, group: String?,
                               full: Bool, save: Bool) {
        guard result.ok, let output = result.output else {
            let error = result.error
            append(.failure, "gestalt: \(error?.message ?? "failed") "
                + "[\(error?.code ?? "error")]")
            return
        }
        var rendered: [String] = []
        func emit(_ rows: [[String]]) {
            let width = rows.map { $0.first?.count ?? 0 }.max() ?? 0
            for row in rows where row.count >= 2 {
                let label = row[0].padding(toLength: width, withPad: " ",
                                           startingAt: 0)
                rendered.append("  \(label)  \(row[1])")
            }
        }
        if full {
            for name in Self.fullGroups {
                guard let rows = output[name] else { continue }
                rendered.append("[\(name)]")
                emit(rows)
            }
        } else if let group {
            if let rows = output[group] {
                emit(rows)
            } else {
                rendered.append("no such group: \(group)")
            }
        } else if let rows = output["snapshot"] {
            emit(rows)
        }
        for line in rendered { append(.output, line) }
        if save {
            saveToDisk(rendered)
        }
    }

    private func saveToDisk(_ lines: [String]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/NOW gestalt.txt")
        let body = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            append(.notice, "Saved to \(url.path)")
        } catch {
            append(.failure, "Save failed: \(error.localizedDescription)")
        }
    }

    private func showHelpList() {
        append(.notice, "Commands on the connected Mac:")
        for key in (Self.commands + ["help", "clear"]).sorted() {
            let summary = Self.catalog[key]?.summary ?? ""
            append(.notice,
                   "  \(key.padding(toLength: 8, withPad: " ", startingAt: 0)) \(summary)")
        }
        append(.notice, "Add --help or -h to any command for details.")
    }

    private func showHelp(for name: String) {
        if let info = Self.catalog[name] {
            for line in info.help { append(.notice, line) }
        } else {
            append(.failure, "No help for \"\(name)\"")
        }
    }

    /// ls carries a positional path: "ls Lab:Code".
    private func runLs(_ rest: [String]) {
        let path = rest.first ?? ""
        listener.runCommand("ls", args: path.isEmpty ? nil
                                                     : ["path": path]) {
            [weak self] result in
            self?.renderRows(result, command: "ls")
        }
    }

    private func run(_ command: String) {
        guard Self.commands.contains(command) else {
            append(.failure,
                   "\(command): not a declared command (try \"help\")")
            return
        }
        listener.runCommand(command) { [weak self] result in
            self?.render(command, result)
        }
    }

    private func render(_ command: String, _ result: CommandResult) {
        // Generic path for non-gestalt commands: any grouped [label, value]
        // rows render aligned, so a new guest command needs no host code.
        if let error = result.error {
            append(.failure, "\(command): \(error.message) [\(error.code)]")
            return
        }
        guard let output = result.output, !output.isEmpty else {
            append(.output, "(ok)")
            return
        }
        let width = output.values.joined()
            .compactMap(\.first?.count).max() ?? 0
        for key in output.keys.sorted() {
            for row in output[key] ?? [] where row.count >= 2 {
                let label = row[0].padding(toLength: max(width, row[0].count),
                                           withPad: " ", startingAt: 0)
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
