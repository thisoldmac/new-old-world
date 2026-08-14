import AppKit
import SwiftUI

struct HostBrowserContent: View {
    @ObservedObject var model: HostFilesBrowserModel
    let view: FilesBrowserView

    var body: some View {
        FilesNativeBrowser(
            view: view,
            adapter: HostFileBrowserAdapter(model: model))
    }
}
