import XCTest
@testable import Host

final class FrameCodecTests: XCTestCase {
    func testHeaderLayoutIsBigEndianPerContract() throws {
        let data = try FrameCodec.encode(channel: .bulk, flags: [.end],
                                         transfer: 0x1234,
                                         payload: Data([0xAB, 0xCD]))
        XCTAssertEqual([UInt8](data),
                       [1, 1, 0x12, 0x34, 0, 0, 0, 2, 0xAB, 0xCD])
    }

    func testRoundTrip() throws {
        let payload = Data("{\"type\":\"ping\",\"id\":7}".utf8)
        let encoded = try FrameCodec.encode(channel: .control, payload: payload)
        let frames = try FrameDecoder().feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].header.channel, .control)
        XCTAssertEqual(frames[0].header.transfer, 0)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testDecoderReassemblesAcrossArbitrarySplits() throws {
        let a = try FrameCodec.encode(channel: .control,
                                      payload: Data("first".utf8))
        let b = try FrameCodec.encode(channel: .bulk, flags: [.end],
                                      transfer: 9,
                                      payload: Data("second".utf8))
        let stream = a + b
        for splitAt in 1..<stream.count {
            let decoder = FrameDecoder()
            var frames = try decoder.feed(stream.prefix(splitAt))
            frames += try decoder.feed(stream.suffix(stream.count - splitAt))
            XCTAssertEqual(frames.count, 2, "split at \(splitAt)")
            XCTAssertEqual(frames[0].payload, Data("first".utf8))
            XCTAssertEqual(frames[1].header.transfer, 9)
            XCTAssertTrue(frames[1].header.flags.contains(.end))
        }
    }

    func testEmptyPayloadFrame() throws {
        let encoded = try FrameCodec.encode(channel: .control, payload: Data())
        let frames = try FrameDecoder().feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload.count, 0)
    }

    func testOversizedPayloadRefusedOnEncode() {
        let big = Data(count: FrameHeader.maxPayloadLength + 1)
        XCTAssertThrowsError(try FrameCodec.encode(channel: .bulk,
                                                   payload: big)) { error in
            XCTAssertEqual(error as? FrameCodecError,
                           .payloadTooLarge(big.count))
        }
    }

    func testOversizedDeclaredLengthKillsStream() {
        var bytes: [UInt8] = [0, 0, 0, 0]
        bytes += [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try FrameDecoder().feed(Data(bytes))) { error in
            XCTAssertEqual(error as? FrameCodecError,
                           .oversizedFrame(declared: 0xFFFF_FFFF))
        }
    }

    func testUnknownChannelKillsStream() {
        let bytes: [UInt8] = [7, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try FrameDecoder().feed(Data(bytes))) { error in
            XCTAssertEqual(error as? FrameCodecError, .unknownChannel(7))
        }
    }
}
