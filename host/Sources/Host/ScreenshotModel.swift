import Foundation

enum CaptureDepth: Int, CaseIterable, Identifiable, Sendable {
    case mono = 1
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

struct ScreenshotRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let width: Int
    let height: Int
    let depth: CaptureDepth
    let savedURL: URL?
}

@MainActor
final class ScreenshotModuleModel: ObservableObject {
    @Published var connection: GuestConnectionState = .disconnected
    @Published var selectedDepth: CaptureDepth = .indexed
    @Published private(set) var history: [ScreenshotRecord] = []

    var canCapture: Bool { connection.canCapture }

    func receive(_ record: ScreenshotRecord) {
        history.insert(record, at: 0)
    }
}

