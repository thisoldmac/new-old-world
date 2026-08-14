import AppKit
import SwiftUI

struct FilesFolderMenuEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let toolTip: String
}

struct FilesCurrentFolderDisplay: Equatable {
    let title: String
    let source: String
    let symbolName: String
    let toolTip: String
    let path: [FilesFolderMenuEntry]

    static func guest(shareRoot: String?, breadcrumb: [String],
                      source: String) -> Self {
        let crumbs = FilePathBar.crumbs(
            shareRoot: shareRoot, breadcrumb: breadcrumb)
        let current = crumbs.last
        return Self(
            title: current?.name ?? "Shared Folder",
            source: source,
            symbolName: current?.isVolume == true ? "externaldrive" : "folder",
            toolTip: FilePathBar.fullPath(
                shareRoot: shareRoot, breadcrumb: breadcrumb),
            path: crumbs.compactMap { crumb in
                guard let depth = crumb.depth else { return nil }
                return FilesFolderMenuEntry(
                    id: String(depth), title: crumb.name,
                    symbolName: crumb.isVolume ? "externaldrive" : "folder",
                    toolTip: crumb.name)
            })
    }

    static func host(breadcrumbs: [HostFileLocation], source: String) -> Self {
        let current = breadcrumbs.last
        return Self(
            title: current?.name ?? source,
            source: source,
            symbolName: current?.symbol ?? "folder",
            toolTip: current?.url.path ?? source,
            path: breadcrumbs.map { location in
                FilesFolderMenuEntry(
                    id: location.url.standardizedFileURL.path,
                    title: location.name,
                    symbolName: location.symbol,
                    toolTip: location.url.path)
            })
    }
}

/// Finder shows the current folder as title chrome and reveals the ancestor
/// path contextually. This native control keeps that exact interaction while
/// allowing the guest adapter to supply an HFS path that has no local URL.
struct FilesCurrentFolderControl: NSViewRepresentable {
    let display: FilesCurrentFolderDisplay
    let isEnabled: Bool
    let select: (String) -> Void

    func makeNSView(context: Context) -> FilesCurrentFolderButton {
        let button = FilesCurrentFolderButton()
        button.onSelect = select
        button.configure(display: display, isEnabled: isEnabled)
        return button
    }

    func updateNSView(_ button: FilesCurrentFolderButton,
                      context: Context) {
        button.onSelect = select
        button.configure(display: display, isEnabled: isEnabled)
    }
}

@MainActor
final class FilesCurrentFolderButton: NSButton {
    var onSelect: (String) -> Void = { _ in }
    private var folderMenu = NSMenu()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 15, weight: .semibold)
        lineBreakMode = .byTruncatingMiddle
        focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow,
                                                for: .horizontal)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(display: FilesCurrentFolderDisplay, isEnabled: Bool) {
        self.isEnabled = isEnabled
        title = "\(display.title) — \(display.source)"
        image = NSImage(systemSymbolName: display.symbolName,
                        accessibilityDescription: nil)
        toolTip = display.toolTip
        setAccessibilityLabel(title)
        setAccessibilityHelp("Command-click or right-click to show the path")

        let menu = NSMenu(title: title)
        for entry in display.path.reversed() {
            let item = NSMenuItem(title: entry.title,
                                  action: #selector(selectPathItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.image = NSImage(systemSymbolName: entry.symbolName,
                                 accessibilityDescription: nil)
            item.toolTip = entry.toolTip
            menu.addItem(item)
        }
        folderMenu = menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(.command) {
            showFolderMenu(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showFolderMenu(with: event)
    }

    @objc private func selectPathItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect(id)
    }

    private func showFolderMenu(with event: NSEvent) {
        guard isEnabled, !folderMenu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(folderMenu, with: event, for: self)
    }
}
