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

/// Rolling numbers for the live stream — the tuning surface: watch fps
/// respond as depth, chunk, pacing, and compression change.
struct StreamStats: Equatable {
    var frames: Int
    var fps: Double
    var kbPerSecond: Double
    var lastFrameMs: Int
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

    /// Live-stream state: the latest frame replaces the preview while the
    /// bracket is open; frames never touch history, disk, or clipboard.
    @Published private(set) var isStreaming = false
    @Published private(set) var liveFrame: ScreenshotRecord?
    @Published private(set) var streamStats: StreamStats?

    /// The landing pad: guest-initiated screenshots always save here;
    /// host-initiated ones only when autoSave says so (they already have a
    /// home — the panel).
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

    var canCapture: Bool {
        connection.canCapture && !isCapturing && !isStreaming
    }
    var canStream: Bool { connection.canCapture && !isCapturing }
    var latest: ScreenshotRecord? { history.first }

    private enum Keys {
        static let autoSave = "screenshots.autoSave"
        static let autoCopy = "screenshots.autoCopy"
        static let saveDirectory = "screenshots.saveDirectory"
    }

    /// Called when a guest-initiated screenshot lands; the app wires the
    /// system-notification toaster here. Kept as a closure so tests and
    /// headless runs stay silent.
    var announce: ((_ guest: String, _ format: CaptureFormat,
                    _ fileURL: URL?) -> Void)?

    private let listener: GuestListener
    private let defaults: UserDefaults
    private var progressWatch: AnyCancellable?
    private var pushWatch: AnyCancellable?
    private var streamWatch: AnyCancellable?
    private var streamStateWatch: AnyCancellable?
    private var frameClock: [Date] = []
    private static let historyLimit = 20
    private static let fpsWindow = 10

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
        pushWatch = listener.pushedCaptures
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.receivePushed($0) }
        streamWatch = listener.streamFrames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.receiveStreamFrame($0) }
        streamStateWatch = listener.$activeStreamId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.streamStateChanged(id) }
    }

    func startStream() {
        guard canStream else { return }
        lastError = nil
        listener.startStream(depth: selectedDepth.rawValue)
    }

    func stopStream() {
        listener.stopStream()
    }

    private func streamStateChanged(_ id: Int?) {
        let streaming = id != nil
        guard streaming != isStreaming else { return }
        isStreaming = streaming
        if streaming {
            frameClock = []
            streamStats = nil
            liveFrame = nil
        } else if let reason = listener.streamEndReason {
            lastError = "Stream ended: \(reason)"
        }
    }

    private func receiveStreamFrame(_ delivery: GuestListener.CaptureDelivery) {
        let record = ScreenshotRecord(
            capturedAt: Date(), image: delivery.image,
            format: delivery.format, transferMs: delivery.transferMs,
            wireBytes: delivery.wireBytes)
        liveFrame = record
        frameClock.append(record.capturedAt)
        if frameClock.count > Self.fpsWindow {
            frameClock.removeFirst(frameClock.count - Self.fpsWindow)
        }
        var stats = streamStats
            ?? StreamStats(frames: 0, fps: 0, kbPerSecond: 0, lastFrameMs: 0)
        stats.frames += 1
        stats.lastFrameMs = delivery.transferMs
        if frameClock.count >= 2,
           let first = frameClock.first, let last = frameClock.last {
            let span = last.timeIntervalSince(first)
            if span > 0 {
                stats.fps = Double(frameClock.count - 1) / span
            }
        }
        if delivery.transferMs > 0 {
            stats.kbPerSecond = Double(delivery.wireBytes) / 1024.0
                / (Double(delivery.transferMs) / 1000.0)
        }
        streamStats = stats
    }

    /// A guest-initiated screenshot: same record as a requested one, but it
    /// always writes to the landing pad — unlike a panel capture it has no
    /// other home — and it announces itself.
    func receivePushed(_ delivery: GuestListener.CaptureDelivery) {
        let record = ScreenshotRecord(
            capturedAt: Date(), image: delivery.image,
            format: delivery.format, transferMs: delivery.transferMs,
            wireBytes: delivery.wireBytes)
        receive(record)
        if autoCopy {
            copyToPasteboard(record)
        }
        var savedTo: URL?
        if let failure = write(record, to: saveDirectory, savedTo: &savedTo) {
            lastError = failure
        }
        let guest: String
        if case .connected(let name) = connection {
            guest = name
        } else {
            guest = "the guest"
        }
        announce?(guest, record.format, savedTo)
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
        var ignored: URL?
        return write(record, to: directory, savedTo: &ignored)
    }

    func write(_ record: ScreenshotRecord, to directory: URL,
               savedTo: inout URL?) -> String? {
        savedTo = nil
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
            savedTo = url
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
