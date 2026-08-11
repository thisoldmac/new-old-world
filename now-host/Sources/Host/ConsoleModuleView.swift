import SwiftUI

struct ConsoleModuleView: View {
    @ObservedObject var model: ConsoleModel
    @ObservedObject var listener: GuestListener

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(28)
            Divider()
            scrollback
            Divider()
            inputLine
                .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Console")
                    .font(.largeTitle.weight(.semibold))
                Text("A command line on \(MachineNaming.sentence(machineName)). "
                     + "Lines go across as typed; \"help\" asks it what it "
                     + "serves.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectionBadge
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch listener.state {
        case .connected(let name):
            Label(MachineNaming.title(name), systemImage: "circle.fill")
                .foregroundStyle(.green)
        default:
            Label("No \(MachineNaming.properNoun) Connected",
                  systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// What the machine on the wire calls itself, when there is one.
    private var machineName: String? {
        if case .connected(let name) = listener.state { return name }
        return nil
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.lines) { line in
                        text(for: line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.lines) { _ in
                if let last = model.lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func text(for line: ConsoleModel.Line) -> Text {
        switch line.kind {
        case .input(let guest):
            return Text("\(guest)> ").foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
                + Text(line.text)
                .font(.system(.body, design: .monospaced).weight(.semibold))
        case .output:
            return Text(line.text)
                .font(.system(.body, design: .monospaced))
        case .failure:
            return Text(line.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.red)
        case .notice:
            return Text(line.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var inputLine: some View {
        HStack(spacing: 8) {
            Text(promptLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            // AppKit, for ↑/↓ history and Tab completion — see
            // ConsoleInputField for why SwiftUI cannot serve them here.
            ConsoleInputField(
                text: $model.input,
                isEnabled: isConnected,
                placeholder: "command",
                onSubmit: { model.submit() },
                onRecall: { model.recallHistory($0) },
                onComplete: { model.complete($0) })
        }
    }

    private var isConnected: Bool {
        if case .connected = listener.state { return true }
        return false
    }

    private var promptLabel: String {
        if case .connected(let name) = listener.state {
            return "\(name)>"
        }
        return "(no mac)>"
    }
}
