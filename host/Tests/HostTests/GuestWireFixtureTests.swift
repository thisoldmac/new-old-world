import Foundation
import XCTest
@testable import Host

/// The exact bytes the guest puts on the wire, decoded by the host.
///
/// Every other test in this suite builds messages as Swift values, which
/// proves the host agrees with itself and nothing more. Two frames the
/// guest sends were missing contract-required fields and no test noticed:
/// the host could not decode them, dropped the connection, and the
/// symptom was "the send does nothing".
///
/// The strings below are copied from the snprintf calls in
/// guest/src/wire.c. When one changes there, it changes here, and that
/// is the point: this is the only place the two halves are compared.
///
/// There are two guests now, and their emitters do not resemble each
/// other. The PowerPC Carbon client (`guest/src`) writes messages with
/// snprintf; NOW-68K (`guest68k/src`) has no printf family at all — the
/// float tail newlib drags in costs ~42 KB of a 384 KB partition — so it
/// appends literals and hand-formatted integers through `numfmt.c`.
/// Every fixture below is named for the guest it was derived from:
/// `…AsTheGuestWritesIt` is the PowerPC client, `test68K…` is NOW-68K.
final class GuestWireFixtureTests: XCTestCase {
    private func decode(_ json: String,
                        file: StaticString = #filePath,
                        line: UInt = #line) throws -> ControlMessage {
        do {
            return try ControlMessageCodec.decode(Data(json.utf8))
        } catch {
            XCTFail("the host cannot decode what the guest sends: \(error)",
                    file: file, line: line)
            throw error
        }
    }

    /// now_wire_send_file(): the guest offering a file to the host.
    func testFileOfferAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.offer","id":1,"name":"Notes","path":"",\
        "container":"data","bytes":66,"fileType":"TEXT",\
        "creator":"ttxt","modified":3300000000}
        """
        guard case .fileOffer(let offer) = try decode(json) else {
            return XCTFail("not an offer")
        }
        XCTAssertEqual(offer.name, "Notes")
        XCTAssertEqual(offer.path, "", "the root of this Mac's share")
        XCTAssertEqual(offer.bytes, 66)
        XCTAssertEqual(offer.container, "data")
    }

    /// send_offer(true): the same offer again after a person said to
    /// replace. Only the overwrite flag differs, and the conformance
    /// check cannot see this variant - it instantiates the optional
    /// fragment as absent, which is the other branch.
    func testFileOfferWithOverwriteAsTheGuestWritesIt() throws {
        let json = #"{"type":"file.offer","id":1,"name":"Notes","path":"","#
            + #""container":"data","bytes":66,"fileType":"TEXT","#
            + #""creator":"ttxt","modified":3300000000,"overwrite":true}"#
        guard case .fileOffer(let offer) = try decode(json) else {
            return XCTFail("not an offer")
        }
        XCTAssertEqual(offer.overwrite, true)
        XCTAssertEqual(offer.name, "Notes", "the same file, asked again")
    }

    /// send_accepted(): the guest announcing the transfer that follows.
    func testFileBeginAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.begin","id":1,"transfer":3,"name":"Notes",\
        "container":"data","bytes":66}
        """
        guard case .fileBegin(let begin) = try decode(json) else {
            return XCTFail("not a begin")
        }
        XCTAssertEqual(begin.transfer, 3)
        XCTAssertEqual(begin.name, "Notes")
        XCTAssertEqual(begin.bytes, 66)
    }

    /// xfer_finish(): how any transfer from the guest ends.
    func testFileEndAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.end","id":1,"transfer":3,"ok":true,"sendMs":412,\
        "crc32":305419896}
        """
        guard case .fileEnd(let end) = try decode(json) else {
            return XCTFail("not an end")
        }
        XCTAssertTrue(end.ok)
        XCTAssertEqual(end.crc32, 0x1234_5678)
    }

    /// serve_file_list(): a listing, with the share label the browser
    /// puts in the breadcrumb.
    func testFileListingAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.listing","id":2,"path":"","entries":[\
        {"name":"Docs","kind":"folder","modified":3300000000,\
        "identity":"0123456789abcdef"},\
        {"name":"Notes","kind":"file","fileType":"TEXT","creator":"ttxt",\
        "dataBytes":66,"rsrcBytes":0,"modified":3300000000,\
        "identity":"fedcba9876543210"}],\
        "more":false,"cursor":3,"root":"Macintosh HD:Lab:"}
        """
        guard case .fileListing(let listing) = try decode(json) else {
            return XCTFail("not a listing")
        }
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries.first?.isFolder, true)
        XCTAssertEqual(listing.entries.first?.identity,
                       "0123456789abcdef")
        XCTAssertEqual(listing.root, "Macintosh HD:Lab:")
    }

    func testGuestReservationAndFinalizationEvidenceDecodes() throws {
        guard case .fileAccept(let accept) = try decode(
            #"{"type":"file.accept","id":5,"freeBytes":5000000,"reservedBytes":4096,"staging":"same-folder-temp"}"#
        ) else {
            return XCTFail("not an accept")
        }
        XCTAssertEqual(accept.freeBytes, 5_000_000)
        XCTAssertEqual(accept.reservedBytes, 4_096)
        XCTAssertEqual(accept.staging, "same-folder-temp")

        guard case .fileDone(let done) = try decode(
            #"{"type":"file.done","id":5,"ok":true,"received":4096,"crc32":305419896,"finalization":"same-folder-rename","cleanup":"temp-renamed"}"#
        ) else {
            return XCTFail("not done")
        }
        XCTAssertEqual(done.received, 4_096)
        XCTAssertEqual(done.crc32, 0x12345678)
        XCTAssertEqual(done.finalization, "same-folder-rename")
        XCTAssertEqual(done.cleanup, "temp-renamed")
    }

    /// A listing without the root, which is what a subfolder gets and
    /// what a guest built before the label existed sends.
    func testAListingWithoutARootStillDecodes() throws {
        let json = """
        {"type":"file.listing","id":2,"path":"Docs","entries":[],\
        "more":false,"cursor":1}
        """
        guard case .fileListing(let listing) = try decode(json) else {
            return XCTFail("not a listing")
        }
        XCTAssertNil(listing.root)
    }

    /// file_refuse(): every guest-side failure takes this shape.
    func testFileRefuseAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.refuse","id":4,"code":"busy",\
        "reason":"a transfer is already in flight"}
        """
        guard case .fileRefuse(let refuse) = try decode(json) else {
            return XCTFail("not a refusal")
        }
        XCTAssertEqual(refuse.code, "busy")
    }

    /// finish_put(): the guest's receipt for a file the host sent.
    func testFileDoneAsTheGuestWritesIt() throws {
        for json in [
            #"{"type":"file.done","id":5,"ok":true}"#,
            #"{"type":"file.done","id":5,"ok":false,"code":"io-error","#
                + #""reason":"the File Manager refused (-48)"}"#,
        ] {
            guard case .fileDone = try decode(json) else {
                return XCTFail("not a receipt")
            }
        }
    }

    /// file_result_ok() / file_result_fail(): the answer to every
    /// change operation. Assembled across calls, so the conformance
    /// check cannot reach it and these stand in — the success shape has
    /// an optional trashedAs that the host's undo depends on.
    func testFileResultAsTheGuestWritesIt() throws {
        let moved = #"{"type":"file.result","id":6,"ok":true,"path":"Docs:Notes"}"#
        guard case .fileResult(let ok) = try decode(moved) else {
            return XCTFail("not a result")
        }
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.path, "Docs:Notes")

        let trashed = #"{"type":"file.result","id":7,"ok":true,"path":"","#
            + #""trashedAs":"Notes 2"}"#
        guard case .fileResult(let binned) = try decode(trashed) else {
            return XCTFail("not a result")
        }
        XCTAssertEqual(binned.trashedAs, "Notes 2",
                       "the name an undo has to put back")

        let failed = #"{"type":"file.result","id":8,"ok":false,"#
            + #""code":"io-error","#
            + #""reason":"the File Manager refused (File Manager error -48)"}"#
        guard case .fileResult(let bad) = try decode(failed) else {
            return XCTFail("not a result")
        }
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.code, "io-error")
    }

    /// serve_process_list(): the guest's running processes, assembled
    /// across a header / per-entry / tail set of snprintf calls, so the
    /// conformance check cannot reach it. The three kinds and the
    /// front flag are what the host's Processes mirror reads.
    func testProcessListingAsTheGuestWritesIt() throws {
        let json = """
        {"type":"process.listing","id":9,"processes":[\
        {"name":"Finder","kind":"finder","code":"FNDR","creator":"MACS",\
        "sizeKB":2048,"front":false,"psnHigh":0,"psnLow":8386},\
        {"name":"NOW","kind":"application","code":"APPL","creator":"NwWs",\
        "sizeKB":3072,"front":true,"psnHigh":0,"psnLow":16519},\
        {"name":"File Sharing Extension","kind":"background","code":"appe",\
        "creator":"fsee","sizeKB":512,"front":false,"psnHigh":0,\
        "psnLow":24601}],\
        "more":false,"cursor":4}
        """
        guard case .processListing(let listing) = try decode(json) else {
            return XCTFail("not a process listing")
        }
        XCTAssertEqual(listing.processes.count, 3)
        XCTAssertEqual(listing.processes.first?.kind, "finder")
        XCTAssertEqual(listing.processes[1].front, true, "NOW is front")
        XCTAssertTrue(listing.processes[2].isBackground)
        XCTAssertFalse(listing.more)
        // The PSN is what the drive verbs echo back to name a process.
        XCTAssertEqual(listing.processes[1].psnLow, 16519)
        XCTAssertTrue(listing.processes[1].isDrivable)
    }

    /// serve_software_list(): the guest's installed software, assembled
    /// across header / per-entry / tail snprintf calls like the process
    /// listing. The ® in the name pins the MacRoman-high-byte escape
    /// path (0xA8 -> ®), and the off+running pair pins the two
    /// state booleans the Software page will render.
    func testSoftwareListingAsTheGuestWritesIt() throws {
        let json = """
        {"type":"software.listing","id":11,"domain":"apps","entries":[\
        {"name":"Adobe Illustrator\\u00AE 8.0",\
        "path":"Macintosh HD:Applications:Adobe Illustrator\\u00AE 8.0",\
        "type":"APPL","creator":"ART5","sizeK":3072,"off":false,\
        "running":false},\
        {"name":"SimpleText","path":"Macintosh HD:SimpleText",\
        "type":"APPL","creator":"ttxt","sizeK":92,"off":false,\
        "running":true,"version":"1.4"}],\
        "more":true,"cursor":3}
        """
        guard case .softwareListing(let listing) = try decode(json) else {
            return XCTFail("not a software listing")
        }
        XCTAssertEqual(listing.domain, "apps")
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries.first?.name,
                       "Adobe Illustrator\u{00AE} 8.0")
        XCTAssertEqual(listing.entries[1].running, true)
        XCTAssertTrue(listing.entries[1].isLaunchable)
        // Version is optional per entry: present when the guest read a
        // 'vers', absent (nil) when the file has none.
        XCTAssertEqual(listing.entries[1].version, "1.4")
        XCTAssertNil(listing.entries.first?.version)
        XCTAssertTrue(listing.more)
        XCTAssertEqual(listing.cursor, 3)
    }

    /// serve_software_list() refusing a domain, and marking a truncated
    /// inventory: the two honest edges ride the same note field, and an
    /// empty path must decode as listed-but-not-launchable.
    func testSoftwareListingEdgesAsTheGuestWritesThem() throws {
        let refused = """
        {"type":"software.listing","id":12,"domain":"games",\
        "entries":[],"more":false,"note":"no such domain"}
        """
        guard case .softwareListing(let empty) = try decode(refused) else {
            return XCTFail("not a software listing")
        }
        XCTAssertEqual(empty.note, "no such domain")
        XCTAssertTrue(empty.entries.isEmpty)

        let truncated = """
        {"type":"software.listing","id":13,"domain":"extensions",\
        "entries":[{"name":"Deep Thing","path":"","type":"INIT",\
        "creator":"deep","sizeK":12,"off":true,"running":false}],\
        "more":false,"cursor":2,\
        "note":"inventory truncated at cache"}
        """
        guard case .softwareListing(let listing) = try decode(truncated)
        else {
            return XCTFail("not a software listing")
        }
        XCTAssertEqual(listing.entries.first?.off, true)
        XCTAssertFalse(listing.entries.first?.isLaunchable ?? true,
                       "an empty path is listed but not launchable")
        XCTAssertEqual(listing.note, "inventory truncated at cache")
    }

    /// serve_process_act(): the guest's answer to a drive verb. Two
    /// literals in one function, each a complete object, so the
    /// conformance check reaches them — but the ok:false shape carries a
    /// reason the ok:true shape omits, which these pin.
    func testProcessResultAsTheGuestWritesIt() throws {
        let ok = #"{"type":"process.result","id":11,"ok":true}"#
        guard case .processResult(let applied) = try decode(ok) else {
            return XCTFail("not a process result")
        }
        XCTAssertTrue(applied.ok)
        XCTAssertNil(applied.reason)

        let refused = #"{"type":"process.result","id":12,"ok":false,"#
            + #""reason":"that process is no longer running"}"#
        guard case .processResult(let declined) = try decode(refused) else {
            return XCTFail("not a process result")
        }
        XCTAssertFalse(declined.ok)
        XCTAssertEqual(declined.reason, "that process is no longer running")
    }

    /// A first page that fills: `more` is true and the cursor points past
    /// what was sent, which is what the host carries to ask for the rest.
    func testProcessListingWithMorePages() throws {
        let json = """
        {"type":"process.listing","id":10,"processes":[\
        {"name":"NOW","kind":"application","code":"APPL","creator":"NwWs",\
        "sizeKB":3072,"front":true}],\
        "more":true,"cursor":17}
        """
        guard case .processListing(let listing) = try decode(json) else {
            return XCTFail("not a process listing")
        }
        XCTAssertTrue(listing.more)
        XCTAssertEqual(listing.cursor, 17, "where the next page resumes")
    }

    /// file.progress, sent mid-put so the host's bar moves.
    func testFileProgressAsTheGuestWritesIt() throws {
        let json = #"{"type":"file.progress","id":5,"received":32768}"#
        guard case .fileProgress(let progress) = try decode(json) else {
            return XCTFail("not progress")
        }
        XCTAssertEqual(progress.received, 32768)
    }

    /// census.report, assembled row-by-row in guest/src/census_report.c
    /// (header, a loop over rows, then the trailing fields). The loop puts
    /// it out of the conformance check's reach, so the exact shape it emits
    /// is pinned here: a present page with rows and no continuation, and a
    /// partial page carrying cursor/total/note.
    func testCensusReportAsTheGuestWritesIt() throws {
        let present = """
        {"type":"census.report","id":4,"probe":"video",\
        "outcome":"present","rows":[["Display 1","main","main screen"],\
        ["Bounds","0,0,600,800","800 x 600 pixels"]],"more":false}
        """
        guard case .censusReport(let page) = try decode(present) else {
            return XCTFail("not a report")
        }
        XCTAssertEqual(page.probe, "video")
        XCTAssertEqual(page.outcome, "present")
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows[0], ["Display 1", "main", "main screen"],
                       "name, raw, meaning - in that order")
        XCTAssertFalse(page.more)
        XCTAssertNil(page.cursor, "no cursor when there is no continuation")

        let partial = """
        {"type":"census.report","id":5,"probe":"gestalt",\
        "outcome":"present","rows":[["SystemVersion","$00000921",\
        "version 9.2.1"]],"more":true,"cursor":16,"total":203}
        """
        guard case .censusReport(let more) = try decode(partial) else {
            return XCTFail("not a report")
        }
        XCTAssertTrue(more.more)
        XCTAssertEqual(more.cursor, 16, "pass back to continue the walk")
        XCTAssertEqual(more.total, 203)
    }

    // MARK: - NOW-68K (guest68k/src)

    /// now68k_hello_build() — guest68k/src/hello.c:15-29. Seven appends,
    /// so the source scanner sees seven fragments and no message; this is
    /// the whole thing.
    ///
    /// Field order is the order of the appends, and nothing in between:
    /// `type`, `contract` (an integer through now68k_fmt_append_long),
    /// `side` fixed to "guest", `version` (the caller's string — wire68.c
    /// passes NOW68K_APP_VERSION, "0.9", wire68.c:68), then `name`, `os`
    /// and `chunk` frozen into the format literal itself from
    /// NOW68K_HELLO_NAME / _OS / _CHUNK (guest68k/src/hello.h:16-18).
    ///
    /// chunk is 4096 rather than the contract's 8192 default, deliberately:
    /// MacTCP advertises a ~8K receive window whatever rcvBuff says, and an
    /// 8 KB chunk stalls on delayed-ACK window updates. The connection uses
    /// the smaller of the two sides' preferences, so this number is the one
    /// that governs — which is the reason to pin it.
    ///
    /// There is no truncated hello: hello.c returns 0 rather than a short
    /// buffer when anything would not fit (the `|| pos >= cap` arm), and
    /// wire68.c:1023 tears the connection down instead of sending. So this
    /// one string, with only `version` free to vary, is the entire set of
    /// bytes this message can ever be.
    func test68KHelloAsTheGuestWritesIt() throws {
        guard case .hello(let hello) =
            try decode(Guest68KWire.hello) else {
            return XCTFail("not a hello")
        }
        XCTAssertEqual(hello.contract, Contract.revision)
        XCTAssertEqual(hello.side, "guest")
        XCTAssertEqual(hello.version, "0.9", "NOW68K_APP_VERSION")
        XCTAssertEqual(hello.name, "now-68k",
                       "the name that tells the two guests apart in the UI")
        XCTAssertEqual(hello.os, "7.1")
        XCTAssertEqual(hello.chunk, 4096)
        XCTAssertLessThan(hello.chunk ?? Contract.defaultChunk,
                          Contract.defaultChunk,
                          "MacTCP's ~8K window: 68K asks for less than default")
    }

    /// now68k_ping_build() — guest68k/src/ping.c:16-18. Three appends,
    /// hence invisible to the source scanner.
    ///
    /// The id is g_ping_id, pre-incremented at wire68.c:1044 and reset to 0
    /// at the start of every session (wire68.c:638, 1193), so the first ping
    /// of any connection is exactly `1`. now68k_fmt_append_long
    /// (numfmt.c:17-45) writes plain decimal: no padding, no grouping, no
    /// leading `+`, and a `-` only for a negative value, which g_ping_id
    /// never is.
    func test68KPingAsTheGuestWritesIt() throws {
        guard case .ping(let id) = try decode(Guest68KWire.pingFirst) else {
            return XCTFail("not a ping")
        }
        XCTAssertEqual(id, 1, "the first ping of a session")

        guard case .ping(let later) = try decode(Guest68KWire.pingLater) else {
            return XCTFail("not a ping")
        }
        XCTAssertEqual(later, 7, "multi-digit ids are plain decimal")
    }

    /// send_error_reply() — guest68k/src/wire68.c:461-494, the 68K guest's
    /// only emitter of a top-level `error`. Reached from the live-state
    /// dispatcher's fall-through (wire68.c:894-899) for any message type
    /// that is not pong / bye / error / hello / refuse / command.request /
    /// census.request.
    ///
    /// Two shapes, and only two, because `id` is the one conditional
    /// append: present when now68k_json_find_int found an `id` on the
    /// failed request, absent when it did not. `code` and `message` are a
    /// single fixed literal — the request's own `type` is deliberately NOT
    /// echoed, because this writer never escapes anything and a
    /// peer-controlled type could carry a quote or backslash that breaks
    /// the JSON around it. That is why there is no escaping edge to pin
    /// here: nothing peer-controlled reaches the payload except the
    /// integer id.
    ///
    /// NOTE: unlike hello and ping, this frame has never been exercised
    /// against a real host. It is a claim about the emitter read off the C,
    /// not evidence from a run.
    func test68KErrorReplyAsTheGuestWritesIt() throws {
        guard case .error(let withID) =
            try decode(Guest68KWire.errorWithID) else {
            return XCTFail("not an error")
        }
        XCTAssertEqual(withID.id, 7, "echoes the failed request's id")
        XCTAssertEqual(withID.code, "not-implemented")
        XCTAssertEqual(withID.message, "unsupported message type")

        guard case .error(let anonymous) =
            try decode(Guest68KWire.errorWithoutID) else {
            return XCTFail("not an error")
        }
        XCTAssertNil(anonymous.id,
                     "no id on the request means no id field, not id:0")
        XCTAssertEqual(anonymous.code, "not-implemented")
    }

    /// The id the 68K guest echoes is whatever the host's request carried,
    /// and now68k_json_find_int (json_scan.c:109-121) accepts a leading `-`.
    /// numfmt.c:34 then writes the sign back out, so a negative id is a
    /// shape the host must be able to read — it is the host's own number
    /// coming home.
    func test68KErrorEchoesANegativeIdBack() throws {
        guard case .error(let negative) =
            try decode(Guest68KWire.errorNegativeID) else {
            return XCTFail("not an error")
        }
        XCTAssertEqual(negative.id, -1)
    }
}

/// The exact payload bytes NOW-68K puts on the control channel, derived
/// from guest68k/src and kept in one place so GuestWireConformanceTests can
/// put the same strings through the contract's required-field check that
/// the whole-message scan gives every other frame.
///
/// hello and ping were produced by compiling guest68k/src/hello.c,
/// ping.c and numfmt.c with the host cc and printing the buffer, the same
/// way guest/tests exercises Toolbox-free guest code. The two error shapes
/// are transcribed from the literals in send_error_reply().
enum Guest68KWire {
    static let hello = #"{"type":"hello","contract":1,"side":"guest","#
        + #""version":"0.9","name":"now-68k","os":"7.1","chunk":4096}"#

    static let pingFirst = #"{"type":"ping","id":1}"#
    static let pingLater = #"{"type":"ping","id":7}"#

    static let errorWithID = #"{"type":"error","id":7,"#
        + #""code":"not-implemented","#
        + #""message":"unsupported message type"}"#
    static let errorWithoutID = #"{"type":"error","#
        + #""code":"not-implemented","#
        + #""message":"unsupported message type"}"#
    static let errorNegativeID = #"{"type":"error","id":-1,"#
        + #""code":"not-implemented","#
        + #""message":"unsupported message type"}"#

    /// Every fixture string above, for the contract check next door.
    static let all: [String] = [
        hello, pingFirst, pingLater,
        errorWithID, errorWithoutID, errorNegativeID,
    ]
}
