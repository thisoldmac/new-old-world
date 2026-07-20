import Combine
import Network
import XCTest
@testable import Host

@MainActor
final class FileWireTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    func testListingPagesThroughTheShare() async throws {
        let guest = try await connectedGuest()
        var pages: [FileListing] = []

        listener.listFiles(path: "") { result in
            if case .success(let listing) = result { pages.append(listing) }
        }
        var listId: Int?
        try await waitUntil("file.list") {
            for message in guest.received {
                if case .fileList(let list) = message {
                    listId = list.id
                    return list.path == ""
                }
            }
            return false
        }
        let id = try XCTUnwrap(listId)
        try guest.send(.fileListing(FileListing(
            id: id, path: "",
            entries: [
                FileEntry(name: "Lab", kind: "folder", fileType: nil,
                          creator: nil, dataBytes: nil, rsrcBytes: nil,
                          modified: 3_400_000_000),
                FileEntry(name: "Read Me", kind: "file", fileType: "TEXT",
                          creator: "ttxt", dataBytes: 1200, rsrcBytes: 0,
                          modified: 3_400_000_100),
            ],
            more: true, cursor: 3)))

        try await waitUntil("listing") { pages.count == 1 }
        XCTAssertEqual(pages[0].entries.count, 2)
        XCTAssertTrue(pages[0].entries[0].isFolder)
        XCTAssertEqual(pages[0].entries[1].fileType, "TEXT")
        XCTAssertTrue(pages[0].more)
        XCTAssertEqual(pages[0].cursor, 3)
    }

    func testRefusalFailsTheListing() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.listFiles(path: "Nope") { result in
            if case .failure(let f) = result { failure = f }
        }
        var listId: Int?
        try await waitUntil("file.list") {
            for message in guest.received {
                if case .fileList(let list) = message {
                    listId = list.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileRefuse(FileRefuse(
            id: try XCTUnwrap(listId), code: "not-found",
            reason: "no such folder in the share")))
        try await waitUntil("refusal") { failure != nil }
        XCTAssertEqual(failure?.code, "not-found")
    }

    func testPullDeliversBytesAndClearsProgress() async throws {
        let guest = try await connectedGuest()
        var delivered: GuestListener.FileDelivery?
        listener.getFile(path: "Read Me") { result in
            if case .success(let file) = result { delivered = file }
        }
        var getId: Int?
        try await waitUntil("file.get") {
            for message in guest.received {
                if case .fileGet(let get) = message {
                    getId = get.id
                    return get.path == "Read Me"
                }
            }
            return false
        }
        let id = try XCTUnwrap(getId)
        // Classic text: MacRoman bytes with CR line endings.
        let payload = Data("First\rSecond\r".utf8)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 7, name: "Read Me", container: "data",
            bytes: payload.count, dataBytes: payload.count, rsrcBytes: 0,
            fileType: "TEXT", creator: "ttxt", modified: 3_400_000_100)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 7, payload: payload))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 7, ok: true,
                                        sendMs: 12)))

        try await waitUntil("delivery") { delivered != nil }
        let file = try XCTUnwrap(delivered)
        XCTAssertEqual(file.name, "Read Me")
        XCTAssertEqual(file.container, "data")
        XCTAssertEqual(file.bytes, payload)
        XCTAssertNil(listener.captureProgress,
                     "progress must clear when the file lands")
    }

    func testPutOffersWaitsForAcceptThenStreamsAndSettlesOnDone()
        async throws {
        let guest = try await connectedGuest()
        var settled: Result<Void, GuestListener.FileFailure>?
        let payload = Data("hello from the modern side\n".utf8)

        listener.putFile(name: "Notes", into: "Code", container: "data",
                         bytes: payload, fileType: "TEXT",
                         creator: "ttxt") { settled = $0 }

        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return offer.name == "Notes" && offer.path == "Code"
                        && offer.bytes == payload.count
                }
            }
            return false
        }
        let id = try XCTUnwrap(offerId)

        // The bytes must NOT move before the guest accepts: a refusal
        // has to cost only the message.
        XCTAssertFalse(guest.received.contains {
            if case .fileBegin = $0 { return true }
            return false
        }, "begin arrived before accept")

        try guest.send(.fileAccept(FileAccept(id: id)))
        try await waitUntil("file.begin") {
            guest.received.contains {
                if case .fileBegin(let begin) = $0 {
                    return begin.id == id && begin.bytes == payload.count
                }
                return false
            }
        }
        try await waitUntil("bulk + end") {
            guest.bulkReceived == payload
                && guest.received.contains {
                    if case .fileEnd(let end) = $0 { return end.ok }
                    return false
                }
        }

        // Not finished until the guest says the file is written.
        XCTAssertNil(settled)
        try guest.send(.fileDone(FileDone(id: id, ok: true, code: nil,
                                          reason: nil)))
        try await waitUntil("settled") { settled != nil }
        guard case .success = try XCTUnwrap(settled) else {
            return XCTFail("expected success")
        }
    }

    func testCancellingAStalledPutSettlesWithoutTheWire() async throws {
        // The guest accepts and then says nothing — the case that hung on
        // metal. Cancel must settle locally, because the send that would
        // notice it is the one not completing.
        let guest = try await connectedGuest()
        var settled: Result<Void, GuestListener.FileFailure>?
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 9, count: 200_000)) {
            settled = $0
        }
        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileAccept(FileAccept(id: try XCTUnwrap(offerId))))
        try await waitUntil("bytes moving") { guest.bulkReceived.count > 0 }

        listener.cancelFile()
        try await waitUntil("settled") { settled != nil }
        guard case .failure(let failure) = try XCTUnwrap(settled) else {
            return XCTFail("expected a cancellation")
        }
        XCTAssertEqual(failure.code, "cancelled")
        XCTAssertNil(listener.captureProgress)
    }

    func testAPushIsNotKeptAliveByTheGuestsHeartbeat() async throws {
        // A guest can answer pings perfectly while the transfer it is
        // receiving has stalled; those pings must not reset the push's
        // watchdog.
        let guest = try await connectedGuest()
        var settled: Result<Void, GuestListener.FileFailure>?
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data(repeating: 9, count: 64)) { settled = $0 }
        try await waitUntil("file.offer") {
            guest.received.contains {
                if case .fileOffer = $0 { return true }
                return false
            }
        }
        // Chatter, but no answer to the offer.
        try guest.send(.ping(id: 1))
        try guest.send(.ping(id: 2))
        listener.expireWatchdogsForTesting()
        try await waitUntil("timed out") { settled != nil }
        guard case .failure(let failure) = try XCTUnwrap(settled) else {
            return XCTFail("expected a timeout")
        }
        XCTAssertEqual(failure.code, "timeout")
    }

    func testPutRefusedByNameCollisionSettlesWithExists() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.putFile(name: "Notes", into: "", container: "data",
                         bytes: Data([1, 2, 3])) { result in
            if case .failure(let f) = result { failure = f }
        }
        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileRefuse(FileRefuse(
            id: try XCTUnwrap(offerId), code: "exists",
            reason: "a file of that name is already there")))
        try await waitUntil("refusal") { failure != nil }
        XCTAssertEqual(failure?.code, "exists")
    }

    func testPutThatTheGuestCouldNotWriteFailsWithItsReason() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: Data([1, 2, 3])) { result in
            if case .failure(let f) = result { failure = f }
        }
        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(offerId)
        try guest.send(.fileAccept(FileAccept(id: id)))
        try await waitUntil("bulk sent") { guest.bulkReceived.count == 3 }
        try guest.send(.fileDone(FileDone(
            id: id, ok: false, code: "io-error",
            reason: "the disk is full")))
        try await waitUntil("failure") { failure != nil }
        XCTAssertEqual(failure?.code, "io-error")
        XCTAssertEqual(failure?.message, "the disk is full")
    }

    func testTruncatedPullIsRejected() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.getFile(path: "Big") { result in
            if case .failure(let f) = result { failure = f }
        }
        var getId: Int?
        try await waitUntil("file.get") {
            for message in guest.received {
                if case .fileGet(let get) = message {
                    getId = get.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(getId)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 9, name: "Big", container: "data",
            bytes: 1000, dataBytes: 1000, rsrcBytes: 0, fileType: "BINA",
            creator: "????", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 9,
            payload: Data(repeating: 0, count: 10)))
        try guest.send(.fileEnd(FileEnd(id: id, transfer: 9, ok: true,
                                        sendMs: 1)))
        try await waitUntil("truncation refused") { failure != nil }
        XCTAssertTrue(failure?.message.contains("truncated") == true)
    }
}

@MainActor
final class TransferQueueTests: XCTestCase {
    private var listener: GuestListener!
    private var model: FilesModuleModel!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "files.test.\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        model = nil
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A guest that connects and then says nothing, so the first
    /// transfer stays in flight and the rest of a drop has to wait.
    private func silentGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        model.connection = .connected(name: "PowerBook 1400")
        return guest
    }

    private func tempFiles(_ names: [String]) throws -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return try names.map { name in
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
    }

    func testADropOfSeveralFilesSendsOneAndQueuesTheRest() async throws {
        let guest = try await silentGuest()
        model.enqueue(try tempFiles(["a.txt", "b.txt", "c.txt"]))

        try await waitUntil("first offer") {
            guest.received.contains {
                if case .fileOffer(let offer) = $0 {
                    return offer.name == "a.txt"
                }
                return false
            }
        }
        XCTAssertEqual(model.queue.map(\.lastPathComponent),
                       ["b.txt", "c.txt"], "the rest wait their turn")
        XCTAssertEqual(model.transfer?.index, 1)
        XCTAssertEqual(model.transfer?.total, 3)

        // Only one offer may be outstanding: the wire has one lane.
        let offers = guest.received.filter {
            if case .fileOffer = $0 { return true }
            return false
        }
        XCTAssertEqual(offers.count, 1)
    }

    func testTheQueueAdvancesWhenAFileLands() async throws {
        let guest = try await silentGuest()
        model.enqueue(try tempFiles(["a.txt", "b.txt"]))
        var firstId: Int?
        try await waitUntil("first offer") {
            for m in guest.received {
                if case .fileOffer(let offer) = m, offer.name == "a.txt" {
                    firstId = offer.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(firstId)
        try guest.send(.fileAccept(FileAccept(id: id)))
        try guest.send(.fileDone(FileDone(id: id, ok: true, code: nil,
                                          reason: nil)))
        try await waitUntil("second offer") {
            guest.received.contains {
                if case .fileOffer(let offer) = $0 {
                    return offer.name == "b.txt"
                }
                return false
            }
        }
        XCTAssertTrue(model.queue.isEmpty)
    }

    func testADeadWireStopsTheQueueInsteadOfFailingEveryFile()
        async throws {
        let guest = try await silentGuest()
        model.enqueue(try tempFiles(["a.txt", "b.txt", "c.txt", "d.txt"]))
        try await waitUntil("first offer") {
            guest.received.contains {
                if case .fileOffer = $0 { return true }
                return false
            }
        }
        listener.stop()                    // the wire goes away
        try await waitUntil("queue stopped") { self.model.queue.isEmpty }
        XCTAssertNil(model.transfer)
        XCTAssertTrue(model.lastError?.contains("not sent") == true,
                      "the human should be told how many did not go")
    }

    func testDroppingOnAFolderRowRetargetsTheDestination() async throws {
        _ = try await silentGuest()
        XCTAssertEqual(model.path, "")
        model.enqueue(try tempFiles(["a.txt"]), into: "Code:TBT")
        XCTAssertEqual(model.path, "Code:TBT")
    }
}

final class OutboundFileTests: XCTestCase {
    func testHFSNamesFitThirtyOneCharactersKeepingTheExtension() {
        let long = String(repeating: "a", count: 40) + ".txt"
        let out = OutboundFile.hfsName(long)
        XCTAssertLessThanOrEqual(out.utf8.count, 31)
        XCTAssertTrue(out.hasSuffix(".txt"), "extension must survive")
    }

    func testColonsAndLeadingDotsAreReplaced() {
        // ":" is HFS's path separator; a leading dot hides the file.
        XCTAssertEqual(OutboundFile.hfsName("a:b.txt"), "a-b.txt")
        XCTAssertEqual(OutboundFile.hfsName(".hidden"), "_hidden")
    }

    func testUnmappableCharactersBecomeUnderscores() {
        // Emoji have no MacRoman representation.
        let out = OutboundFile.hfsName("hello👋.txt")
        XCTAssertEqual(out, "hello_.txt")
        XCTAssertNotNil(out.data(using: .macOSRoman))
    }

    func testTextIsConvertedAndTyped() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let plan = OutboundFile.plan(url: url,
                                     data: Data("a\nb\n".utf8),
                                     convertText: true)
        XCTAssertEqual(plan.container, "data")
        XCTAssertEqual(plan.fileType, "TEXT")
        XCTAssertEqual(plan.creator, "ttxt")
        XCTAssertEqual(plan.bytes, Data([0x61, 0x0D, 0x62, 0x0D]))
        XCTAssertNotNil(plan.note)
    }

    func testTextConversionCanBeSwitchedOff() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let raw = Data("a\nb\n".utf8)
        let plan = OutboundFile.plan(url: url, data: raw,
                                     convertText: false)
        XCTAssertEqual(plan.bytes, raw, "bytes must be untouched")
    }

    func testMacBinaryTravelsWholeAndShedsItsExtension() {
        var header = [UInt8](repeating: 0, count: 128)
        header[1] = 5            // name length
        header[122] = 129        // MacBinary II
        let data = Data(header) + Data(repeating: 7, count: 128)
        let plan = OutboundFile.plan(
            url: URL(fileURLWithPath: "/tmp/SimpleText.bin"),
            data: data, convertText: true)
        XCTAssertEqual(plan.container, "macbinary")
        XCTAssertEqual(plan.name, "SimpleText")
        XCTAssertEqual(plan.bytes, data)
    }

    func testAFileMerelyNamedBinIsNotTreatedAsMacBinary() {
        let plan = OutboundFile.plan(
            url: URL(fileURLWithPath: "/tmp/firmware.bin"),
            data: Data(repeating: 0xFF, count: 400), convertText: true)
        XCTAssertEqual(plan.container, "data")
        XCTAssertEqual(plan.name, "firmware.bin")
    }

    func testUnknownExtensionsClaimNoType() {
        let plan = OutboundFile.plan(
            url: URL(fileURLWithPath: "/tmp/thing.wibble"),
            data: Data([1, 2, 3]), convertText: true)
        XCTAssertNil(plan.fileType)
        XCTAssertNil(plan.creator)
    }
}

final class FileConverterTests: XCTestCase {
    func testClassicTextBecomesUTF8WithUnixEndings() {
        // "café" in MacRoman: é is 0x8E.
        let bytes = Data([0x63, 0x61, 0x66, 0x8E, 0x0D, 0x6F, 0x6B, 0x0D])
        let out = FileConverter.convert(name: "Read Me", container: "data",
                                        fileType: "TEXT", bytes: bytes)
        XCTAssertEqual(String(data: out.data, encoding: .utf8), "café\nok\n")
        XCTAssertNotNil(out.note)
    }

    func testBinaryFilesArePassedThroughUntouched() {
        let bytes = Data([0x00, 0x0D, 0xFF, 0x0D])
        let out = FileConverter.convert(name: "thing.dat", container: "data",
                                        fileType: "BINA", bytes: bytes)
        XCTAssertEqual(out.data, bytes)
        XCTAssertNil(out.note)
    }

    func testMacBinaryKeepsItsBytesAndGainsTheExtension() {
        let bytes = Data(repeating: 7, count: 128)
        let out = FileConverter.convert(name: "SimpleText",
                                        container: "macbinary",
                                        fileType: "APPL", bytes: bytes)
        XCTAssertEqual(out.data, bytes)
        XCTAssertEqual(out.name, "SimpleText.bin")
    }

    func testTextDetectionUsesTypeThenExtension() {
        XCTAssertTrue(FileConverter.isText(fileType: "TEXT", name: "x"))
        XCTAssertTrue(FileConverter.isText(fileType: nil, name: "notes.md"))
        XCTAssertFalse(FileConverter.isText(fileType: "PICT",
                                            name: "shot.pict"))
    }

    func testRoundTripToClassicRestoresCR() {
        let classic = FileConverter.toClassicText("a\nb\r\nc")
        XCTAssertEqual(classic, Data([0x61, 0x0D, 0x62, 0x0D, 0x63]))
    }

    func testUnmappableCharactersAreSubstitutedNotDropped() {
        let classic = FileConverter.toClassicText("a→b")
        XCTAssertEqual(classic.count, 3)
        XCTAssertEqual(classic.first, UInt8(ascii: "a"))
        XCTAssertEqual(classic.last, UInt8(ascii: "b"))
    }

    func testClassicEpochConverts() throws {
        // 1904-01-01 + 3_400_000_000s lands in 2011.
        let date = try XCTUnwrap(ClassicDate.date(from: 3_400_000_000))
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: date)
        XCTAssertEqual(year, 2011)
        XCTAssertNil(ClassicDate.date(from: 0))
    }
}
