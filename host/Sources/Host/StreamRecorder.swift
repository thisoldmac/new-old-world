import AVFoundation
import CoreGraphics
import Foundation

/// Records a live stream as it plays: each delivered frame is appended to
/// a temp QuickTime movie with its real arrival timestamp, so the
/// irregular frame rate plays back with correct timing and nothing is
/// buffered — when the stream stops, the file is already encoded and
/// "offer to save" is just a finalize. Hardware H.264; classic desktop
/// content encodes crisply at this bitrate.
@MainActor
final class StreamRecorder {
    struct Recording: Equatable {
        var url: URL
        var frames: Int
        var duration: TimeInterval
        var bytes: Int
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: Date?
    private var lastTime = CMTime.zero
    private var frames = 0
    private var frameWidth = 0
    private let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-stream-\(UUID().uuidString).mov")
    }

    /// Appends one frame. The writer starts lazily on the first frame,
    /// which is when the stream's dimensions are first known.
    func append(_ image: CGImage, at date: Date) {
        if writer == nil && !start(width: image.width, height: image.height) {
            return
        }
        guard let writer, let input, let adaptor,
              writer.status == .writing,
              image.width == frameWidth else { return }
        let time: CMTime
        if let startedAt {
            time = CMTime(seconds: date.timeIntervalSince(startedAt),
                          preferredTimescale: 600)
        } else {
            startedAt = date
            time = .zero
        }
        // The writer refuses non-increasing timestamps; a same-millisecond
        // frame just nudges forward a tick.
        let stamped = time <= lastTime
            ? lastTime + CMTime(value: 1, timescale: 600) : time
        guard input.isReadyForMoreMediaData,
              let buffer = pixelBuffer(from: image) else { return }
        if adaptor.append(buffer, withPresentationTime: stamped) {
            lastTime = stamped
            frames += 1
        }
    }

    /// Finalizes the movie. Calls back on the main actor with the finished
    /// recording, or nil if nothing was ever appended.
    func finish(completion: @escaping @MainActor (Recording?) -> Void) {
        guard let writer, frames > 0 else {
            discard()
            completion(nil)
            return
        }
        let url = url
        let frames = frames
        let duration = lastTime.seconds
        input?.markAsFinished()
        nonisolated(unsafe) let finishingWriter = writer
        writer.finishWriting {
            let ok = finishingWriter.status == .completed
            Task { @MainActor in
                guard ok else {
                    try? FileManager.default.removeItem(at: url)
                    completion(nil)
                    return
                }
                let bytes = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int)
                    .flatMap { $0 } ?? 0
                completion(Recording(url: url, frames: frames,
                                     duration: duration, bytes: bytes))
            }
        }
    }

    /// Abandons the temp file without finalizing. Idempotent, and a later
    /// finish() sees a recorder with nothing in it rather than a writer
    /// that was already cancelled (finishWriting after cancelWriting is a
    /// crash, not an error).
    func discard() {
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
        writer = nil
        input = nil
        adaptor = nil
        frames = 0
        try? FileManager.default.removeItem(at: url)
    }

    private func start(width: Int, height: Int) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url,
                                              fileType: .mov) else {
            return false
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        frameWidth = width
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        return true
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width,
                                       height: image.height))
        return buffer
    }
}
