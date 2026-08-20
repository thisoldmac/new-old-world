import SwiftUI

/// A transport card's session log: the ring's lines tagged with this
/// transport, in the Logs page's scrollback shape. A SESSION log honestly —
/// the tag exists only on lines this run of the app wrote, so it makes no
/// claim about history the way the persisted file could.
struct MCPTransportLogTail: View {
    static let shownLines = 100

    let kind: MCPTransportKind
    @ObservedObject var log: HostLog

    private var lines: [HostLog.Line] {
        log.lines.filter { $0.transport == kind.rawValue }
            .suffix(Self.shownLines)
    }

    var body: some View {
        let shown = lines
        if shown.isEmpty {
            Text("Nothing logged for this transport this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { line in
                            Text(line.text)
                                .font(.system(.caption,
                                              design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity,
                                       alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 160)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    if let last = shown.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: log.lines) { _ in
                    if let last = lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
