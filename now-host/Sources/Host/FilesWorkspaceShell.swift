import AppKit
import SwiftUI

/// The guest browser is the primary workspace. This Mac is a full right-hand
/// sidebar with its own navigation, modes, resizing, and collapse control.
struct FilesWorkspaceShell: View {
    @ObservedObject var model: FilesModuleModel
    @Binding var sort: [KeyPathComparator<FileRow>]
    let chooseFileToSend: () -> Void

    @State private var hostMode = FilesHostMode.browser
    @State private var guestSidebarCompact = false
    @State private var mainPaneFraction =
        RightSidebarSplitController.defaultLeadingFraction
    @State private var guestSidebarOverride: Bool?
    @State private var hostSidebarOverride: Bool?
    @State private var hostPaneOverride: Bool?

    /// One noun for the right sidebar, read by the split component's rail
    /// and by the expanded toggle, so the two controls for one surface
    /// cannot end up naming it differently.
    static let hostSidebarTitle = "This Mac"

    var body: some View {
        GeometryReader { geometry in
            let state = FilesResponsivePolicy.resolve(
                width: geometry.size.width,
                preferences: FilesResponsivePreferences(
                    guestSidebarCompact: guestSidebarCompact,
                    hostSidebarCompact: model.hostSidebarCompact,
                    hostPaneCollapsed: model.hostPaneCollapsed))
            let guestCompact = guestSidebarOverride
                ?? state.guestSidebarCompact
            let hostCompact = hostSidebarOverride ?? state.hostSidebarCompact
            let hostCollapsed = hostPaneOverride ?? state.hostPaneCollapsed

            RightSidebarSplitView(
                isTrailingCollapsed: hostCollapsed,
                onTrailingCollapseChanged: { collapsed in
                    setHostCollapsed(collapsed, responsive: state)
                },
                leadingFraction: $mainPaneFraction,
                trailingTitle: FilesWorkspaceShell.hostSidebarTitle,
                leading: FilesGuestPane(
                    model: model,
                    sort: $sort,
                    sidebarCompact: guestCompact,
                    toggleSidebar: {
                        toggleGuestSidebar(current: guestCompact,
                                           responsive: state)
                    },
                    chooseFileToSend: chooseFileToSend,
                    compactChrome: state.usesCompactChrome),
                trailing: FilesRightSidebar(
                    model: model,
                    mode: $hostMode,
                    sidebarCompact: hostCompact,
                    toggleSidebar: {
                        toggleHostSidebar(current: hostCompact,
                                          responsive: state)
                    },
                    toggleCollapse: {
                        setHostCollapsed(true, responsive: state)
                    },
                    compactChrome: state.usesCompactChrome))
                .modifier(FilesWorkspaceFrame())
                .onChange(of: state.presentation) { _ in
                    guestSidebarOverride = nil
                    hostSidebarOverride = nil
                    hostPaneOverride = nil
                }
        }
    }

    private func toggleGuestSidebar(
        current: Bool, responsive: FilesResponsiveState
    ) {
        if responsive.presentation == .spacious {
            guestSidebarOverride = nil
            guestSidebarCompact.toggle()
        } else {
            guestSidebarOverride = current ? false : nil
        }
    }

    private func toggleHostSidebar(
        current: Bool, responsive: FilesResponsiveState
    ) {
        if responsive.presentation == .spacious {
            hostSidebarOverride = nil
            model.hostSidebarCompact.toggle()
        } else {
            hostSidebarOverride = current ? false : nil
        }
    }

    private func setHostCollapsed(
        _ collapsed: Bool, responsive: FilesResponsiveState
    ) {
        if responsive.presentation == .guestOnly {
            hostPaneOverride = collapsed ? nil : false
        } else {
            hostPaneOverride = nil
        }
        model.hostPaneCollapsed = collapsed
    }
}

private struct FilesWorkspaceFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum FilesHostMode: String, CaseIterable, Identifiable {
    case browser
    case settings
    case sharing

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .browser: "Browser"
        case .settings: "Settings"
        case .sharing: "Sharing"
        }
    }

    var symbol: String {
        switch self {
        case .browser: "folder"
        case .settings: "gearshape"
        case .sharing: "arrow.left.arrow.right"
        }
    }
}

private enum FilesBrowserTarget {
    case guest(String)
    case connecting
    case disconnected
    case host

    @ViewBuilder var title: some View {
        switch self {
        case .guest(let name): Text(verbatim: name)
        case .connecting: Text("Connecting…")
        case .disconnected: Text("No Mac Connected")
        case .host: Text("This Mac")
        }
    }

}

/// Both machines use this root. A target supplies the title and file-system
/// adapter; the pane hierarchy and chrome stay identical on either side.
private struct FilesBrowserRoot<NavigationControls: View,
                                TitleAccessory: View,
                                ViewControls: View, LocationControl: View,
                                ActionControls: View,
                                Sidebar: View, Content: View,
                                Footer: View>: View {
    let target: FilesBrowserTarget
    let showsToolbar: Bool
    let showsSidebar: Bool
    let compactChrome: Bool
    let navigationControls: NavigationControls
    let titleAccessory: TitleAccessory
    let viewControls: ViewControls
    let locationControl: LocationControl
    let actionControls: ActionControls
    let sidebar: Sidebar
    let content: Content
    let footer: Footer

    init(target: FilesBrowserTarget,
         showsToolbar: Bool = true,
         showsSidebar: Bool = false,
         compactChrome: Bool = false,
         navigationControls: NavigationControls,
         titleAccessory: TitleAccessory,
         viewControls: ViewControls,
         locationControl: LocationControl,
         actionControls: ActionControls,
         sidebar: Sidebar,
         content: Content,
         footer: Footer) {
        self.target = target
        self.showsToolbar = showsToolbar
        self.showsSidebar = showsSidebar
        self.compactChrome = compactChrome
        self.navigationControls = navigationControls
        self.titleAccessory = titleAccessory
        self.viewControls = viewControls
        self.locationControl = locationControl
        self.actionControls = actionControls
        self.sidebar = sidebar
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsToolbar {
                HStack(spacing: compactChrome ? 6 : 10) {
                    navigationControls
                    locationControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)
                    Spacer(minLength: compactChrome ? 0 : 8)
                    viewControls
                        .fixedSize()
                    actionControls
                        .fixedSize()
                    titleAccessory
                        .fixedSize()
                }
                .padding(.horizontal, FilesStyle.chromeHorizontalPadding)
                .frame(height: compactChrome ? 44 : 56)
                .filesPaneChrome()
            } else {
                HStack(spacing: 10) {
                    Spacer(minLength: 8)
                    target.title
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                    titleAccessory
                }
                .padding(.horizontal, FilesStyle.chromeHorizontalPadding)
                .frame(height: compactChrome ? 44 : 52)
                .filesPaneChrome()
            }
            Divider()
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                    Divider()
                }
                content
            }
            footer
        }
        .filesPaneSurface()
    }
}

private struct FilesHostModePill: View {
    @Binding var mode: FilesHostMode
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: FilesStyle.chromeHorizontalPadding)
            HStack(spacing: 2) {
                ForEach(FilesHostMode.allCases) { item in
                    Button { mode = item } label: {
                        Group {
                            if compact {
                                Image(systemName: item.symbol)
                                    .help(item.title)
                            } else {
                                Text(item.title)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: FilesStyle.controlHeight)
                        .contentShape(FilesStyle.controlShape)
                    }
                    .buttonStyle(.plain)
                    .background {
                        FilesStyle.controlShape
                            .fill(mode == item
                                  ? Color.accentColor.opacity(0.22)
                                  : Color.clear)
                    }
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                    .accessibilityLabel(Text(item.title))
                }
            }
            .padding(3)
            .frame(minWidth: compact ? 150 : 210,
                   idealWidth: compact ? 174 : 264,
                   maxWidth: compact ? 200 : 300)
            .nowGlassPanel(cornerRadius: FilesStyle.controlHeight)
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            Spacer(minLength: FilesStyle.chromeHorizontalPadding)
        }
        .padding(.vertical, FilesStyle.controlVerticalPadding)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FilesGuestPane: View {
    @ObservedObject var model: FilesModuleModel
    @Binding var sort: [KeyPathComparator<FileRow>]
    let sidebarCompact: Bool
    let toggleSidebar: () -> Void
    let chooseFileToSend: () -> Void
    let compactChrome: Bool

    var body: some View {
        FilesBrowserRoot(
            target: guestTarget,
            showsSidebar: true,
            compactChrome: compactChrome,
            navigationControls: FilesNavigationButtons(
                canGoBack: model.canGoBack && model.canBrowse,
                canGoForward: model.canGoForward && model.canBrowse,
                canGoUp: !model.breadcrumb.isEmpty && model.canBrowse,
                goBack: model.goBack,
                goForward: model.goForward,
                goUp: model.goUp),
            titleAccessory: EmptyView(),
            viewControls: FilesBrowserViewPicker(
                label: "Guest browser view",
                selection: $model.browserView,
                compact: compactChrome),
            locationControl: FilesGuestFolderTitle(model: model),
            actionControls: FilesGuestActions(
                model: model,
                chooseFileToSend: chooseFileToSend,
                compact: compactChrome),
            sidebar: FilesPlacesSidebar(model: model,
                                        compact: sidebarCompact,
                                        toggleCompact: toggleSidebar),
            content: FilesGuestContent(model: model, sort: $sort),
            footer: FilesGuestStatusBar(model: model))
    }

    private var guestTarget: FilesBrowserTarget {
        switch model.connection {
        case .connected(let name, _): .guest(name)
        case .connecting: .connecting
        case .disconnected: .disconnected
        }
    }
}

private struct FilesRightSidebar: View {
    @ObservedObject var model: FilesModuleModel
    @Binding var mode: FilesHostMode
    let sidebarCompact: Bool
    let toggleSidebar: () -> Void
    let toggleCollapse: () -> Void
    let compactChrome: Bool
    @StateObject private var browser: HostFilesBrowserModel

    init(model: FilesModuleModel,
         mode: Binding<FilesHostMode>,
         sidebarCompact: Bool,
         toggleSidebar: @escaping () -> Void,
         toggleCollapse: @escaping () -> Void,
         compactChrome: Bool) {
        self.model = model
        _mode = mode
        self.sidebarCompact = sidebarCompact
        self.toggleSidebar = toggleSidebar
        self.toggleCollapse = toggleCollapse
        self.compactChrome = compactChrome
        _browser = StateObject(wrappedValue:
            HostFilesBrowserModel(root: model.shareDirectory,
                                  includesSystemLocations: true))
    }

    var body: some View {
        FilesBrowserRoot(
            target: .host,
            showsToolbar: mode == .browser,
            showsSidebar: mode == .browser,
            compactChrome: compactChrome,
            navigationControls: Group {
                if mode == .browser {
                    FilesNavigationButtons(
                        canGoBack: browser.canGoBack,
                        canGoForward: browser.canGoForward,
                        canGoUp: browser.canGoUp,
                        goBack: browser.goBack,
                        goForward: browser.goForward,
                        goUp: browser.goUp)
                }
            },
            titleAccessory: RightSidebarToggle(
                isCollapsed: false,
                title: FilesWorkspaceShell.hostSidebarTitle,
                action: toggleCollapse),
            viewControls: FilesBrowserViewPicker(
                label: "This Mac browser view",
                selection: $model.hostBrowserView,
                compact: compactChrome),
            locationControl: FilesHostFolderTitle(model: browser),
            actionControls: HostFilesBrowserActions(model: browser),
            sidebar: HostFilesSidebar(model: browser,
                                      compact: sidebarCompact,
                                      toggleCompact: toggleSidebar),
            content: FilesHostModeContent(
                mode: mode,
                filesModel: model,
                browser: browser),
            footer: FilesHostModePill(mode: $mode, compact: compactChrome))
        .onChange(of: model.shareDirectory) { browser.setRoot($0) }
    }
}

private struct FilesHostModeContent: View {
    let mode: FilesHostMode
    @ObservedObject var filesModel: FilesModuleModel
    @ObservedObject var browser: HostFilesBrowserModel

    @ViewBuilder var body: some View {
        switch mode {
        case .browser:
            FilesHostBrowserView(model: browser, view: filesModel.hostBrowserView)
        case .settings:
            FilesSettingsPane(model: filesModel)
        case .sharing:
            FilesSharingPane(model: filesModel)
        }
    }
}

private struct FilesBrowserViewPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: FilesBrowserView
    let compact: Bool

    var body: some View {
        if compact {
            Menu {
                ForEach(FilesBrowserView.allCases) { view in
                    Toggle(isOn: Binding(
                        get: { selection == view },
                        set: { selected in
                            if selected { selection = view }
                        })) {
                        Label(view.title, systemImage: view.symbol)
                    }
                }
            } label: {
                Image(systemName: selection.symbol)
                    .frame(width: FilesStyle.controlHeight,
                           height: FilesStyle.controlHeight)
            }
            .fixedSize()
            .nowGlassButton()
            .accessibilityLabel(label)
            .accessibilityValue(Text(selection.title))
            .help(Text(selection.title))
        } else {
            Picker(label, selection: $selection) {
                ForEach(FilesBrowserView.allCases) { view in
                    Image(systemName: view.symbol)
                        .accessibilityLabel(Text(view.title))
                        .help(Text(view.title))
                        .tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }
}

private struct FilesGuestFolderTitle: View {
    @ObservedObject var model: FilesModuleModel

    var body: some View {
        FilesCurrentFolderControl(
            display: .guest(
                shareRoot: model.shareRoot,
                breadcrumb: model.breadcrumb,
                source: sourceTitle),
            isEnabled: model.canBrowse,
            select: { id in
                guard let depth = Int(id) else { return }
                model.jump(toDepth: depth)
            })
            .frame(minWidth: 96, idealWidth: 180, maxWidth: 320,
                   minHeight: FilesStyle.controlHeight)
    }

    private var sourceTitle: String {
        switch model.connection {
        case .connected(let name, _): name
        case .connecting: String(localized: "Connecting…")
        case .disconnected: String(localized: "No Mac Connected")
        }
    }
}

private struct FilesGuestActions: View {
    @ObservedObject var model: FilesModuleModel
    let chooseFileToSend: () -> Void
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            if compact {
                Menu {
                    Button("New Folder") { model.beginNewFolder() }
                        .disabled(!model.canBrowse || model.isChanging)
                    Button("Send File…", action: chooseFileToSend)
                        .disabled(!model.canBrowse || model.transfer != nil)
                    if let title = model.undoTitle {
                        Button(title) { model.undoLastChange() }
                    }
                    Divider()
                    Button("Refresh") { model.refreshBrowser() }
                        .disabled(!model.canBrowse)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: FilesStyle.controlHeight,
                               height: FilesStyle.controlHeight)
                }
                .fixedSize()
                .nowGlassButton()
                .accessibilityLabel("File actions")
                .help("File actions")
            } else {
                HStack(spacing: 0) {
                    FilesToolbarActionButton(
                        symbol: "folder.badge.plus", label: "New Folder",
                        isEnabled: model.canBrowse && !model.isChanging,
                        action: model.beginNewFolder)
                    FilesToolbarActionButton(
                        symbol: "plus", label: "Send File…",
                        isEnabled: model.canBrowse && model.transfer == nil,
                        action: chooseFileToSend)
                    if let title = model.undoTitle {
                        FilesToolbarActionButton(
                            symbol: "arrow.uturn.backward",
                            label: "Undo Last File Change",
                            help: title, isEnabled: true,
                            action: model.undoLastChange)
                    }
                    FilesToolbarActionButton(
                        symbol: "arrow.clockwise", label: "Refresh",
                        isEnabled: model.canBrowse,
                        action: model.refreshBrowser)
                }
                .padding(3)
                .nowGlassPanel(cornerRadius: FilesStyle.controlHeight)
            }
        }
    }
}

struct FilesToolbarActionButton: View {
    let symbol: String
    let label: LocalizedStringResource
    var help: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: FilesStyle.controlHeight,
                       height: FilesStyle.controlHeight)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
        .help(help ?? String(localized: label))
    }
}

private struct FilesGuestContent: View {
    @ObservedObject var model: FilesModuleModel
    @Binding var sort: [KeyPathComparator<FileRow>]

    var body: some View {
        FilesBrowserNavigationHost(
            goBack: model.goBack, goForward: model.goForward) {
                GuestBrowserContent(model: model,
                                    rows: model.sorted(using: sort),
                                    sort: $sort)
                .overlay {
                    if !model.canBrowse {
                        FilesGuestUnavailable()
                    } else if model.rows.isEmpty && !model.isLoading {
                        FilesGuestEmpty(error: model.lastError)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
    }
}

private struct FilesGuestUnavailable: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36, weight: .light))
            Text("No \(MachineNaming.properNoun) Connected")
                .font(.headline)
            Text("Guest files appear once a Mac connects.")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct FilesGuestEmpty: View {
    let error: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: error == nil ? "folder" :
                    "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
            Text(error ?? "This folder is empty")
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
    }
}

private struct FilesPlacesSidebar: View {
    @ObservedObject var model: FilesModuleModel
    let compact: Bool
    let toggleCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                HStack(spacing: 6) {
                    FilesBrowserSidebarToggle(
                        compact: compact, action: toggleCompact)
                    Text("Places")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isDiscoveringLocations {
                        ProgressView().controlSize(.small)
                    }
                    Menu {
                        Button("Look Again") { model.discoverLocations() }
                            .disabled(!model.canBrowse ||
                                      model.isDiscoveringLocations)
                        Button("Add This Folder") {
                            model.pinLocation(path: model.path)
                        }
                        .disabled(model.pinnableName(for: model.path) == nil)
                        Divider()
                        Button("Restore Removed Places") {
                            model.restoreRemovedLocations()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, FilesStyle.chromeHorizontalPadding)
                .frame(height: 32)
            } else {
                FilesBrowserSidebarToggle(
                    compact: compact, action: toggleCompact)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }

            List {
                ForEach(model.locations) { location in
                    FileLocationRow(model: model, location: location,
                                    help: help(for: location),
                                    compact: compact)
                }
                .onMove { model.moveLocations(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.locations.isEmpty && !compact {
                    Text(model.isDiscoveringLocations
                         ? "Looking…"
                         : "No saved places")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .frame(width: compact ? 52 : 176)
        .animation(.easeInOut(duration: 0.18), value: compact)
        .background(SidebarVibrancyBackground())
        .onDrop(of: [.folder], isTargeted: nil) { _ in
            guard let path = model.draggedFolderPath else { return false }
            return model.pinLocation(path: path)
        }
    }

    private func help(for location: FileLocation) -> String {
        let place = location.path.isEmpty
            ? "the folder \(model.connection.peerLabel) shares"
            : location.path
        switch location.origin {
        case .root: return "Go to \(place)"
        case .folderManager:
            return "\(place) — from the guest Folder Manager."
        case .probed:
            return "\(place) — found by name probe."
        case .pinned:
            return "\(place) — added manually."
        }
    }
}

struct FilesBrowserSidebarToggle: View {
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .help(compact ? "Show Place Names" : "Collapse Places to Icons")
        .accessibilityLabel(compact ? "Show Place Names"
                                   : "Collapse Places to Icons")
    }
}

private struct FilesGuestStatusBar: View {
    @ObservedObject var model: FilesModuleModel

    var body: some View {
        HStack(spacing: 8) {
            if let error = model.lastError, !model.rows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let notice = model.lastNotice {
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .onTapGesture { model.lastNotice = nil }
                    .help("Click to dismiss")
            }
            Spacer()
            Text("\(model.rows.count) item\(model.rows.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, FilesStyle.chromeHorizontalPadding)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FilesSettingsPane: View {
    @ObservedObject var model: FilesModuleModel

    var body: some View {
        Form {
            Section("Open Guest Browser In") {
                Picker("Default folder", selection: $model.startupDirectory) {
                    ForEach(FilesStartupDirectory.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if model.startupDirectory == .custom {
                    TextField("Folder relative to the share",
                              text: $model.customStartupPath)
                    Text("Colon-separated, for example " +
                         "System Folder:Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Transfers") {
                Toggle("Convert text files", isOn: $model.convertText)
                LabeledContent("Downloads") {
                    FilesFolderPicker(current: model.downloadDirectory) {
                        model.downloadDirectory = $0
                    }
                }
            }
            Section("Guest View") {
                Picker("Layout", selection: $model.browserView) {
                    ForEach(FilesBrowserView.allCases) { view in
                        Label(view.title, systemImage: view.symbol).tag(view)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilesSharingPane: View {
    @ObservedObject var model: FilesModuleModel

    var body: some View {
        Form {
            Section("Shared from This Mac") {
                FilesFolderPicker(current: model.shareDirectory) {
                    model.shareDirectory = $0
                }
                Text(model.shareDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: model.shareDirectory.path)
                }
            }
            Section("How It Works") {
                Text("Shown in the Browser panel. Drag files into the " +
                     "\(MachineNaming.properNoun) pane to copy them to " +
                     model.connection.peerLabel + ".")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilesFolderPicker: View {
    let current: URL
    let choose: (URL) -> Void

    var body: some View {
        Menu {
            ForEach(folderChoices, id: \.path) { url in
                Button(FileManager.default.displayName(atPath: url.path)) {
                    choose(url)
                }
            }
            Divider()
            Button("Other…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = current
                if panel.runModal() == .OK, let url = panel.url {
                    choose(url)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: current.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: current.path))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var folderChoices: [URL] {
        let standard: [FileManager.SearchPathDirectory] =
            [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        var urls = standard.compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        }
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: cloud.path,
                                          isDirectory: &isDirectory),
           isDirectory.boolValue {
            urls.append(cloud)
        }
        if !urls.contains(where: { $0.path == current.path }) {
            urls.insert(current, at: 0)
        }
        return urls
    }
}
