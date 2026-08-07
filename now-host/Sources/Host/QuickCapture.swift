import Combine
import Foundation

/// What a menu-bar capture ended up doing. Phrased to stand alone: the
/// person who issued it did so without opening a window, so the outcome has
/// to carry its own context rather than lean on the panel beside it.
enum QuickCaptureOutcome: Equatable {
    case copied(width: Int, height: Int, depth: Int, savedAs: String?)
    case failed(String)

    var title: String {
        switch self {
        case .copied: return "Screenshot copied"
        case .failed: return "Screenshot failed"
        }
    }

    var body: String {
        switch self {
        case .copied(let width, let height, let depth, let savedAs):
            var line = "\(width) × \(height) · \(depth)-bit · on the clipboard"
            if let savedAs { line += " · saved as \(savedAs)" }
            return line
        case .failed(let reason):
            return reason
        }
    }

    /// The status-item flash has room for a couple of words, not a
    /// sentence — it replaces the item's own title for a moment. Its own
    /// glyph, so a flash never reads as a connection state.
    var flash: String {
        switch self {
        case .copied: return "✓ Copied"
        case .failed: return "✕ Failed"
        }
    }
}

/// Whether "Capture Screen" can run right now, and why not when it can't.
/// Pure and separate from the models so the menu's validation hook and the
/// tests agree on one rule instead of two drifting copies.
struct QuickCaptureReadiness: Equatable {
    var isEnabled: Bool
    var reason: String?

    /// There is exactly one transfer lane on the wire: a live stream or a
    /// file download owns it outright. Greying the item out is honest —
    /// firing it anyway would just earn a "busy" refusal from the guest.
    static func evaluate(connection: GuestConnectionState,
                         isCapturing: Bool,
                         isStreaming: Bool,
                         isTransferringFile: Bool) -> QuickCaptureReadiness {
        guard connection.canCapture else {
            return .init(isEnabled: false, reason: "No \(MachineNaming.commonNoun) is connected")
        }
        if isCapturing {
            return .init(isEnabled: false,
                         reason: "A screenshot is already on its way")
        }
        if isStreaming {
            return .init(isEnabled: false,
                         reason: "The live stream is using the connection")
        }
        if isTransferringFile {
            return .init(isEnabled: false,
                         reason: "A file transfer is using the connection")
        }
        return .init(isEnabled: true, reason: nil)
    }
}

/// The menu-bar command: one click captures the guest's screen and puts it
/// on the clipboard. It drives the same `ScreenshotModuleModel` the panel
/// does — history, depth, and tuning stay a single source of truth, so the
/// two surfaces can never disagree about what was captured or how.
@MainActor
final class QuickCaptureCommand: ObservableObject {
    @Published private(set) var readiness =
        QuickCaptureReadiness(isEnabled: false, reason: "No \(MachineNaming.commonNoun) is connected")

    /// Where the outcome goes. The app wires both halves of the feedback
    /// pair here; tests and headless runs simply observe.
    var report: ((QuickCaptureOutcome) -> Void)?

    private let screenshots: ScreenshotModuleModel
    private var readinessWatch: AnyCancellable?

    init(screenshots: ScreenshotModuleModel, files: FilesModuleModel) {
        self.screenshots = screenshots
        readinessWatch = Publishers.CombineLatest4(
            screenshots.$connection, screenshots.$isCapturing,
            screenshots.$isStreaming, files.$transfer)
            .map { connection, capturing, streaming, transfer in
                QuickCaptureReadiness.evaluate(
                    connection: connection, isCapturing: capturing,
                    isStreaming: streaming,
                    isTransferringFile: transfer != nil)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.readiness = $0 }
    }

    func run() {
        guard readiness.isEnabled else {
            report?(.failed(readiness.reason ?? "Not available right now"))
            return
        }
        screenshots.captureToClipboard { [weak self] in self?.report?($0) }
    }
}
