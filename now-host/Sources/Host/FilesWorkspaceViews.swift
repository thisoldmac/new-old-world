import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GuestBrowserContent: View {
    @ObservedObject var model: FilesModuleModel
    var rows: [FileRow]
    @Binding var sort: [KeyPathComparator<FileRow>]

    var body: some View {
        FilesNativeBrowser(
            view: model.browserView,
            adapter: GuestFileBrowserAdapter(
                model: model, rows: rows, onOpen: open, sort: $sort))
            .modifier(GuestFileDropSurface(model: model, folder: model.path))
    }

    private func open(_ row: FileRow) {
        row.isFolder ? model.open(row) : model.openOnThisMac(row)
    }

}

private struct GuestFileDropSurface: ViewModifier {
    private final class URLAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            storage.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @ObservedObject var model: FilesModuleModel
    var folder: String

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Self.loadURLs(providers) { urls in
                Task { @MainActor in model.enqueue(urls, into: folder) }
            }
        }
    }

    private static func loadURLs(_ providers: [NSItemProvider],
                                 completion: @escaping ([URL]) -> Void)
        -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty else { return false }
        let group = DispatchGroup()
        let urls = URLAccumulator()
        for provider in candidates {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else { url = nil }
                if let url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls.snapshot()) }
        return true
    }
}
