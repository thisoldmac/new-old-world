import SwiftUI

/// The MCP page's card chrome, with a header a person can grab, collapse,
/// and read even while the body is away. The header carries, in order: the
/// drag handle (the only drag surface, so text selection inside a body
/// never starts a move), the disclosure chevron, the title, and the card's
/// own accessory controls — which stay live while collapsed, because Stop
/// must not require reopening the card that started something.
struct MCPCollapsibleCard<Accessories: View, Content: View>: View {
    let id: MCPCardID
    let title: String
    @ObservedObject var layoutModel: MCPCardLayoutModel
    /// Set while a drag from this page is in flight; the handle publishes
    /// the card it lifted.
    @Binding var dragged: MCPCardID?
    @ViewBuilder let accessories: () -> Accessories
    @ViewBuilder let content: () -> Content

    private var collapsed: Bool { layoutModel.layout.isCollapsed(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { moveMenu }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onDrag {
                    dragged = id
                    return NSItemProvider(object: id.rawValue as NSString)
                }
                .accessibilityLabel("Move \(title)")
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    layoutModel.toggleCollapsed(id)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(collapsed
                ? "Expand \(title)" : "Collapse \(title)")
            Text(title)
                .font(.headline)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        layoutModel.toggleCollapsed(id)
                    }
                }
            Spacer(minLength: 12)
            accessories()
        }
    }

    /// Drag has no keyboard; these do.
    @ViewBuilder private var moveMenu: some View {
        Button("Move Up") { layoutModel.nudge(id, forward: false) }
        Button("Move Down") { layoutModel.nudge(id, forward: true) }
        if layoutModel.column(of: id) == .left {
            Button("Move to Right Column") {
                layoutModel.move(id, to: .right)
            }
        } else {
            Button("Move to Left Column") {
                layoutModel.move(id, to: .left)
            }
        }
    }
}

/// Reorders live as the cursor crosses cards: `dropEntered` moves the
/// dragged card to the hovered position, which is its own insertion
/// indicator, and the drop just settles what the eye already saw.
struct MCPCardDropDelegate: DropDelegate {
    let target: MCPCardID?
    let column: MCPCardColumn
    let layoutModel: MCPCardLayoutModel
    @Binding var dragged: MCPCardID?

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        layoutModel.move(dragged, to: column, before: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragged != nil else { return false }
        dragged = nil
        return true
    }
}
