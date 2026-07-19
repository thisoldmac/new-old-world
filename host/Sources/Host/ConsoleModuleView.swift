import SwiftUI

struct ConsoleModuleView: View {
    @ObservedObject var model: ConsoleModel
    @ObservedObject var listener: GuestListener
    @FocusState private var inputFocused: Bool

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
                Text("A shell into the connected Mac — declared commands only.")
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
            Label(name, systemImage: "circle.fill")
                .foregroundStyle(.green)
        default:
            Label("No Mac Connected", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        }
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
            TextField("command", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($inputFocused)
                .onSubmit {
                    model.submit()
                    inputFocused = true
                }
                .disabled(!isConnected)
        }
        .onAppear { inputFocused = true }
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
