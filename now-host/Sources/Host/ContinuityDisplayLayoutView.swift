import SwiftUI

struct ContinuityDisplayLayoutView: View {
    @ObservedObject var layout: ContinuityDisplayLayout
    @ObservedObject var edge: ContinuityEdgeController
    @ObservedObject var previews: ContinuityDisplayPreviewStore
    let guestName: String
    let continuityRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Arrange Displays")
                        .font(.title2.weight(.semibold))
                    Text("The host displays are fixed. Drag the blue guest "
                         + "display to the edge where the pointer should pass.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh Host Displays") { layout.refreshDisplays() }
            }

            ContinuityArrangementCanvas(layout: layout, previews: previews,
                                        guestName: guestName)
                .frame(minHeight: 280)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .overlay(alignment: .bottomLeading) {
                    /* A preview that could not be taken says why, in the
                       canvas. The alternative - flat fills with no
                       explanation - is indistinguishable from a Mac whose
                       displays are simply grey, and a black rectangle is
                       worse still. */
                    if let note = previews.note {
                        Text(note.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }

            /* This row squished to a one-letter-per-line sliver on a narrow
               window: an HStack has no compression resistance of its own,
               so a parent narrower than the row's ideal width shrank every
               Text and Button down with it, and SwiftUI's last resort for
               text that has nowhere left to go is wrapping mid-word rather
               than clipping. `.fixedSize` tells the row to lay out at its
               IDEAL width regardless of what the parent offers; the
               ScrollView around it is what makes that safe — an oversized
               row scrolls horizontally instead of overflowing the pane, so
               the controls stay one line and clickable at any window
               width the app permits. */
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 16) {
                    Text("Guest size")
                        .font(.headline)
                    Text("\(Int(layout.guestSize.width)) × "
                         + "\(Int(layout.guestSize.height))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Divider().frame(height: 24)
                    Text("Layout scale")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(GuestDisplayScaleMode.allCases) { mode in
                            Button(mode.label) { layout.selectScaleMode(mode) }
                                .buttonStyle(ContinuityChoiceButtonStyle(
                                    selected: layout.scaleMode == mode))
                        }
                    }
                    Divider().frame(height: 24)
                    Toggle("Screen previews", isOn: Binding(
                        get: { previews.enabled },
                        set: { previews.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .help("Show live stills of each screen in the "
                              + "arrangement. The host side needs Screen "
                              + "Recording permission to capture its own "
                              + "displays.")
                        .lineLimit(1)
                        .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(layoutLine,
                      systemImage: layout.sharedEdge == nil
                        ? "rectangle.on.rectangle.slash"
                        : "rectangle.connected.to.line.below")
                    .font(.callout.weight(.medium))
                Text(continuityRunning ? edge.status
                     : "Turn on Continuity before crossing into the guest "
                       + "display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Cursor traversal is copy-free in this version. Files "
                     + "and held drags do not cross the display edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        // First appearance only, in effect: a placement already on disk —
        // including one a person deliberately dragged away from every edge
        // — makes this a no-op. See `attachToDefaultEdgeIfNeverPlaced`.
        .onAppear { layout.attachToDefaultEdgeIfNeverPlaced() }
    }

    private var layoutLine: String {
        guard let shared = layout.sharedEdge else {
            return "The guest display is not attached to a host edge"
        }
        return "Guest attached to \(shared.host.name)'s "
            + hostSide(shared.guestSide) + " edge"
    }

    private func hostSide(_ guestSide: GuestDisplaySide) -> String {
        switch guestSide {
        case .left: return "right"
        case .right: return "left"
        case .bottom: return "top"
        case .top: return "bottom"
        }
    }
}

struct ContinuityChoiceButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor
                        : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct ContinuityArrangementCanvas: View {
    @ObservedObject var layout: ContinuityDisplayLayout
    @ObservedObject var previews: ContinuityDisplayPreviewStore
    let guestName: String
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let transform = ArrangementTransform(
                world: layout.arrangementBounds, canvas: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.hostDisplays) { display in
                    displayTile(display, transform: transform)
                }
                guestTile(transform: transform)
            }
        }
        .padding(8)
        .task { await previews.refresh(hosts: layout.hostDisplays) }
        /* The two moments a still can go stale, and the only two: the shape
           of the arrangement changed, or the guest arrived. Not a timer. */
        .onChange(of: layout.hostDisplays) { hosts in
            Task { await previews.refresh(hosts: hosts) }
        }
        /* The toggle is the third moment: previews are off by default, so
           flipping it on is the first time there is anything to capture.
           `refresh` is already the hard gate when it is off, so this only
           needs to fire the pass back up when it turns on. */
        .onChange(of: previews.enabled) { enabled in
            guard enabled else { return }
            Task { await previews.refresh(hosts: layout.hostDisplays) }
        }
    }

    private func displayTile(_ display: HostDisplayDescriptor,
                             transform: ArrangementTransform) -> some View {
        let rect = transform.canvasRect(display.frame)
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let preview = previews.hostPreviews[display.id] {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    // The name has to stay readable over a wallpaper.
                    .overlay(Color.black.opacity(0.25))
            }
            RoundedRectangle(cornerRadius: 7)
                .stroke(display.isPrimary ? Color.primary.opacity(0.65)
                                          : Color.secondary.opacity(0.55),
                        lineWidth: display.isPrimary ? 2 : 1)
            VStack(spacing: 3) {
                Text(display.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(Int(display.pixelSize.width)) × "
                     + "\(Int(display.pixelSize.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .shadow(radius: previews.hostPreviews[display.id] == nil ? 0 : 3)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fixed host display \(display.name)")
    }

    private func guestTile(transform: ArrangementTransform) -> some View {
        let rect = transform.canvasRect(layout.guestFrame)
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(0.22))
            // No guest connected is not a failure: the tile keeps the flat
            // fill and the machine name, exactly as before previews existed.
            if let preview = previews.guestPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(Color.black.opacity(0.2))
            }
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.accentColor, lineWidth: 2)
            VStack(spacing: 3) {
                Text(guestName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("Guest · \(layout.scaleMode.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = layout.guestOrigin }
                guard let dragOrigin else { return }
                layout.setGuestOrigin(CGPoint(
                    x: dragOrigin.x + value.translation.width / transform.scale,
                    y: dragOrigin.y - value.translation.height / transform.scale))
            }
            .onEnded { _ in
                dragOrigin = nil
                layout.finishGuestMove()
            })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Movable guest display \(guestName)")
        .accessibilityHint("Drag to a host display edge")
    }
}

private struct ArrangementTransform {
    let world: CGRect
    let canvas: CGSize
    let scale: CGFloat
    private let inset: CGFloat = 24

    init(world: CGRect, canvas: CGSize) {
        let validWorld = world.isNull || world.width <= 0 || world.height <= 0
            ? CGRect(x: 0, y: 0, width: 1, height: 1) : world
        self.world = validWorld
        self.canvas = canvas
        let availableWidth = max(1, canvas.width - inset * 2)
        let availableHeight = max(1, canvas.height - inset * 2)
        scale = min(availableWidth / validWorld.width,
                    availableHeight / validWorld.height)
    }

    func canvasRect(_ rect: CGRect) -> CGRect {
        let drawnWidth = world.width * scale
        let drawnHeight = world.height * scale
        let originX = (canvas.width - drawnWidth) / 2
        let originY = (canvas.height - drawnHeight) / 2
        return CGRect(
            x: originX + (rect.minX - world.minX) * scale,
            y: originY + (world.maxY - rect.maxY) * scale,
            width: max(42, rect.width * scale),
            height: max(34, rect.height * scale))
    }
}
