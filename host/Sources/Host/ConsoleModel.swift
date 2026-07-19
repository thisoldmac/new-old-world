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
    static let commands = ["gestalt"]

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
        run(name)
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
        if result.ok {
            guard let output = result.output, !output.isEmpty else {
                append(.output, "(no output)")
                return
            }
            let width = output.keys.map(\.count).max() ?? 0
            for key in output.keys.sorted() {
                let padded = key.padding(toLength: width, withPad: " ",
                                         startingAt: 0)
                append(.output, "\(padded)  \(output[key] ?? "")")
            }
        } else {
            let error = result.error
            append(.failure, "\(command): \(error?.message ?? "failed") "
                + "[\(error?.code ?? "error")]")
        }
    }

    private func append(_ kind: Line.Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
        if lines.count > Self.scrollbackLimit {
            lines.removeFirst(lines.count - Self.scrollbackLimit)
        }
    }
}
