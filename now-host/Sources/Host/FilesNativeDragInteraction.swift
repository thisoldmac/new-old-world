import AppKit

/// AppKit imports promise completions without `Sendable`, even when the
/// delegate supplies a serial operation queue. Transfer ownership once and
/// invoke the callback only from the main actor after the model finishes.
final class FilesPromiseCompletion: @unchecked Sendable {
    private let body: (Error?) -> Void

    init(_ body: @escaping (Error?) -> Void) { self.body = body }

    @MainActor
    func finish(_ error: Error?) { body(error) }
}

extension FilesBrowserRow {
    static func promisePayload(
        from provider: NSFilePromiseProvider
    ) -> FilesBrowserRow? {
        if let row = provider.userInfo as? FileRow { return .guest(row) }
        if let row = provider.userInfo as? HostFileRow { return .host(row) }
        return nil
    }
}
/// AppKit sends periodic drag updates specifically so destinations can keep
/// scrolling while the pointer is stationary at an edge. All native browser
/// modes route that behavior through this owner instead of synthesizing drag
/// timers in SwiftUI.
@MainActor
enum FilesNativeDragAutoscroll {
    static func update(_ view: NSView) {
        guard let event = NSApp.currentEvent else { return }
        _ = view.autoscroll(with: event)
    }
}
