import SwiftUI

struct HostRootView: View {
    let registry: ModuleRegistry
    @ObservedObject var state: HostAppState
    @ObservedObject var sidebar: SidebarPreferences

    /// The list in the person's arrangement, which is what every part of
    /// the sidebar reads — the drag, the rows, and the icons.
    private var listModules: [ModuleDescriptor] {
        sidebar.ordered(registry.listModules)
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationTitle("Modules")
                /* Folded down, the column is exactly wide enough for the
                   icons; it is not resizable there, because there is
                   nothing in it whose width is a matter of taste. */
                .modifier(SidebarWidth(collapsed: sidebar.collapsed))
                // An inset rather than a VStack around the List, so the
                // header and footer sit inside the sidebar's material
                // instead of on top of it.
                .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .contextMenu { sidebarMenu }
        } detail: {
            // The sidebar declares its own ideal width one line above; the
            // detail never declared anything, and that asymmetry is what let
            // MCP and Diagnostics open the window wider than the display.
            //
            // A ScrollView reports its content's ideal width as its own, so a
            // module whose content has no natural width - MCP's tool payloads,
            // Diagnostics' monospaced probe output - proposed an unbounded
            // ideal and the window sized to it. The `.fixedSize(horizontal:
            // false, vertical: true)` those modules already carry wraps text
            // only once something upstream proposes a FINITE width. Nothing
            // did. This is that proposal, and it belongs here rather than in
            // each module: a module must not be able to drive the window.
            //
            // maxWidth stays infinite on purpose - this bounds what the window
            // ASKS for, never what a person can resize it to.
            detail
                .frame(minWidth: 480, idealWidth: 820,
                       maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The rows. A `ForEach` rather than `List(data:)` because `.onMove` is
    /// what makes the list draggable on macOS, and it only attaches to a
    /// ForEach.
    @ViewBuilder
    private var sidebarList: some View {
        List(selection: listSelection) {
            ForEach(listModules) { module in
                SidebarModuleRow(module: module,
                                 compact: sidebar.compact,
                                 collapsed: sidebar.collapsed)
                    .tag(module.id)
            }
            .onMove { source, destination in
                sidebar.move(registry.listModules,
                             from: source, to: destination)
            }
        }
    }

    /// The sidebar's own controls: the fold button, then the live guest the
    /// whole module stack is attached to.
    @ViewBuilder
    private var sidebarHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Button {
                    sidebar.collapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(sidebar.collapsed
                      ? "Show module names"
                      : "Collapse the sidebar to icons")
                .accessibilityLabel(sidebar.collapsed
                                    ? "Show module names"
                                    : "Collapse sidebar to icons")
                if !sidebar.collapsed {
                    Spacer(minLength: 0)
                }
            }
            SidebarGuestMenu(
                listener: state.listener,
                collapsed: sidebar.collapsed,
                select: { state.selectGuest($0) },
                add: { state.selectedModuleID = "settings" })
        }
        .padding(.horizontal, sidebar.collapsed ? 0 : 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        /* Backed for the same reason the footer is: rows scroll UNDER a
           safe-area inset, and an inset with nothing behind it renders on
           top of whatever is passing beneath. Glass keeps that promise —
           it blurs what passes under it rather than letting it through —
           and falls back to the `.bar` material this used to name outright
           below macOS 26, or when the person has asked for less
           translucency. */
        .nowGlassBar()
    }

    /// Right-click anywhere in the sidebar. The density and the reset live
    /// here rather than in a preferences window, which this app does not
    /// have on purpose — a setting belongs next to the thing it changes.
    @ViewBuilder
    private var sidebarMenu: some View {
        Picker("Rows", selection: $sidebar.compact) {
            Text("Full").tag(false)
            Text("Compact").tag(true)
        }
        .pickerStyle(.inline)
        Divider()
        Button(sidebar.collapsed ? "Show Module Names" : "Collapse to Icons") {
            sidebar.collapsed.toggle()
        }
        Button("Reset Order") {
            sidebar.resetOrder(registry.listModules)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            if !registry.footerModules.isEmpty {
                SidebarFooter(modules: registry.footerModules,
                              monitor: state.guestStatus,
                              selectedID: state.selectedModuleID,
                              collapsed: sidebar.collapsed) { id in
                    state.selectedModuleID = id
                }
            }
        }
        /* OPAQUE, and this is not decoration. `safeAreaInset` insets the
           scroll view's safe area but list rows still SCROLL UNDERNEATH
           the inset - that is what it is for, and it is only legible if
           the inset has something behind it. Without this the footer's
           text and a scrolled row render on top of each other.

           It did not show until 2026-08-01 because the module list was
           short enough never to scroll. Adding Networking made it
           scroll, and a latent bug became a visible one - so this is a
           fix for every module added after it, not for that one.

           `nowGlassBar` is backed on every path it has, which is why it
           can stand here: glass on macOS 26, which diffuses what scrolls
           beneath rather than admitting it, and the exact `.bar` material
           this line used to name outright on anything older or under
           Reduce Transparency. The invariant survives both. */
        .nowGlassBar()
    }

    /// The List only knows about the modules it draws; a footer selection
    /// reads as no selection to it, so it does not leave a second row
    /// highlighted behind the one a person actually picked.
    private var listSelection: Binding<String?> {
        Binding {
            registry.footerModules.contains { $0.id == state.selectedModuleID }
                ? nil : state.selectedModuleID
        } set: { picked in
            if let picked { state.selectedModuleID = picked }
        }
    }

    @ViewBuilder
    private var detail: some View {
        state.moduleView(registry: registry, id: state.selectedModuleID)
    }
}

/// The live-only guest menu. Registry records never enter this list: a
/// remembered machine cannot receive a module request. The final action
/// routes to Connections, where listening for another guest is configured.
struct SidebarGuestMenu: View {
    @ObservedObject var listener: GuestListener
    let collapsed: Bool
    let select: (GuestKey) -> Void
    let add: () -> Void

    var body: some View {
        Menu {
            if listener.guests.isEmpty {
                Text("No Guests Attached")
            } else {
                ForEach(listener.guests) { guest in
                    Button {
                        select(guest.key)
                    } label: {
                        if guest.isActive {
                            Label(guest.label, systemImage: "checkmark")
                        } else {
                            Text(guest.label)
                        }
                    }
                    .disabled(guest.isActive)
                }
            }
            Divider()
            Button("Add Guest…", action: add)
        } label: {
            if collapsed {
                Image(systemName: "desktopcomputer")
                    .frame(width: 18, height: 18)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text(activeLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 26,
                       alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .menuStyle(.borderlessButton)
        .help("Choose the guest every host module is attached to")
    }

    private var activeLabel: String {
        listener.guests.first(where: \.isActive)?.label
            ?? "No Guest Attached"
    }
}

/// One module in the sidebar, in whichever of the three shapes the person
/// has asked for: icon and two lines, icon and one line, or the icon alone.
///
/// Collapsed rows carry a tooltip, and that is not a nicety — an icon with
/// no name is a guess, and the tooltip is the only thing that makes the
/// folded rail readable to someone who has not memorised it.
struct SidebarModuleRow: View {
    let module: ModuleDescriptor
    let compact: Bool
    let collapsed: Bool

    var body: some View {
        if collapsed {
            HStack {
                Spacer(minLength: 0)
                Image(systemName: module.symbol)
                    .frame(width: 18, height: 18)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .help(module.title)
            .accessibilityLabel(module.title)
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title)
                    // Compact gives up the summary — that IS the density.
                    if !compact {
                        Text(module.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: module.symbol)
            }
            .padding(.vertical, compact ? 1 : 4)
            // The summary is the tooltip when compact has taken it off the
            // row, so nothing is simply lost by choosing the denser one.
            .help(compact ? module.summary : "")
        }
    }
}

/// The sidebar column's width, which is a fixed number when folded and a
/// range when not. Two `navigationSplitViewColumnWidth` calls cannot both
/// be applied conditionally in one expression — they return different
/// opaque types — so the choice lives in a modifier.
private struct SidebarWidth: ViewModifier {
    let collapsed: Bool

    func body(content: Content) -> some View {
        if collapsed {
            content.navigationSplitViewColumnWidth(64)
        } else {
            content.navigationSplitViewColumnWidth(min: 220, ideal: 250,
                                                  max: 300)
        }
    }
}

/// Holds the one subscription the footer needs, so the rows below stay pure
/// values — cheap to render anywhere, including a snapshot test.
struct SidebarFooter: View {
    let modules: [ModuleDescriptor]
    @ObservedObject var monitor: GuestStatusMonitor
    let selectedID: String
    var collapsed: Bool = false
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 2) {
                ForEach(modules) { module in
                    FooterModuleRow(module: module,
                                    status: monitor.status,
                                    isSelected: selectedID == module.id,
                                    collapsed: collapsed) {
                        select(module.id)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 4 : 10)
            .padding(.vertical, 8)
        }
        .onAppear { monitor.refresh() }
    }
}

/// A footer row reads as status first: the title, then whatever the wire is
/// doing right now, then a dot in the same colours the modules use for it.
struct FooterModuleRow: View {
    let module: ModuleDescriptor
    let status: GuestStatus
    let isSelected: Bool
    var collapsed: Bool = false
    let select: () -> Void

    var body: some View {
        if collapsed {
            collapsedBody
        } else {
            fullBody
        }
    }

    /// Folded: the icon, and - for the link's own row - the status dot
    /// still riding on it. Whether the wire is up is the one thing the
    /// footer must be able to say with no words at all.
    private var collapsedBody: some View {
        Button(action: select) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: module.symbol)
                    .frame(width: 18, height: 18)
                if module.showsLinkStatus {
                    Image(systemName: indicator.symbol)
                        .font(.system(size: 7))
                        .foregroundStyle(indicator.tint)
                        .offset(x: 5, y: -3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(module.title)
        .help(module.showsLinkStatus
              ? "\(module.title) - \(status.menuLine)"
              : module.title)
    }

    private var fullBody: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: module.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                // Only the link's own row carries the live status dot.
                if module.showsLinkStatus {
                    Image(systemName: indicator.symbol)
                        .font(.caption2)
                        .foregroundStyle(indicator.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // The caption is abbreviated to fit; the tooltip is the full line.
        .help(module.showsLinkStatus ? status.menuLine : module.summary)
    }

    /// The link's row reads as status; any other footer module reads as
    /// what it is.
    private var subtitle: String {
        module.showsLinkStatus ? status.sidebarLine : module.summary
    }

    /// The same dot vocabulary the modules use in their own headers.
    private var indicator: (symbol: String, tint: Color) {
        switch status {
        case .notListening:
            return ("circle", .secondary)
        case .waiting:
            return ("circle.dotted", .orange)
        case .connected:
            return ("circle.fill", status.isQuiet ? .orange : .green)
        case .failed:
            return ("exclamationmark.triangle", .red)
        }
    }
}
