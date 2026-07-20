import AVFoundation
import XCTest
@testable import Host

@MainActor
final class StreamRecorderTests: XCTestCase {
    private func testImage(shade: UInt8) throws -> CGImage {
        let pixels = [UInt8](repeating: shade, count: 16 * 16)
        let format = CaptureFormat(
            width: 16, height: 16, depth: 8, rowBytes: 16,
            bytes: pixels.count, paletteBytes: 0, packed: false,
            captureMs: 0, encodeMs: 0)
        var palette = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            palette[i * 3] = UInt8(i)
            palette[i * 3 + 1] = UInt8(i)
            palette[i * 3 + 2] = UInt8(i)
        }
        return try CaptureDecoder.renderImage(pixels: pixels,
                                              palette: palette,
                                              format: format)
    }

    func testRecordsAPlayableMovieWithRealTimestamps() async throws {
        let recorder = StreamRecorder()
        let t0 = Date()
        for i in 0..<3 {
            try recorder.append(testImage(shade: UInt8(i * 80)),
                                at: t0.addingTimeInterval(Double(i) * 0.5))
        }
        let recording: StreamRecorder.Recording? =
            await withCheckedContinuation { continuation in
                recorder.finish { continuation.resume(returning: $0) }
            }
        let finished = try XCTUnwrap(recording)
        defer { try? FileManager.default.removeItem(at: finished.url) }

        XCTAssertEqual(finished.frames, 3)
        XCTAssertEqual(finished.duration, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(finished.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: finished.url.path))

        let asset = AVURLAsset(url: finished.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let size = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(Int(size.width), 16)
    }

    func testFinishWithNoFramesOffersNothing() async {
        let recorder = StreamRecorder()
        let recording: StreamRecorder.Recording? =
            await withCheckedContinuation { continuation in
                recorder.finish { continuation.resume(returning: $0) }
            }
        XCTAssertNil(recording)
    }

    func testDiscardRemovesTheTempFile() async throws {
        let recorder = StreamRecorder()
        try recorder.append(testImage(shade: 128), at: Date())
        recorder.discard()
        // Finish after discard must not resurrect anything.
        let recording: StreamRecorder.Recording? =
            await withCheckedContinuation { continuation in
                recorder.finish { continuation.resume(returning: $0) }
            }
        XCTAssertNil(recording)
    }
}
