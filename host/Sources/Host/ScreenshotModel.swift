import Foundation
import CoreGraphics

enum CaptureDepth: Int, CaseIterable, Identifiable, Sendable {
    case mono = 1
    case gray4 = 2
    case indexed16 = 4
    case indexed = 8
    case thousands = 16
    case millions = 32

    var id: Int { rawValue }
    var title: String { "\(rawValue)-bit" }
}

enum GuestConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(name: String)

    var canCapture: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// One received screen capture, with the numbers behind it.
struct ScreenshotRecord: Identifiable, Equatable {
    let id = UUID()
    let capturedAt: Date
    let image: CGImage
    let format: CaptureFormat
    let transferMs: Int
    let wireBytes: Int

    var width: Int { format.width }
    var height: Int { format.height }

    /// Raw pixel volume before compression, for the ratio readout.
    var rawBytes: Int { format.rowBytes * format.height }

    var compressionRatio: Double {
        wireBytes > 0 ? Double(rawBytes) / Double(wireBytes) : 0
    }

    static func == (lhs: ScreenshotRecord, rhs: ScreenshotRecord) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ScreenshotModuleModel: ObservableObject {
    @Published var connection: GuestConnectionState = .disconnected
    @Published var selectedDepth: CaptureDepth = .indexed
    @Published private(set) var history: [ScreenshotRecord] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    var canCapture: Bool { connection.canCapture && !isCapturing }
    var latest: ScreenshotRecord? { history.first }

    private let listener: GuestListener
    private static let historyLimit = 20

    init(listener: GuestListener) {
        self.listener = listener
    }

    func capture() {
        guard canCapture else { return }
        isCapturing = true
        lastError = nil
        listener.requestCapture(depth: selectedDepth.rawValue) { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            switch $0 {
            case .success(let delivery):
                self.receive(ScreenshotRecord(
                    capturedAt: Date(), image: delivery.image,
                    format: delivery.format, transferMs: delivery.transferMs,
                    wireBytes: delivery.wireBytes))
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    func receive(_ record: ScreenshotRecord) {
        history.insert(record, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}
