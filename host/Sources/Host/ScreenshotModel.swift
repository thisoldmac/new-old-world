import AppKit
import Combine
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
    /// Bytes in over bytes promised, while a transfer is in flight.
    @Published private(set) var progress: GuestListener.CaptureProgress?

    /// Where auto-saved captures land, and whether they land at all. Both
    /// persist so the folder survives a relaunch.
    @Published var autoSave: Bool {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }
    /// Put each capture on the pasteboard as it lands, so a screenshot can
    /// go straight into a message without a round trip through the disk.
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Keys.autoCopy) }
    }
    @Published var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: Keys.saveDirectory) }
    }

    var canCapture: Bool { connection.canCapture && !isCapturing }
    var latest: ScreenshotRecord? { history.first }

    private enum Keys {
        static let autoSave = "screenshots.autoSave"
        static let autoCopy = "screenshots.autoCopy"
        static let saveDirectory = "screenshots.saveDirectory"
    }

    private let listener: GuestListener
    private let defaults: UserDefaults
    private var progressWatch: AnyCancellable?
    private static let historyLimit = 20

    init(listener: GuestListener, defaults: UserDefaults = .standard) {
        self.listener = listener
        self.defaults = defaults
        self.autoSave = defaults.bool(forKey: Keys.autoSave)
        self.autoCopy = defaults.bool(forKey: Keys.autoCopy)
        let stored = defaults.string(forKey: Keys.saveDirectory)
        self.saveDirectory = stored.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .picturesDirectory,
                                        in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        progressWatch = listener.$captureProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.progress = $0 }
    }

    func capture() {
        guard canCapture else { return }
        isCapturing = true
        lastError = nil
        listener.requestCapture(depth: selectedDepth.rawValue) { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            self.progress = nil
            switch $0 {
            case .success(let delivery):
                let record = ScreenshotRecord(
                    capturedAt: Date(), image: delivery.image,
                    format: delivery.format, transferMs: delivery.transferMs,
                    wireBytes: delivery.wireBytes)
                self.receive(record)
                if self.autoCopy {
                    self.copyToPasteboard(record)
                }
                if self.autoSave {
                    self.lastError = self.write(record,
                                                to: self.saveDirectory)
                }
            case .failure(let failure):
                self.lastError = failure.message
            }
        }
    }

    /// Asks the guest to stop. The failed capture.end that follows is what
    /// clears `isCapturing`, so the button state always tracks the wire.
    func cancel() {
        guard isCapturing else { return }
        listener.cancelCapture()
    }

    /// Writes a PNG into `directory` under a non-colliding name. Returns a
    /// human-readable reason on failure, nil on success.
    @discardableResult
    func write(_ record: ScreenshotRecord, to directory: URL) -> String? {
        guard let png = CaptureDecoder.pngData(record.image) else {
            return "Could not encode the capture as PNG"
        }
        let stamp = Self.stampFormatter.string(from: record.capturedAt)
        var url = directory.appendingPathComponent("NOW \(stamp).png")
        var bump = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("NOW \(stamp) \(bump).png")
            bump += 1
        }
        do {
            try png.write(to: url)
            return nil
        } catch {
            return "Could not save to \(directory.lastPathComponent): "
                + error.localizedDescription
        }
    }

    /// Replaces the pasteboard with the capture as a TIFF-backed image.
    func copyToPasteboard(_ record: ScreenshotRecord) {
        let rep = NSBitmapImageRep(cgImage: record.image)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func receive(_ record: ScreenshotRecord) {
        history.insert(record, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}
