import SwiftUI
import UniformTypeIdentifiers

struct FileLocationRow: View {
    @ObservedObject var model: FilesModuleModel
    var location: FileLocation
    var help: String
    var compact = false

    private var isActive: Bool { model.isCurrentLocation(location) }

    private static let draggedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .init(UTType.folder.identifier),
    ]

    var body: some View {
        nativeRow.contextMenu {
            if location.origin != .root {
                Button("Remove from Sidebar") {
                    model.removeLocation(location)
                }
            }
        }
    }

    private var nativeRow: some View {
        FilesNativeSidebarRow(
            title: location.name,
            symbolName: location.symbol,
            compact: compact,
            isActive: isActive,
            isEnabled: model.canBrowse,
            toolTip: help,
            draggedTypes: Self.draggedTypes,
            activate: { model.go(to: location) },
            validateDrop: { info in validateDrop(info) },
            acceptDrop: { info in acceptDrop(info) })
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 30 : 28)
    }

    private func validateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard model.canBrowse else { return [] }
        if !model.draggedRows.isEmpty { return .move }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: options) ? .copy : []
    }

    private func acceptDrop(_ info: NSDraggingInfo) -> Bool {
        guard model.canBrowse else { return false }
        if !model.draggedRows.isEmpty {
            model.requestMove(model.draggedRows, toFolder: location.path)
            return true
        }
        let urls = (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        model.enqueue(urls, into: location.path)
        return true
    }
}
