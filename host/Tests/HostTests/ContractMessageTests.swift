import XCTest
@testable import Host

final class ContractMessageTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let hello = Hello(contract: 1, side: "guest", version: "0.1.0",
                          name: "Power Mac G3", os: "9.1", chunk: 8192)
        let data = try ControlMessageCodec.encode(.hello(hello))
        XCTAssertEqual(try ControlMessageCodec.decode(data), .hello(hello))
    }

    func testDecodesGuestHelloJSONFromContractExample() throws {
        let json = """
        {"type":"hello","contract":1,"side":"guest","version":"0.1.0",\
        "name":"PowerBook 1400","os":"9.1"}
        """
        let message = try ControlMessageCodec.decode(Data(json.utf8))
        guard case .hello(let hello) = message else {
            return XCTFail("expected hello, got \(message)")
        }
        XCTAssertEqual(hello.contract, Contract.revision)
        XCTAssertEqual(hello.side, "guest")
        XCTAssertNil(hello.chunk)
    }

    func testPingPongCarryId() throws {
        let ping = try ControlMessageCodec.encode(.ping(id: 42))
        XCTAssertEqual(try ControlMessageCodec.decode(ping), .ping(id: 42))
        let pong = try ControlMessageCodec.encode(.pong(id: 42))
        XCTAssertEqual(try ControlMessageCodec.decode(pong), .pong(id: 42))
    }

    func testRefuseAndErrorRoundTrip() throws {
        let refuse = Refuse(contract: 1, reason: "contract revision 2 != 1")
        let error = ErrorMessage(id: 3, code: "capture-no-memory",
                                 message: "Not enough memory for 32-bit")
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.refuse(refuse))),
            .refuse(refuse))
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.error(error))),
            .error(error))
    }

    func testCaptureFlowMessagesRoundTrip() throws {
        let request = CaptureRequest(id: 1, depth: 8)
        let begin = CaptureBegin(id: 1, transfer: 5, width: 640, height: 480,
                                 depth: 8, rowBytes: 640, bytes: 307200)
        let end = CaptureEnd(id: 1, transfer: 5, ok: true)
        for message: ControlMessage in [.captureRequest(request),
                                        .captureBegin(begin),
                                        .captureEnd(end)] {
            XCTAssertEqual(
                try ControlMessageCodec.decode(
                    ControlMessageCodec.encode(message)),
                message)
        }
    }

    func testUnknownTypeThrows() {
        let json = Data("{\"type\":\"teleport\"}".utf8)
        XCTAssertThrowsError(try ControlMessageCodec.decode(json)) { error in
            XCTAssertEqual(error as? ControlMessageError,
                           .unknownType("teleport"))
        }
    }

    func testNonObjectAndMissingTypeThrow() {
        XCTAssertThrowsError(
            try ControlMessageCodec.decode(Data("[1,2]".utf8)))
        XCTAssertThrowsError(
            try ControlMessageCodec.decode(Data("{\"id\":1}".utf8)))
    }
}
