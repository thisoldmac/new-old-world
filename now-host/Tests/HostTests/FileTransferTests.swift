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

    func testMoveCarriesTheWholeDestination() async throws {
        let guest = try await connectedGuest()
        var answer: FileResult?

        listener.moveFile(from: "Lab:Notes", to: "Lab:Old Notes") { result in
            if case .success(let r) = result { answer = r }
        }
        var moveId: Int?
        try await waitUntil("file.move") {
            for message in guest.received {
                if case .fileMove(let move) = message {
                    moveId = move.id
                    // A rename is a move: one message, whole destination.
                    return move.path == "Lab:Notes"
                        && move.toPath == "Lab:Old Notes"
                }
            }
            return false
        }
        try guest.send(.fileResult(FileResult(
            id: try XCTUnwrap(moveId), ok: true, path: "Lab:Old Notes")))
        try await waitUntil("result") { answer != nil }
        XCTAssertEqual(answer?.path, "Lab:Old Notes")
    }

    func testTrashHandsBackTheNameItLandedUnder() async throws {
        let guest = try await connectedGuest()
        var answer: FileResult?

        listener.trashFile(path: "Lab:Notes") { result in
            if case .success(let r) = result { answer = r }
        }
        var trashId: Int?
        try await waitUntil("file.trash") {
            for message in guest.received {
                if case .fileTrash(let trash) = message {
                    trashId = trash.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileResult(FileResult(
            id: try XCTUnwrap(trashId), ok: true, path: "Lab:Notes",
            trashedAs: "Notes 2")))
        try await waitUntil("result") { answer != nil }
        XCTAssertEqual(answer?.trashedAs, "Notes 2")
    }

    /// Restore names both ends, so nothing is remembered on either side
    /// and an undo outlives a restart. When the Trash no longer holds the
    /// item the failure still has to reach the caller, so the history can
    /// drop an entry that will never work again.
    func testRestoreNamesBothEndsAndFailsHonestly() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?

        listener.restoreFile(trashedAs: "Notes 2", to: "Lab:Notes") { result in
            if case .failure(let f) = result { failure = f }
        }
        var restoreId: Int?
        try await waitUntil("file.restore") {
            for message in guest.received {
                if case .fileRestore(let restore) = message {
                    restoreId = restore.id
                    return restore.trashedAs == "Notes 2"
                        && restore.toPath == "Lab:Notes"
                }
            }
            return false
        }
        try guest.send(.fileResult(FileResult(
            id: try XCTUnwrap(restoreId), ok: false, path: nil,
            trashedAs: nil, code: "not-found",
            reason: "no such item — it may have been moved "
                + "or the Trash emptied")))
        try await waitUntil("failure") { failure != nil }
        XCTAssertEqual(failure?.code, "not-found")
    }

    /// An older guest answers an unknown message with file.refuse rather
    /// than file.result. That still has to settle the request.
    func testRefusalAlsoSettlesAChange() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?

        listener.makeFolder(path: "Lab:New") { result in
            if case .failure(let f) = result { failure = f }
        }
        var mkdirId: Int?
        try await waitUntil("file.mkdir") {
            for message in guest.received {
                if case .fileMkdir(let mkdir) = message {
                    mkdirId = mkdir.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileRefuse(FileRefuse(
            id: try XCTUnwrap(mkdirId), code: "exists",
            reason: "something is already there")))
        try await waitUntil("failure") { failure != nil }
        XCTAssertEqual(failure?.code, "exists")
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
        try await waitUntil("receiver progress") {
            guest.received.contains {
                if case .fileProgress(let progress) = $0 {
                    return progress.id == id
                        && progress.received == payload.count
                }
                return false
            }
        }
        let file = try XCTUnwrap(delivered)
        XCTAssertEqual(file.name, "Read Me")
        XCTAssertEqual(file.container, "data")
        XCTAssertEqual(try Data(contentsOf: file.staged.url), payload)
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

    func testAMeteredFrameArrivesAsExactlyTheSameBytes() async throws {
        // Pacing splits each 32 KB protocol frame across many TCP
        // writes. The guest reassembles a byte stream and must not be
        // able to tell — least of all at a frame boundary, where a
        // split that lost or duplicated bytes would desync its decoder
        // rather than merely corrupt a file.
        listener.stop()
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60),
            // A deliberately ugly size that divides neither the frame
            // payload nor the file, so pieces straddle both boundaries.
            pacing: .init(bytes: 97, gap: 0))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        let guest = try await connectedGuest()

        // Spans three 32 KB frames, and ends mid-frame.
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        var settled: Result<Void, GuestListener.FileFailure>?
        listener.putFile(name: "Metered", into: "", container: "data",
                         bytes: payload) { settled = $0 }

        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return offer.bytes == payload.count
                }
            }
            return false
        }
        let id = try XCTUnwrap(offerId)
        try guest.send(.fileAccept(FileAccept(id: id)))

        try await waitUntil("all bytes", timeout: 20) {
            guest.bulkReceived.count == payload.count
        }
        XCTAssertEqual(guest.bulkReceived, payload,
                       "metering must not alter the byte stream")
        try await waitUntil("file.end") {
            guest.received.contains {
                if case .fileEnd(let end) = $0 { return end.ok }
                return false
            }
        }
        try guest.send(.fileDone(FileDone(id: id, ok: true, code: nil,
                                          reason: nil)))
        try await waitUntil("settled") { settled != nil }
        guard case .success = try XCTUnwrap(settled) else {
            return XCTFail("expected success")
        }
    }

    func testProgressFollowsTheGuestNotOurOwnSendCounter() async throws {
        // The defect this replaces: progress came from the local send
        // completing, which only means macOS accepted the bytes. Over a
        // link this slow that reached 100% with a third of the file
        // actually delivered, and the watchdog was fed by the same
        // claim, so a stalled guest looked healthy.
        let guest = try await connectedGuest()
        let payload = Data(repeating: 7, count: 200_000)
        listener.putFile(name: "Big", into: "", container: "data",
                         bytes: payload) { _ in }

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

        // Locally the whole file goes out almost at once, so the send
        // counter races to the end.
        try await waitUntil("sent") { guest.bulkReceived == payload }
        try await waitUntil("send counter ran ahead") {
            self.listener.captureProgress?.received == payload.count
        }

        // The guest then says what it has really taken, and that is what
        // must be shown — even though it moves the bar backwards.
        try guest.send(.fileProgress(FileProgress(id: id, received: 32_768)))
        try await waitUntil("guest truth wins") {
            self.listener.captureProgress?.received == 32_768
        }
        XCTAssertEqual(listener.captureProgress?.expected, payload.count)

        // And it keeps winning: a later send completion must not push the
        // bar back up past what the guest has confirmed.
        try guest.send(.fileProgress(FileProgress(id: id, received: 65_536)))
        try await waitUntil("still following the guest") {
            self.listener.captureProgress?.received == 65_536
        }
    }

    func testAGuestThatNeverReportsProgressKeepsTheSendCounter()
        async throws {
        // An older guest sends no file.progress at all. It must not lose
        // its progress bar or, worse, have the watchdog starve and call a
        // healthy transfer dead: absence means an old guest, not a
        // stalled one.
        let guest = try await connectedGuest()
        let payload = Data(repeating: 3, count: 100_000)
        var settled: Result<Void, GuestListener.FileFailure>?
        listener.putFile(name: "Old", into: "", container: "data",
                         bytes: payload) { settled = $0 }

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

        try await waitUntil("progress still moves") {
            self.listener.captureProgress?.received == payload.count
        }
        try guest.send(.fileDone(FileDone(id: id, ok: true, code: nil,
                                          reason: nil)))
        try await waitUntil("settled") { settled != nil }
        guard case .success = try XCTUnwrap(settled) else {
            return XCTFail("expected success")
        }
    }

    func testProgressForAnotherPutIsIgnored() async throws {
        // Same correlation rule the done path already learned: a late
        // report from a transfer that has finished must not redraw the
        // bar for the one after it.
        let guest = try await connectedGuest()
        let payload = Data(repeating: 1, count: 50_000)
        listener.putFile(name: "Now", into: "", container: "data",
                         bytes: payload) { _ in }

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
        try await waitUntil("sent") { guest.bulkReceived == payload }

        try guest.send(.fileProgress(FileProgress(id: id + 99,
                                                  received: 1)))
        try guest.send(.fileProgress(FileProgress(id: id, received: 4_096)))
        try await waitUntil("only its own put counts") {
            self.listener.captureProgress?.received == 4_096
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

    func testLateAcceptAfterTimeoutCannotDisruptTheNextPut() async throws {
        let guest = try await connectedGuest()
        var first: Result<Void, GuestListener.FileFailure>?
        listener.putFile(
            name: "First", into: "", container: "data",
            bytes: Data([1])) { first = $0 }
        var firstID: Int?
        try await waitUntil("first file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message,
                   offer.name == "First" {
                    firstID = offer.id
                    return true
                }
            }
            return false
        }
        listener.expireWatchdogsForTesting()
        try await waitUntil("first timeout") { first != nil }

        var second: Result<Void, GuestListener.FileFailure>?
        listener.putFile(
            name: "Second", into: "", container: "data",
            bytes: Data([2])) { second = $0 }
        var secondID: Int?
        try await waitUntil("second file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message,
                   offer.name == "Second" {
                    secondID = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileAccept(FileAccept(id: try XCTUnwrap(firstID))))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(guest.received.contains {
            if case .fileBegin(let begin) = $0 {
                return begin.id == firstID
            }
            return false
        })
        XCTAssertNil(second)

        try guest.send(.fileAccept(FileAccept(id: try XCTUnwrap(secondID))))
        try await waitUntil("second bulk") {
            guest.bulkReceived == Data([2])
        }
        try guest.send(.fileDone(FileDone(
            id: try XCTUnwrap(secondID), ok: true)))
        try await waitUntil("second settled") { second != nil }
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
        try guest.send(.fileAccept(FileAccept(
            id: id,
            freeBytes: 4096,
            reservedBytes: 3,
            staging: "same-folder-temp")))
        try await waitUntil("bulk sent") { guest.bulkReceived.count == 3 }
        try guest.send(.fileDone(FileDone(
            id: id, ok: false, code: "io-error",
            reason: "the disk is full",
            received: 3,
            cleanup: "temp-removed")))
        try await waitUntil("failure") { failure != nil }
        XCTAssertEqual(failure?.code, "io-error")
        XCTAssertEqual(failure?.message, "the disk is full")
        XCTAssertEqual(failure?.putEvidence?.totalBytes, 3)
        XCTAssertEqual(
            failure?.putEvidence?.receiverConfirmedBytes, 3)
        XCTAssertEqual(failure?.putEvidence?.guestReservedBytes, 3)
        XCTAssertEqual(
            failure?.putEvidence?.guestCleanup, "temp-removed")
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

    func testPullWithTheWrongChecksumIsRejected() async throws {
        let guest = try await connectedGuest()
        var failure: GuestListener.FileFailure?
        listener.getFile(path: "Wrong") { result in
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
        let payload = Data("complete but corrupt".utf8)
        try guest.send(.fileBegin(FileBegin(
            id: id, transfer: 10, name: "Wrong", container: "data",
            bytes: payload.count, dataBytes: payload.count, rsrcBytes: 0,
            fileType: "BINA", creator: "????", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 10,
            payload: payload))
        try guest.send(.fileEnd(FileEnd(
            id: id, transfer: 10, ok: true, sendMs: 1,
            crc32: 0x1234_5678)))

        try await waitUntil("checksum refused") { failure != nil }
        XCTAssertTrue(failure?.message.contains("checksum") == true)
    }

    func testCancellingAPullDeletesItsSameFolderPartial() async throws {
        let guest = try await connectedGuest()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failure: GuestListener.FileFailure?

        listener.getFile(path: "Interrupted", stagingDirectory: directory) {
            result in
            if case .failure(let value) = result { failure = value }
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
            id: id, transfer: 11, name: "Interrupted", container: "data",
            bytes: 1_000_000, dataBytes: 1_000_000, rsrcBytes: 0,
            fileType: "BINA", creator: "????", modified: nil)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [], transfer: 11,
            payload: Data(repeating: 0xA5, count: 32 * 1024)))
        try await waitUntil("partial written") {
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: directory.path)) ?? []
            return names.contains { $0.hasSuffix(".part") }
        }

        listener.cancelFile()

        try await waitUntil("cancelled") { failure?.code == "cancelled" }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path),
            [])
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
        model.connection = .connected(named: "PowerBook 1400")
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
        XCTAssertEqual(model.queue.map { $0.url.lastPathComponent },
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

    func testDroppingOnAFolderRowTargetsThatFolder() async throws {
        let guest = try await silentGuest()
        model.enqueue(try tempFiles(["a.txt"]), into: "Code:TBT")
        try await waitUntil("offer") {
            guest.received.contains {
                if case .fileOffer(let offer) = $0 {
                    return offer.path == "Code:TBT"
                }
                return false
            }
        }
        // Dropping somewhere does not move the browser there.
        XCTAssertEqual(model.path, "")
    }

    /// Builds a small tree: Proj/{read me.txt, src/{main.c, deep/x.txt},
    /// empty/, .hidden}
    private func tempTree() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Proj")
        try fm.createDirectory(at: root.appendingPathComponent("src/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(
            to: root.appendingPathComponent("read me.txt"))
        try Data("x".utf8).write(
            to: root.appendingPathComponent("src/main.c"))
        try Data("x".utf8).write(
            to: root.appendingPathComponent("src/deep/x.txt"))
        try Data("x".utf8).write(
            to: root.appendingPathComponent(".hidden"))
        return root
    }

    func testADroppedFolderKeepsItsShape() async throws {
        _ = try await silentGuest()
        model.enqueue([try tempTree()])
        // One is in flight; the rest are queued. Check the whole plan.
        var folders = model.queue.map(\.folder)
        if let inFlight = model.transfer { _ = inFlight }
        folders.insert("Proj", at: 0)     // read me.txt goes first
        XCTAssertEqual(Set(folders),
                       Set(["Proj", "Proj:src", "Proj:src:deep"]),
                       "subfolders keep their position under the drop")
        XCTAssertFalse(model.queue.contains {
            $0.url.lastPathComponent == ".hidden"
        }, "hidden files are not worth sending to a classic Mac")
        XCTAssertFalse(model.queue.contains { $0.folder.contains("empty") },
                       "an empty folder carries nothing")
    }

    func testADroppedFolderLandsUnderTheTargetFolder() async throws {
        _ = try await silentGuest()
        model.enqueue([try tempTree()], into: "Code")
        var folders = model.queue.map(\.folder)
        folders.append("Code:Proj")       // the one already in flight
        XCTAssertTrue(folders.allSatisfy { $0.hasPrefix("Code:Proj") })
    }

    func testAnEnormousDropIsRefusedWithACount() async throws {
        _ = try await silentGuest()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Many")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0...FilesModuleModel.dropFileLimit {
            try Data("x".utf8).write(
                to: root.appendingPathComponent("f\(i).txt"))
        }
        model.enqueue([root])
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertTrue(model.lastError?.contains("limit") == true)
    }
}

final class OutboundFileTests: XCTestCase {

    /// This file system hands out decomposed names, and MacRoman has
    /// the accented letter but not the combining mark. Without
    /// composing first, every accented name arrives mangled.
    func testAccentedNamesSurviveDecomposition() {
        // As the file system yields it: e + combining acute.
        let decomposed = "cafe\u{301}.txt"
        let name = OutboundFile.hfsName(decomposed)
        XCTAssertEqual(name, "café.txt")
        XCTAssertNotNil(name.data(using: .macOSRoman),
                        "and it must still be storable over there")
        XCTAssertEqual(name.data(using: .macOSRoman)?.count, 8,
                       "one byte for the accented letter, not two")
    }

    /// The Apple logo is the character most likely to be lost, and it
    /// only exists in MacRoman.
    func testTheAppleLogoSurvives() {
        XCTAssertEqual(OutboundFile.hfsName("\u{F8FF} Notes"), "\u{F8FF} Notes")
    }

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

    /// Builds a MacBinary file the way a real encoder would, so the
    /// header's arithmetic and CRC hold.
    private func macBinary(name: String, dataFork: Int, rsrcFork: Int,
                           version: UInt8) -> Data {
        var h = [UInt8](repeating: 0, count: 128)
        let nb = Array(name.utf8.prefix(63))
        h[1] = UInt8(nb.count)
        for (i, byte) in nb.enumerated() { h[2 + i] = byte }
        h[65] = 0x41; h[66] = 0x50; h[67] = 0x50; h[68] = 0x4C   // APPL
        func put(_ value: Int, at i: Int) {
            h[i] = UInt8((value >> 24) & 0xFF)
            h[i + 1] = UInt8((value >> 16) & 0xFF)
            h[i + 2] = UInt8((value >> 8) & 0xFF)
            h[i + 3] = UInt8(value & 0xFF)
        }
        put(dataFork, at: 83)
        put(rsrcFork, at: 87)
        if version != 0 {
            h[122] = version
            h[123] = version
            var crc: UInt16 = 0
            for byte in h[0..<124] {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 {
                    crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
                }
            }
            h[124] = UInt8(crc >> 8)
            h[125] = UInt8(crc & 0xFF)
        }
        func pad(_ n: Int) -> Int { (n + 127) / 128 * 128 }
        return Data(h) + Data(repeating: 7, count: pad(dataFork))
            + Data(repeating: 9, count: pad(rsrcFork))
    }

    func testMacBinaryTravelsWholeAndShedsItsExtension() {
        let data = macBinary(name: "SimpleText", dataFork: 0,
                             rsrcFork: 2048, version: 129)
        let plan = OutboundFile.plan(
            url: URL(fileURLWithPath: "/tmp/SimpleText.bin"),
            data: data, convertText: true)
        XCTAssertEqual(plan.container, "macbinary")
        XCTAssertEqual(plan.name, "SimpleText")
        XCTAssertEqual(plan.bytes, data)
    }

    /// The case that failed on metal: archive sites serve MacBinary I,
    /// which has no version byte and no CRC. Requiring them sent real
    /// classic software across as plain data, arriving with no resource
    /// fork — a file the Mac could not open.
    func testMacBinaryOneIsRecognisedWithoutAVersionByte() {
        let data = macBinary(name: "Some App", dataFork: 300,
                             rsrcFork: 5000, version: 0)
        XCTAssertTrue(OutboundFile.looksLikeMacBinary(data))
        let plan = OutboundFile.plan(
            url: URL(fileURLWithPath: "/tmp/Some App.bin"),
            data: data, convertText: true)
        XCTAssertEqual(plan.container, "macbinary")
    }

    func testAHeaderThatDoesNotAccountForTheFileIsNotMacBinary() {
        // Right shape, wrong arithmetic: forks claim far more than the
        // file holds.
        var data = macBinary(name: "Liar", dataFork: 10, rsrcFork: 10,
                             version: 0)
        data = data.prefix(200)
        XCTAssertFalse(OutboundFile.looksLikeMacBinary(data))
    }

    func testACorruptedVersionTwoHeaderIsRejectedByItsCRC() {
        var data = macBinary(name: "Broken", dataFork: 0, rsrcFork: 128,
                             version: 129)
        data[70] = 0xFF                 // creator changed, CRC now stale
        XCTAssertFalse(OutboundFile.looksLikeMacBinary(data))
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

    func testDatesRoundTripThroughTheClassicEpoch() throws {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let mac = try XCTUnwrap(ClassicDate.macSeconds(from: now))
        let back = try XCTUnwrap(ClassicDate.date(from: mac))
        XCTAssertEqual(back.timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 1)
    }

    func testDatesOutsideTheClassicEpochAreRefusedNotWrapped() {
        // 1900: before the Mac epoch, so there is no honest answer.
        XCTAssertNil(ClassicDate.macSeconds(
            from: Date(timeIntervalSince1970: -2_208_988_800)))
        // Far future: past what the classic field can hold.
        XCTAssertNil(ClassicDate.macSeconds(
            from: Date(timeIntervalSince1970: 9_000_000_000)))
    }

    func testGuestWireDatesRefuseValuesItsSignedParserCannotRepresent() {
        let modern = Date(timeIntervalSince1970: 1_784_000_000)
        XCTAssertNotNil(ClassicDate.macSeconds(from: modern))
        XCTAssertNil(ClassicDate.guestWireSeconds(from: modern))

        let representable = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            ClassicDate.guestWireSeconds(from: representable),
            ClassicDate.macSeconds(from: representable))
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
