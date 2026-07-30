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
        XCTAssertNil(
            hello.build,
            "A hello without a build must decode with build nil. It is an "
                + "optional field and the 68K guest sends none, so absence "
                + "has to reach the host as absence rather than as a "
                + "decode failure.")
    }

    /// The whole point of the field: two builds of one version are told
    /// apart, and the version alone cannot do it.
    ///
    /// Written as a decode of the PowerPC guest's own hello shape rather
    /// than a round trip of a struct this file built, so it is the wire
    /// spelling under test.
    func testTwoBuildsOfOneVersionAreDistinguishedByBuild() throws {
        func hello(build: String) throws -> Hello {
            let json = """
            {"type":"hello","contract":1,"side":"guest","version":"0.1.0",\
            "build":"\(build)","name":"PowerBook 1400","os":"9",\
            "chunk":8192}
            """
            guard case .hello(let hello) =
                try ControlMessageCodec.decode(Data(json.utf8)) else {
                throw XCTSkip("expected hello")
            }
            return hello
        }
        let stale = try hello(build: "Jul 12 2026 22:14:03")
        let current = try hello(build: "Jul 30 2026 01:02:58")

        XCTAssertEqual(stale.version, current.version,
                       "the premise: PRODUCT_VERSION is hand-edited and did "
                           + "not change between these two builds")
        XCTAssertEqual(stale.build, "Jul 12 2026 22:14:03")
        XCTAssertNotEqual(
            stale.build, current.build,
            "Two builds a fortnight apart must not report the same build "
                + "string. This is the misdiagnosis of 2026-07-30: a stale "
                + "guest on the 1400c failing every exec test looked "
                + "identical to a current one.")
    }

    func testCaptureOfferAnswersRoundTrip() throws {
        let offer = CaptureOffer(
            id: 7, width: 800, height: 600, depth: 8, rowBytes: 800,
            bytes: 99000, paletteBytes: 768, encoding: "packbits",
            captureMs: 130, encodeMs: 22)
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.captureOffer(offer))),
            .captureOffer(offer))
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(
                    .captureAccept(CaptureAccept(id: 7)))),
            .captureAccept(CaptureAccept(id: 7)))
        let refuse = CaptureRefuse(id: 7,
                                   reason: "busy: a transfer is in flight")
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.captureRefuse(refuse))),
            .captureRefuse(refuse))
    }

    func testDecodesGuestOfferJSONWithoutOptionals() throws {
        // The guest's snprintf always emits every field, but the contract
        // only requires the geometry - hold the decoder to the contract.
        let json = "{\"type\":\"capture.offer\",\"id\":3,"
            + "\"width\":640,\"height\":480,\"depth\":1,"
            + "\"rowBytes\":80,\"bytes\":38400}"
        guard case .captureOffer(let offer) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected capture.offer")
        }
        XCTAssertEqual(offer.id, 3)
        XCTAssertNil(offer.encoding)
    }

    func testStreamRequestRoundTrip() throws {
        let request = StreamRequest(depth: 8)
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.streamRequest(request))),
            .streamRequest(request))
    }

    func testStreamStartCarriesTheInitiatorsKnobs() throws {
        let start = StreamStart(id: 3, depth: 8, minIntervalMs: nil,
                                chunkKb: 32, paceMs: 0, pack: true,
                                predictive: true, interlace: true)
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.streamStart(start))),
            .streamStart(start))
        // A bare start (no tuning) stays legal - the guest falls back to
        // its own panel.
        let json = #"{"type":"stream.start","id":4,"depth":1}"#
        guard case .streamStart(let bare) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected stream.start")
        }
        XCTAssertNil(bare.pack)
    }

    func testStreamBracketRoundTrip() throws {
        let start = StreamStart(id: 11, depth: 8, minIntervalMs: 500)
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.streamStart(start))),
            .streamStart(start))
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.streamStop(StreamStop(id: 11)))),
            .streamStop(StreamStop(id: 11)))
        let stopped = StreamStopped(id: 11, reason: "capture failed")
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.streamStopped(stopped))),
            .streamStopped(stopped))
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

    func testByeRoundTripAndWireCodes() throws {
        let bye = Bye(code: .shuttingDown, reason: "host quitting")
        let data = try ControlMessageCodec.encode(.bye(bye))
        XCTAssertTrue(String(data: data, encoding: .utf8)!
            .contains("\"shutting-down\""))
        XCTAssertEqual(try ControlMessageCodec.decode(data), .bye(bye))
        let bare = Data("{\"type\":\"bye\",\"code\":\"normal\"}".utf8)
        XCTAssertEqual(try ControlMessageCodec.decode(bare),
                       .bye(Bye(code: .normal, reason: nil)))
    }

    func testProcessFamilyRoundTrip() throws {
        let request = ProcessList(id: 12, cursor: 17)
        let listing = ProcessListing(
            id: 12,
            processes: [
                ProcessEntry(name: "NOW", kind: "application", code: "APPL",
                             creator: "NwWs", sizeKB: 3072, front: true),
                ProcessEntry(name: "Finder", kind: "finder", code: "FNDR",
                             creator: "MACS", sizeKB: 2048, front: false),
            ],
            more: true, cursor: 3)
        for message: ControlMessage in [.processList(request),
                                        .processListing(listing)] {
            XCTAssertEqual(
                try ControlMessageCodec.decode(
                    ControlMessageCodec.encode(message)),
                message)
        }
    }

    func testProcessDriveVerbsRoundTrip() throws {
        let front = ProcessFront(id: 20, psnHigh: 0, psnLow: 16519)
        let quit = ProcessQuit(id: 21, psnHigh: 0, psnLow: 8386)
        let applied = ProcessResult(id: 20, ok: true, reason: nil)
        let refused = ProcessResult(
            id: 21, ok: false, reason: "that process is no longer running")
        let shot = ProcessShot(id: 22, psnHigh: 0, psnLow: 16519, depth: 8)
        for message: ControlMessage in [.processFront(front),
                                        .processQuit(quit),
                                        .processShot(shot),
                                        .processResult(applied),
                                        .processResult(refused)] {
            XCTAssertEqual(
                try ControlMessageCodec.decode(
                    ControlMessageCodec.encode(message)),
                message)
        }
    }

    func testProcessShotWithoutDepthDecodes() throws {
        // Depth is optional; omitted means the guest's own preference.
        let json = #"{"type":"process.shot","id":5,"psnHigh":0,"psnLow":42}"#
        guard case .processShot(let shot) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected process.shot")
        }
        XCTAssertNil(shot.depth)
        XCTAssertEqual(shot.psnLow, 42)
    }

    func testProcessListingWithoutPSNStillDecodes() throws {
        // A guest built before the drive verbs sends no PSN; the entry
        // still decodes, and simply is not drivable.
        let json = """
        {"type":"process.listing","id":1,"processes":[\
        {"name":"Finder","kind":"finder"}],"more":false}
        """
        guard case .processListing(let listing) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected process.listing")
        }
        XCTAssertFalse(listing.processes[0].isDrivable)
    }

    func testProcessListWithoutCursorDecodes() throws {
        // The first ask carries no cursor; the guest starts at 1.
        let json = #"{"type":"process.list","id":1}"#
        guard case .processList(let request) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("expected process.list")
        }
        XCTAssertNil(request.cursor)
        XCTAssertEqual(request.id, 1)
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

    func testCensusExchangeRoundTrip() throws {
        let request = CensusRequest(id: 3, probe: "gestalt", cursor: 16)
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.censusRequest(request))),
            .censusRequest(request))

        let report = CensusReport(
            id: 3, probe: "gestalt", outcome: "partial",
            rows: [["SystemVersion", "$00000921", "version 9.2.1"]],
            more: true, cursor: 16, total: 203, note: "one page of many")
        XCTAssertEqual(
            try ControlMessageCodec.decode(
                ControlMessageCodec.encode(.censusReport(report))),
            .censusReport(report))
    }
}
