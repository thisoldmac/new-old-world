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
/// now-guest-ppc/src/core/wire.c. When one changes there, it changes here, and that
/// is the point: this is the only place the two halves are compared.
///
/// There are two guests now, and their emitters do not resemble each
/// other. The PowerPC Carbon client (`now-guest-ppc/src`) writes messages with
/// snprintf; NOW-68K (`now-guest-68k/src`) has no printf family at all — the
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

    /// serve_scene() appends the application-owned settlement records after
    /// its fixed scene.begin prefix. This fixture is independent of the
    /// Swift encoder and pins the exact guest-written optional tail.
    func testSceneBeginSettlementsAsTheGuestWritesIt() throws {
        let json = """
        {"type":"scene.begin","id":4,"transfer":9,"bytes":9214,\
        "irVersion":2,"seq":11,"capturedAt":712345.5,"source":"native",\
        "walkMs":18,"settlements":[{"correlationHi":2779054081,\
        "correlationLo":7,"status":"confirmed","residentStage":4,\
        "createdTicks":100,"timedOutTicks":90,"terminalTicks":140,\
        "confirmedScene":11}]}
        """
        guard case .sceneBegin(let begin) = try decode(json) else {
            return XCTFail("not a scene begin")
        }
        let settlement = try XCTUnwrap(begin.settlements?.first)
        XCTAssertEqual(settlement.correlationHi, 0xA5A5_0001)
        XCTAssertEqual(settlement.status, "confirmed")
        XCTAssertEqual(settlement.timedOutTicks, 90,
                       "late confirmation keeps its earlier timeout")
    }

    /// send_scene_same() in now-guest-ppc/src/core/wire.c, built across
    /// several snprintf calls because its phases block loops over the
    /// phase table. This is the answer a guest gives when the machine did
    /// not change — the cheapest and most common one in the family, and
    /// the only one that costs no transfer at all.
    func testSceneSameAsTheGuestWritesIt() throws {
        let json = """
        {"type":"scene.same","id":7,"seq":412,"digest":"9017d2cd",\
        "capturedAt":712345.5,"walkMs":4,"phases":{"us":{"enumerate":812,\
        "bind":1904,"windows":2201,"controls":63,"menubar":1044,\
        "semantics":0,"refs":190,"encode":589},"clockReads":42,\
        "clockUs":21,"faults":0},"settlements":[]}
        """
        guard case .sceneSame(let same) = try decode(json) else {
            return XCTFail("not a scene.same")
        }
        XCTAssertEqual(same.id, 7)
        XCTAssertEqual(same.seq, 412, "the producer's counter still moves")
        XCTAssertEqual(same.digest, "9017d2cd",
                       "the digest is restated rather than implied, so a "
                           + "consumer can prove the answer is about the "
                           + "baseline it named")
        XCTAssertEqual(same.walkMs, 4)
        XCTAssertEqual(same.settlements?.count, 0)
    }

    /// The same message from a guest with no clock installed. `phases` is
    /// ABSENT rather than zeroed, and the settlement tail is empty — which
    /// is the shortest form the guest can emit, and the one whose trailing
    /// comma had to be stepped back over.
    func testSceneSameWithoutPhasesAsTheGuestWritesIt() throws {
        let json = """
        {"type":"scene.same","id":8,"seq":413,"digest":"deadbeef",\
        "capturedAt":712399.5,"walkMs":3}
        """
        guard case .sceneSame(let same) = try decode(json) else {
            return XCTFail("not a scene.same")
        }
        XCTAssertNil(same.settlements,
                     "absent is not empty: an older guest said nothing about "
                         + "settlements, it did not report none")
    }

    /// now_wire_chat_send() in now-guest-ppc/src/core/wire.c, its prompt
    /// carrying the one guest-emitted chat string with arbitrary human
    /// text. Pinned for exec.output's reason: escaping is the one place
    /// a person's own typing can corrupt the wire. Quotes, a backslash,
    /// and a MacRoman high byte (0xA5, the bullet) as now_json_escape
    /// writes them.
    func testChatSendEscapingAsTheGuestWritesIt() throws {
        let json = """
        {"type":"chat.send","id":41,"ref":"m3",\
        "prompt":"say \\"hi\\" \\\\ twice \\u00A5 done"}
        """
        let message = try decode(json)
        guard case .chatSend(let send) = message else {
            return XCTFail("decoded as \(message)")
        }
        XCTAssertEqual(send.id, 41)
        XCTAssertEqual(send.ref, "m3")
        XCTAssertEqual(send.prompt, "say \"hi\" \\ twice \u{00A5} done")
    }

    /// now_wire_chat_model_page() in now-guest-ppc/src/core/wire.c: the
    /// per-provider ask, cursor included — the guest's half of the
    /// pagination loop, pinned so the field names cannot drift.
    func testChatModelsPageAskAsTheGuestWritesIt() throws {
        let json = """
        {"type":"chat.models","id":6,"provider":"omlx","cursor":16}
        """
        let message = try decode(json)
        guard case .chatModels(let ask) = message else {
            return XCTFail("decoded as \(message)")
        }
        XCTAssertEqual(ask.id, 6)
        XCTAssertEqual(ask.provider, "omlx")
        XCTAssertEqual(ask.cursor, 16)
    }

    /// run_help() in now-guest-ppc/src/commands/commands.c, listing what that Mac serves.
    ///
    /// This reply is discovery: the host console keeps no command list, so
    /// these rows are the only account of the far machine's command set there
    /// is. The names are read out of the first column — that is the one
    /// structural promise the contract makes about this output — so a change
    /// to the row shape here silently costs Tab completion on both guests.
    func testHelpAsTheGuestWritesIt() throws {
        let json = """
        {"type":"command.result","id":7,"ok":true,"output":{"help":[\
        ["gestalt","report this Mac: system, model, RAM, CarbonLib"],\
        ["ls","list a folder in the shared files"],\
        ["help","list commands (\\"help <cmd>\\" for one)"]]}}
        """
        // The summary in cmd_help.c really does contain quotes, so this is
        // also a check that now_json_escape ran over it.
        guard case .commandResult(let result) = try decode(json) else {
            return XCTFail("not a command result")
        }
        XCTAssertTrue(result.ok)
        let rows = try XCTUnwrap(result.output?["help"])
        XCTAssertEqual(rows.compactMap(\.first),
                       ["gestalt", "ls", "help"],
                       "the first column is the command names")
        XCTAssertEqual(rows.last?.last,
                       #"list commands ("help <cmd>" for one)"#,
                       "an escaped quote inside a summary survives the trip")
    }

    /// run_help() on NOW-68K (now-guest-68k/src/commands/commands68.c): the rows it
    /// builds from its own doc table, plus the note row that keeps a short
    /// list from reading as a broken one. Its empty label is deliberate:
    /// rows are [label, value] and this one is prose, not a command.
    ///
    /// The sample below is a SHAPE, not this guest's current command set —
    /// docs/contract-coverage.md carries that, derived rather than
    /// remembered, and CommandRegistryTests fails when the guest's table
    /// and the contract disagree.
    func testHelpAsTheSixtyEightKGuestWritesIt() throws {
        let json = """
        {"type":"command.result","id":3,"ok":true,"output":{"help":[\
        ["launch","open an application on this Mac"],\
        ["quit","ask an application on this Mac to quit"],\
        ["help","list the commands this Mac serves"],\
        ["","every other command answers unknown-command"]]}}
        """
        guard case .commandResult(let result) = try decode(json) else {
            return XCTFail("not a command result")
        }
        let rows = try XCTUnwrap(result.output?["help"])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last?.first, "",
                       "the note carries no command name, and the host must "
                       + "not offer \"\" as a completion")
    }

    /// The contract's answer for a command a machine does not have. NOW-68K
    /// gives this for most of what the Carbon guest serves, and the host
    /// console renders it verbatim rather than pre-empting it — which is
    /// the whole of being a dumb shell.
    ///
    /// The example used to be `ls`, which NOW-68K now answers. Swapped for
    /// one it still does not, because a fixture whose premise has quietly
    /// become false is a test that passes while proving something else.
    func testUnknownCommandAsTheGuestWritesIt() throws {
        let json = """
        {"type":"command.result","id":9,"ok":false,"error":\
        {"code":"unknown-command","message":"tail is not a command this Mac \
        knows"}}
        """
        guard case .commandResult(let result) = try decode(json) else {
            return XCTFail("not a command result")
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, "unknown-command")
        XCTAssertNil(result.output)
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
        "sizeKB":3072,"front":true,"psnHigh":0,"psnLow":16519,\
        "isSelf":true},\
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
        // isSelf is the guest naming ITSELF in its own list — the only
        // trustworthy answer to "which of these is the process on the
        // other end of this connection", and emitted only where true.
        XCTAssertEqual(listing.processes[1].isSelf, true)
        XCTAssertNil(listing.processes[0].isSelf,
                     "absent means not-self; the contract does not make "
                     + "every row pay for a false")
        XCTAssertFalse(listing.processes[1].isQuittable,
                       "the guest refuses to quit itself, so the host "
                       + "should never offer it")
        XCTAssertTrue(listing.processes[0].isQuittable)
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

        /* THE THREE SHAPES serve_process_act now writes, as it writes
           them. `outcome` exists because `ok` alone cannot tell a refusal
           from an accepted switch that never landed, and a field the host
           declares but drops on the floor would be the same lie one layer
           down - so these decode it rather than only permitting it. */
        let landed = #"{"type":"process.result","id":13,"ok":true,"#
            + #""outcome":"confirmed"}"#
        guard case .processResult(let front) = try decode(landed) else {
            return XCTFail("not a process result")
        }
        XCTAssertTrue(front.ok)
        XCTAssertEqual(front.outcome, "confirmed")

        /* The branch that has NEVER RUN on a real guest (wire.c says so
           at the site). The fixture is what proves the host can read it
           when it does, which is the only thing a fixture can prove. */
        let unlanded = #"{"type":"process.result","id":14,"ok":false,"#
            + #""outcome":"dispatched-but-unconfirmed","#
            + #""reason":"the Mac accepted the request and it is still "#
            + #"not frontmost"}"#
        guard case .processResult(let pending) = try decode(unlanded) else {
            return XCTFail("not a process result")
        }
        XCTAssertFalse(pending.ok)
        XCTAssertEqual(pending.outcome, "dispatched-but-unconfirmed")

        /* A quit: delivered, and that is ALL that was established. ok is
           true and the outcome says why that is not a promise it has
           gone. */
        let sent = #"{"type":"process.result","id":15,"ok":true,"#
            + #""outcome":"dispatched-but-unconfirmed"}"#
        guard case .processResult(let asked) = try decode(sent) else {
            return XCTFail("not a process result")
        }
        XCTAssertTrue(asked.ok)
        XCTAssertEqual(asked.outcome, "dispatched-but-unconfirmed")

        /* NOW-68K emits no outcome at all, and nil must not be read as
           "unknown" - it means the sender does not report outcomes, which
           is why BringToFrontProjection's confirming re-list stays. */
        XCTAssertNil(applied.outcome)
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

    /// census.report, assembled row-by-row in now-guest-ppc/src/census/census_report.c
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

    // MARK: - NOW-68K (now-guest-68k/src)

    /// now68k_hello_build() — now-guest-68k/src/core/hello.c:15-29. Seven appends,
    /// so the source scanner sees seven fragments and no message; this is
    /// the whole thing.
    ///
    /// Field order is the order of the appends, and nothing in between:
    /// `type`, `contract` (an integer through now68k_fmt_append_long),
    /// `side` fixed to "guest", `version` (the caller's string — wire68.c
    /// passes NOW68K_APP_VERSION, read from wire68.c by this file), then
    /// and `chunk` frozen into the format literal itself from
    /// NOW68K_HELLO_NAME / _OS / _CHUNK (now-guest-68k/src/core/hello.h:16-18).
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
        XCTAssertEqual(hello.version, Guest68KWire.appVersion,
                       "NOW68K_APP_VERSION, read from wire68.c")
        XCTAssertEqual(hello.name, "now-68k",
                       "the name that tells the two guests apart in the UI")
        XCTAssertEqual(hello.os, "7.1.0",
                       "measured from gestaltSystemVersion, three components")
        XCTAssertEqual(hello.machine?.id, 34,
                       "the raw gestaltMachineType, not a name")
        XCTAssertEqual(hello.machine?.model, "Macintosh Quadra 950")
        XCTAssertEqual(hello.chunk, 4096)
        XCTAssertLessThan(hello.chunk ?? Contract.defaultChunk,
                          Contract.defaultChunk,
                          "MacTCP's ~8K window: 68K asks for less than default")
    }

    /// now68k_ping_build() — now-guest-68k/src/core/ping.c:16-18. Three appends,
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

    /// n68_census_report_json() — now-guest-68k/src/census/n68_census.c. The
    /// 68K guest's census.report, assembled from numfmt appends like
    /// everything else it writes, so the source scanner sees fragments and
    /// this is the whole frame.
    ///
    /// Three shapes, and each pins something the other two cannot:
    ///
    ///   - an outcome that is not `present` carries its reason in `note`,
    ///     so a partial answer says what it could not reach;
    ///   - `absent` decodes as absent. It is the MACHINE saying no, and
    ///     conflating it with `refused` is the defect the whole census
    ///     design is built against — the 68K guest now answers all
    ///     fourteen declared probes, several of them absent, where until
    ///     this arc it answered every one of them refused;
    ///   - `cursor` appears only with `more`, and counts what the FRAME
    ///     carried. The rows a 1024-byte control frame could not hold are
    ///     deferred to the next request rather than lost, which is the one
    ///     thing this guest's paging can get wrong without any single page
    ///     looking wrong.
    ///
    /// NOTE: these are claims about the emitter read off the C and proved
    /// by its native test. No census probe on this guest has ever run on a
    /// Macintosh — see docs/contract-coverage.md.
    func test68KCensusReportAsTheGuestWritesIt() throws {
        guard case .censusReport(let pram) =
            try decode(Guest68KWire.censusReportPram68K) else {
            return XCTFail("not a report")
        }
        XCTAssertEqual(pram.probe, "pram")
        XCTAssertEqual(pram.outcome, "partial")
        XCTAssertEqual(pram.rows.count, 2)
        XCTAssertEqual(pram.rows[0],
                       ["valid", "$A8",
                        "$A8 - Parameter RAM is being retained"],
                       "name, raw, meaning - in that order")
        XCTAssertFalse(pram.more)
        XCTAssertNil(pram.cursor, "no cursor when there is no continuation")
        XCTAssertEqual(pram.total, 2)

        guard case .censusReport(let pccard) =
            try decode(Guest68KWire.censusReportAbsent68K) else {
            return XCTFail("not a report")
        }
        XCTAssertEqual(pccard.outcome, "absent",
                       "the machine said no; that is not `refused`")
        XCTAssertTrue(pccard.rows.isEmpty)

        guard case .censusReport(let paged) =
            try decode(Guest68KWire.censusReportPaged68K) else {
            return XCTFail("not a report")
        }
        XCTAssertTrue(paged.more)
        XCTAssertEqual(paged.cursor, 1, "resume at the first row not carried")
        XCTAssertEqual(paged.total, 24, "and say how many there are in all")
    }

    /// send_error_reply() — now-guest-68k/src/core/wire68.c:461-494, the 68K guest's
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

    /// `ps` on NOW-68K, which is the verb this whole seam was rebuilt for:
    /// the host console is a dumb shell, so a capability the 68K guest
    /// served only as the `process.list` message family was reachable from
    /// its own keyboard and nowhere else. The reply is a command.result
    /// like any other — which is the point, because it means the host
    /// console renders it with no knowledge of what `ps` is.
    ///
    /// The detail column is the same sentence the PowerPC guest builds
    /// (now-guest-ppc/src/commands/commands.c, now_process_gather), pinned here because one
    /// console renders both machines and a person should not have to know
    /// which one they are reading.
    func test68KPsReplyAsTheGuestWritesIt() throws {
        guard case .commandResult(let result) =
            try decode(Guest68KWire.psReply) else {
            return XCTFail("not a command.result")
        }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.id, 4, "echoes the request id")
        let rows = try XCTUnwrap(result.output?["ps"],
                                 "the contract names the group `ps`")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0],
                       ["NOW-68K", "application, 384 KB, front, self"],
                       "the guest names its own row, so a reader never has "
                       + "to infer which process is answering them")
        XCTAssertEqual(rows[1], ["Finder", "finder, 250 KB"])
    }

    /// process.result, as NOW-68K's handle_process_quit appends it. The
    /// three shapes are the three answers the guest can give, and the
    /// distinction that matters is between the first and the other two:
    /// `ok` says the Apple Event was DELIVERED, never that the process
    /// has gone. A caller that reads ok:true as "it quit" is the failure
    /// proc68.h exists to prevent, one message family over.
    func test68KProcessResultAsTheGuestWritesIt() throws {
        guard case .processResult(let sent) =
            try decode(Guest68KWire.processQuitSent) else {
            return XCTFail("not a process.result")
        }
        XCTAssertEqual(sent.id, 12, "echoes the request id")
        XCTAssertTrue(sent.ok)
        XCTAssertNil(sent.reason, "a reason belongs to a refusal")

        guard case .processResult(let stale) =
            try decode(Guest68KWire.processQuitStale) else {
            return XCTFail("not a process.result")
        }
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.reason,
                       "quit: that process is no longer running")

        guard case .processResult(let itself) =
            try decode(Guest68KWire.processQuitSelf) else {
            return XCTFail("not a process.result")
        }
        XCTAssertFalse(itself.ok)
        XCTAssertEqual(itself.reason, "quit: NOW will not ask itself to quit")
    }

    /// The front half of the same reply shape. Worth its own fixture
    /// because the two verbs' `ok` means two different things — delivered
    /// for quit, accepted for front — and both are weaker than the words
    /// a reader supplies for free ("it quit", "it is in front").
    func test68KProcessFrontResultAsTheGuestWritesIt() throws {
        guard case .processResult(let sent) =
            try decode(Guest68KWire.processFrontSent) else {
            return XCTFail("not a process.result")
        }
        XCTAssertEqual(sent.id, 15)
        XCTAssertTrue(sent.ok)

        guard case .processResult(let stale) =
            try decode(Guest68KWire.processFrontStale) else {
            return XCTFail("not a process.result")
        }
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.reason,
                       "front: that process is no longer running")
    }

    /// Truncation is STATED. `ps` has no cursor to page with, so a machine
    /// running more processes than one control frame carries ends its list
    /// with the count it dropped. A silently short list would read as the
    /// whole machine, and someone would go looking for an application that
    /// was running the entire time.
    func test68KPsReplySaysWhatItDropped() throws {
        guard case .commandResult(let result) =
            try decode(Guest68KWire.psReplyTruncated) else {
            return XCTFail("not a command.result")
        }
        let rows = try XCTUnwrap(result.output?["ps"])
        XCTAssertEqual(rows.last, ["...", "6 more not shown"],
                       "the last row names the processes not shown")
    }

    // MARK: - NOW-68K's file family (the browse half)

    /// `file.listing` from NOW-68K — the half of the family that lets a
    /// host SEE the machine rather than only write to it. Until this
    /// landed, the host's Files module had nothing to show against a 68K
    /// guest, so the one thing a person most wants from an old Mac on a
    /// network was the one thing this guest could not answer.
    ///
    /// The page is small on purpose. This guest's outbound payload cap is
    /// 1024 bytes against the PowerPC guest's 4 KB, so where that one
    /// sends sixteen entries a page this one sends what fits and pages.
    /// A host must not assume a full page means a full folder — `more`
    /// and `cursor` are the only things that say.
    func test68KFileListingAsTheGuestWritesIt() throws {
        guard case .fileListing(let listing) =
            try decode(Guest68KWire.fileListingRoot) else {
            return XCTFail("not a file.listing")
        }
        XCTAssertEqual(listing.id, 11, "echoes the request id")
        XCTAssertEqual(listing.path, "", "the root is the empty path")
        XCTAssertEqual(listing.entries.count, 3)
        XCTAssertTrue(listing.more, "the folder goes on past this page")
        XCTAssertEqual(listing.cursor, 4, "and says where to continue")
        XCTAssertEqual(listing.root, "Macintosh HD:Desktop Folder:", """
            the root listing names the place it is looking at. On this \
            guest that is not configurable and therefore not guessable \
            from anything else the host has.
            """)

        // A folder carries no type, creator or fork sizes. The host has to
        // be happy with their absence — a renderer that force-unwrapped
        // dataBytes would crash on the first folder either guest sent.
        XCTAssertEqual(listing.entries[0].name, "Projects")
        XCTAssertTrue(listing.entries[0].isFolder)
        XCTAssertNil(listing.entries[0].fileType)
        XCTAssertNil(listing.entries[0].dataBytes)

        XCTAssertEqual(listing.entries[1].name, "Read Me")
        XCTAssertEqual(listing.entries[1].fileType, "TEXT")
        XCTAssertEqual(listing.entries[1].creator, "ttxt")
        XCTAssertEqual(listing.entries[1].dataBytes, 4096)
        XCTAssertEqual(listing.entries[1].rsrcBytes, 0)

        // A two-fork application, which is what most of this machine's
        // disk actually is.
        XCTAssertEqual(listing.entries[2].rsrcBytes, 262144)

        // 3000000000 is past 2^31, where this toolchain's signed `long`
        // wraps negative — and a negative Mac date decodes perfectly well
        // into 1904, so a lost unsigned append is a listing that looks
        // right and dates every file to the epoch.
        XCTAssertEqual(listing.entries[2].modified, 3_000_000_000)

        for entry in listing.entries {
            XCTAssertNil(entry.identity, """
                NOW-68K sends no identity: it is a precondition token for \
                mutations this guest does not serve. If that ever changes, \
                this assertion is the thing to delete — deliberately, not \
                by accident.
                """)
        }
    }

    /// The page that ENDS a walk, and the one asymmetry with the root
    /// page: no caption, because a subfolder listing already knows where
    /// it is, and more:false with the cursor parked past the last entry.
    func test68KFileListingSubfolderAsTheGuestWritesIt() throws {
        guard case .fileListing(let listing) =
            try decode(Guest68KWire.fileListingSubfolder) else {
            return XCTFail("not a file.listing")
        }
        XCTAssertEqual(listing.path, "Projects")
        XCTAssertFalse(listing.more)
        XCTAssertEqual(listing.cursor, 5)
        XCTAssertNil(listing.root, "only the root listing carries a caption")
    }

    /// `ls` — the console face on the same enumeration, and the reason it
    /// exists at all: the host console is a dumb shell that knows no
    /// message families, so a capability served only as `file.list` is one
    /// nobody can type. `ps` cost a day teaching that (2026-07-25).
    func test68KLsReplyAsTheGuestWritesIt() throws {
        guard case .commandResult(let result) =
            try decode(Guest68KWire.lsReply) else {
            return XCTFail("not a command.result")
        }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.id, 13, "echoes the request id")
        let rows = try XCTUnwrap(result.output?["ls"],
                                 "the contract names the group `ls`")
        XCTAssertEqual(rows[0], ["Share", "Macintosh HD:Desktop Folder:"])
        XCTAssertEqual(rows[1], ["Folder", "(root)"])
        XCTAssertEqual(rows[2], ["Projects", "folder"])
        // The same vocabulary the PowerPC guest's now_files_describe uses,
        // pinned because one console renders both machines and a person
        // should not have to know which one they are reading.
        XCTAssertEqual(rows[3], ["Read Me", "TEXT  4 KB"])
        XCTAssertEqual(rows[4], ["NOW-68K", "APPL  128 KB + 256 KB rsrc"])
        XCTAssertEqual(rows.last, ["...", "more entries follow"], """
            `ls` has no cursor — the contract gives command.result none — \
            so a folder longer than one page says so in a final row. A \
            silently short listing would read as the whole folder.
            """)
    }

    /// A folder this guest will not list. The refusal reuses the family's
    /// own `file.refuse`, not a generic protocol error: a host blocked on
    /// a file.listing needs the answer in the envelope it is waiting on.
    func test68KFileListRefusalAsTheGuestWritesIt() throws {
        guard case .fileRefuse(let refuse) =
            try decode(Guest68KWire.fileListRefuseBadPath) else {
            return XCTFail("not a file.refuse")
        }
        XCTAssertEqual(refuse.id, 14)
        XCTAssertEqual(refuse.code, "bad-path")
        XCTAssertFalse(refuse.reason?.isEmpty ?? true,
                       "a refusal says why in words a person can read")
    }

    // MARK: - NOW-68K's file family (the receive half)

    /// handle_file_offer() - now-guest-68k/src/core/wire68.c. The acceptance.
    ///
    /// Two fields and no more, and BOTH absences are the point.
    ///
    /// `have` is absent because this guest does not implement resume.
    /// The contract reads an absent `have` as "start from the beginning"
    /// (FileAccept), so the simplest possible receiver is a legal one -
    /// but a host that read a missing `have` as anything else would
    /// begin every transfer at an offset the guest never claimed.
    ///
    /// `freeBytes` / `reservedBytes` are absent because this guest checks
    /// room before accepting and then says nothing about it. The PowerPC
    /// guest reports both, so the two accepts do not look alike on the
    /// wire and the host has to be happy with either.
    func test68KFileAcceptAsTheGuestWritesIt() throws {
        guard case .fileAccept(let a) =
                try decode(Guest68KWire.fileAccept) else {
            return XCTFail("not a file.accept")
        }
        XCTAssertEqual(a.id, 3)
        XCTAssertNil(a.have, """
            NOW-68K must never claim a resume offset: it keeps no \
            partials, so any `have` it sent would name bytes it does not \
            hold and the sender would begin past the start of the file.
            """)
        XCTAssertEqual(a.staging, "same-folder-temp")
    }

    /// put_refuse() - now-guest-68k/src/core/wire68.c, rendering an N68PutCode.
    ///
    /// The unknown-container case pins a CONTRACT GAP rather than a
    /// behaviour: FileRefuse.code has no value meaning "this receiver
    /// cannot handle that", so it is reported as `io-error` with the
    /// truth in `reason`. Nothing failed and nothing was attempted, so
    /// the code is a lie of category - an honest one, because every
    /// alternative in the enum is worse, but the day the contract grows
    /// a value for it this fixture is where the change lands.
    ///
    /// This used to be the MacBinary refusal. MacBinary is decoded now;
    /// what reaches this path is a container from a contract revision
    /// this build predates, which must NOT be quietly treated as `data` -
    /// an unknown envelope written out as a raw fork is a file of the
    /// wrong length and the wrong shape, blamed on the disk.
    func test68KFileRefuseAsTheGuestWritesIt() throws {
        guard case .fileRefuse(let r) =
                try decode(Guest68KWire.fileRefuseExists) else {
            return XCTFail("not a file.refuse")
        }
        XCTAssertEqual(r.id, 4)
        XCTAssertEqual(r.code, "exists")

        guard case .fileRefuse(let unknown) =
                try decode(Guest68KWire.fileRefuseContainer) else {
            return XCTFail("not a file.refuse")
        }
        XCTAssertEqual(unknown.code, "io-error",
                       "the contract has no code for `unsupported`")
        XCTAssertEqual(unknown.reason,
                       "that container is not one this guest knows",
                       "so `reason` is the only place the truth lives")
    }

    /// put_report_progress() - now-guest-68k/src/core/wire68.c.
    ///
    /// The smallest message this guest sends and the one it sends most,
    /// because it is not a progress bar: the host clocks its sender on
    /// these and parks once it is too far ahead of the last one
    /// (docs/large-transfers.md). A `received` the host cannot read is a
    /// transfer that stops at the window size and never resumes, so this
    /// shape matters far more than its size suggests.
    func test68KFileProgressAsTheGuestWritesIt() throws {
        guard case .fileProgress(let p) =
                try decode(Guest68KWire.fileProgress) else {
            return XCTFail("not a file.progress")
        }
        XCTAssertEqual(p.id, 3)
        XCTAssertEqual(p.received, 8192)
    }

    /// put_done() - now-guest-68k/src/core/wire68.c, both outcomes.
    ///
    /// The success case carries the guest's own CRC-32, and that is the
    /// field this fixture is really here for. `crc32` is UNSIGNED and
    /// `long` on the 68K toolchain is not, so a value above 0x7FFFFFFF -
    /// half of them - comes out negative through an ordinary integer
    /// append. It would still decode as a number, compare unequal to the
    /// host's, and report a perfectly good 4 MB file as corrupt. The
    /// value below sits above that boundary on purpose.
    func test68KFileDoneAsTheGuestWritesIt() throws {
        guard case .fileDone(let ok) =
                try decode(Guest68KWire.fileDoneOK) else {
            return XCTFail("not a file.done")
        }
        XCTAssertEqual(ok.id, 3)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.received, 4_194_304)
        XCTAssertEqual(ok.crc32, 3_419_628_326,
                       "0xCBF43926 - above the signed-long boundary, "
                       + "which is where an unsigned append is the "
                       + "difference between `complete` and `corrupt`")
        XCTAssertEqual(ok.finalization, "same-folder-rename")
        XCTAssertEqual(ok.cleanup, "temp-renamed")

        guard case .fileDone(let bad) =
                try decode(Guest68KWire.fileDoneCorrupt) else {
            return XCTFail("not a file.done")
        }
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.code, "corrupt")
        XCTAssertEqual(bad.cleanup, "temp-discarded", """
            Always temp-discarded on this guest: it implements no resume, \
            so a partial nothing can resume from is debris. A \
            `partial-retained` from here would promise the host a resume \
            candidate that does not exist.
            """)
    }

    /// send_bye_and_close() - now-guest-68k/src/core/wire68.c.
    ///
    /// Piecemeal since it was written, and invisible to
    /// testMessagesThisCannotCheckAreKnown for just as long: three C
    /// character literals ('"') in a helper above it inverted that
    /// scanner's quote parity, so it read every literal after them
    /// inside-out and never saw this message at all. The scanner now
    /// understands character literals; this fixture is the coverage that
    /// was missing the whole time.
    func test68KByeAsTheGuestWritesIt() throws {
        // Every code the guest can send, and all three matter: Bye.Code
        // is a closed enum on this side, so a code the host has no case
        // for fails to DECODE — the guest's parting message becomes an
        // unreadable frame at exactly the moment nobody is watching.
        let cases: [(String, Bye.Code)] = [
            (Guest68KWire.byeNormal, .normal),
            (Guest68KWire.byeProtocolError, .protocolError),
            (Guest68KWire.byeShuttingDown, .shuttingDown),
        ]
        for (json, want) in cases {
            guard case .bye(let b) = try decode(json) else {
                return XCTFail("not a bye")
            }
            XCTAssertEqual(b.code, want)
        }
    }

    /// **A guest can refuse too**, and this side has to be able to read it.
    /// The contract binds the revision gate to whoever RECEIVES a hello,
    /// so `refuse` is no longer only the host's message — and its
    /// `contract` is the SENDER's revision, which is the number a stale
    /// peer needs to be told. Decoded rather than pattern-matched because
    /// the failure this pins is the one the file family keeps producing:
    /// a message one side sends and the other cannot decode at all, which
    /// arrives as a link that simply died.
    func test68KRefuseAsTheGuestWritesIt() throws {
        for (json, reason) in [
            (Guest68KWire.refuseRevision, "contract revision 1 != 2"),
            (Guest68KWire.refuseAbsentRevision,
             "host hello states no contract revision; this guest speaks 2"),
        ] {
            guard case .refuse(let refusal) = try decode(json) else {
                return XCTFail("not a refuse")
            }
            // The literal 2 is the guest's own revision, held to the
            // contract by WireLimitsAgreementTests rather than here.
            XCTAssertEqual(refusal.contract, Contract.revision)
            XCTAssertEqual(refusal.reason, reason)
        }
    }

    // MARK: - NOW-68K's file family (the send half)

    /// The offer this guest makes when a person types `put`. Decoded
    /// here because the host's answer to it is `onAcceptOffer`, the same
    /// path the PowerPC guest's offer takes — the two guests must be
    /// indistinguishable to it, or the host grows a per-guest branch.
    ///
    /// `path` present and empty is the field that cost a dropped
    /// connection when the PowerPC guest omitted it: the host could not
    /// decode the frame at all, so the failure was not "a bad offer" but
    /// "the link died".
    func test68KFileOfferAsTheGuestWritesIt() throws {
        guard case .fileOffer(let offer) =
            try decode(Guest68KWire.sendOffer) else {
            return XCTFail("not a file.offer")
        }
        XCTAssertEqual(offer.id, 3)
        XCTAssertEqual(offer.name, "Notes")
        XCTAssertEqual(offer.path, "")
        XCTAssertEqual(offer.container, "data")
        XCTAssertEqual(offer.bytes, 1000)
        XCTAssertEqual(offer.fileType, "TEXT")
        XCTAssertEqual(offer.creator, "ttxt")
    }

    func test68KFileOfferCarriesAnUnsignedModified() throws {
        guard case .fileOffer(let offer) =
            try decode(Guest68KWire.sendOfferMacBinary) else {
            return XCTFail("not a file.offer")
        }
        XCTAssertEqual(offer.container, "macbinary")
        XCTAssertEqual(offer.modified, 2_952_790_016,
                       "a Mac date past 2^31 must not arrive negative")
    }

    /// file.begin is what actually fixes the stream: name and container
    /// are required here as well as in the offer, because the host sizes
    /// its InboundFileSink from `bytes` before a byte arrives.
    func test68KFileBeginAsTheGuestWritesIt() throws {
        guard case .fileBegin(let begin) =
            try decode(Guest68KWire.sendBegin) else {
            return XCTFail("not a file.begin")
        }
        XCTAssertEqual(begin.id, 7)
        XCTAssertEqual(begin.transfer, 9)
        XCTAssertEqual(begin.name, "Report")
        XCTAssertEqual(begin.container, "data")
        XCTAssertEqual(begin.bytes, 300)
    }

    func test68KFileEndAsTheGuestWritesIt() throws {
        guard case .fileEnd(let end) =
            try decode(Guest68KWire.sendEndOK) else {
            return XCTFail("not a file.end")
        }
        XCTAssertTrue(end.ok)
        XCTAssertEqual(end.transfer, 9)
        XCTAssertEqual(end.sendMs, 42)
        XCTAssertEqual(end.crc32, 3_419_628_326,
                       "the CRC is unsigned; half of them are above 2^31")

        guard case .fileEnd(let failed) =
            try decode(Guest68KWire.sendEndFailed) else {
            return XCTFail("not a file.end")
        }
        XCTAssertFalse(failed.ok)
        XCTAssertNil(failed.crc32,
                     "a failed transfer must not carry a checksum: absent "
                     + "means unchecked, and a number here would be read "
                     + "as corruption rather than truncation")
    }

    func test68KCaptureBeginAsTheGuestWritesIt() throws {
        guard case .captureBegin(let begin) =
            try decode(Guest68KWire.captureBegin68K) else {
            return XCTFail("not a capture.begin")
        }
        XCTAssertEqual(begin.id, 7)
        XCTAssertEqual(begin.transfer, 3)
        XCTAssertEqual(begin.width, 640)
        XCTAssertEqual(begin.height, 480)
        XCTAssertEqual(begin.depth, 8)
        XCTAssertEqual(begin.rowBytes, 640)
        XCTAssertEqual(begin.bytes, 307_968)
        XCTAssertEqual(begin.paletteBytes, 768)
        XCTAssertEqual(begin.encoding, "raw")
        XCTAssertEqual(begin.captureMs, 213)
        XCTAssertNil(begin.frame,
                     "a one-shot capture carries no frame kind; a stream "
                     + "field appearing here would make this side read a "
                     + "single capture as the first frame of a stream")
    }

    // The number and the word have to agree. A packed payload announced as
    // raw is not a decode error anywhere - it is 137,794 bytes read as the
    // first 137,794 of an expected 307,968, which presents as a torn image
    // rather than as a failure.
    func test68KCaptureBeginSaysPackbitsWhenItPacked() throws {
        guard case .captureBegin(let begin) =
            try decode(Guest68KWire.captureBeginPacked68K) else {
            return XCTFail("not a capture.begin")
        }
        XCTAssertEqual(begin.encoding, "packbits")
        XCTAssertEqual(begin.bytes, 137_794,
                       "the byte count is the PACKED length, because that "
                       + "is what the bulk lane will actually carry")
        XCTAssertEqual(begin.encodeMs, 512)
    }

    func test68KCaptureEndAsTheGuestWritesIt() throws {
        guard case .captureEnd(let end) =
            try decode(Guest68KWire.captureEndOK68K) else {
            return XCTFail("not a capture.end")
        }
        XCTAssertTrue(end.ok)
        XCTAssertEqual(end.transfer, 3)

        guard case .captureEnd(let failed) =
            try decode(Guest68KWire.captureEndFailed68K) else {
            return XCTFail("not a capture.end")
        }
        XCTAssertFalse(failed.ok)
    }

    /// exec.output, the one message whose payload is arbitrary text a human
    /// will read. The plain case is barely worth pinning; the escaped one is
    /// the whole reason this fixture exists.
    ///
    /// NOW-68K draws in MacRoman and sends what it drew, so a high byte
    /// reaches the wire as a `\uXXXX` escape from now68k_json_append_escaped
    /// — the same routine every other guest message uses for a
    /// human-supplied string, which is exactly why the exec path must not
    /// grow a second copy of it. A guest that got this wrong would corrupt
    /// the wire only when someone ran `ls` in a folder with an accented
    /// name, which is the kind of bug that reaches metal.
    func test68KExecOutputAsTheGuestWritesIt() throws {
        guard case .execOutput(let first) =
            try decode(Guest68KWire.execOutputFirst68K) else {
            return XCTFail("not an exec.output")
        }
        XCTAssertEqual(first.id, 7)
        XCTAssertEqual(first.seq, 0, "the first frame of an exec is seq 0")
        XCTAssertEqual(first.text, "Launch: SimpleText launched\r",
                       "the CR the guest's own console appends travels with "
                       + "the text; the host splits on it rather than the "
                       + "guest translating for a reader it cannot see")

        guard case .execOutput(let escaped) =
            try decode(Guest68KWire.execOutputEscaped68K) else {
            return XCTFail("not an exec.output")
        }
        XCTAssertEqual(escaped.seq, 1, "seq is contiguous, not restarted")
        XCTAssertEqual(escaped.text, "Caf\u{00E9}: 4K\r",
                       "a MacRoman e-acute arrives as the character, not as "
                       + "its escape and not as a substitution")
    }

    /// exec.result, which carries STATUS AND NOTHING ELSE. The assertion
    /// that matters is the negative one: there is no output field to read on
    /// either shape. That is what lets a guest gain streaming later without
    /// a host that already speaks this having to change.
    func test68KExecResultAsTheGuestWritesIt() throws {
        guard case .execResult(let ok) =
            try decode(Guest68KWire.execResultOK68K) else {
            return XCTFail("not an exec.result")
        }
        XCTAssertEqual(ok.id, 7)
        XCTAssertTrue(ok.ok)
        XCTAssertNil(ok.code)
        XCTAssertNil(ok.message)

        guard case .execResult(let unknown) =
            try decode(Guest68KWire.execResultUnknown68K) else {
            return XCTFail("not an exec.result")
        }
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.code, "unknown-command",
                       "the machine-readable half of the same fact the human "
                       + "already read as \"! unknown-command:\" in the text")
    }
}

/// The exact payload bytes NOW-68K puts on the control channel, derived
/// from now-guest-68k/src and kept in one place so GuestWireConformanceTests can
/// put the same strings through the contract's required-field check that
/// the whole-message scan gives every other frame.
///
/// hello and ping were produced by compiling now-guest-68k/src/core/hello.c,
/// ping.c and numfmt.c with the host cc and printing the buffer, the same
/// way now-guest-ppc/tests exercises Toolbox-free guest code. The two error shapes
/// are transcribed from the literals in send_error_reply().
enum Guest68KWire {
    /// NOW68K_APP_VERSION, read from wire68.c rather than transcribed.
    ///
    /// It was transcribed once, and every deploy then broke this file: the
    /// version has to be bumped on every build that goes to a machine
    /// (it is the only way to tell two builds apart on the wire), so a
    /// pinned copy here turned a one-line release step into a two-line one
    /// and made the fixture look like it was guarding something it was
    /// not. The version is the one field of hello that is SUPPOSED to
    /// vary; everything around it is what this fixture exists to pin.
    /// Read through the comment-stripping reader, and for the usual reason:
    /// this takes the FIRST `#define` the regex finds, so a commented-out
    /// older one above the live line —
    ///
    ///     /* #define NOW68K_APP_VERSION "0.9.0" - before the census build */
    ///     #define NOW68K_APP_VERSION "0.22"
    ///
    /// — silently re-pins every fixture below to a version no guest sends.
    /// Nothing fails, because these fixtures are consistent with themselves:
    /// the host tests would go on decoding bytes correctly, against a hello
    /// no machine has ever put on a wire. Confirmed by mutation 2026-07-31.
    static let appVersion: String = {
        guard let text = try? GateSource.guestC(
                "now-guest-68k/src/core/wire68.c"),
              let range = text.range(
                of: #"#define\s+NOW68K_APP_VERSION\s+"([^"]+)""#,
                options: .regularExpression),
              let quoted = text[range].split(separator: "\"").dropFirst().first
        else {
            // Not a fallback to a guess: a version we cannot read is a
            // fixture that would silently pass against the wrong bytes.
            fatalError("no NOW68K_APP_VERSION in now-guest-68k/src/core/wire68.c")
        }
        return String(quoted)
    }()

    /// `os` and `machine` are MEASURED now, not compiled in (contract,
    /// 2026-08-07). This fixture therefore carries one machine's answer —
    /// a Quadra 950 on 7.1.0 — where it used to carry a literal that was
    /// the same on every machine. The shape is what is being pinned; the
    /// values are an example, and `hello.c` does not choose them.
    static let hello = #"{"type":"hello","contract":2,"side":"guest","#
        + #""version":"\#(appVersion)","name":"now-68k","os":"7.1.0","#
        + #""machine":{"id":34,"model":"Macintosh Quadra 950"},"#
        + #""chunk":4096}"#


    // The file family's receive half, as handle_file_offer / put_refuse /
    // put_report_progress / put_done append them.
    static let fileAccept =
        #"{"type":"file.accept","id":3,"staging":"same-folder-temp"}"#

    static let fileRefuseExists = #"{"type":"file.refuse","id":4,"#
        + #""code":"exists","#
        + #""reason":"a file of that name is already there"}"#

    static let fileRefuseContainer = #"{"type":"file.refuse","id":5,"#
        + #""code":"io-error","#
        + #""reason":"that container is not one this guest knows"}"#

    static let fileProgress =
        #"{"type":"file.progress","id":3,"received":8192}"#

    // 3419628326 is 0xCBF43926: the CRC of the standard "123456789"
    // check vector, chosen here because it also sits above the
    // signed-long boundary and so fails visibly if the unsigned append
    // is ever lost.
    static let fileDoneOK = #"{"type":"file.done","id":3,"ok":true,"#
        + #""received":4194304,"crc32":3419628326,"#
        + #""finalization":"same-folder-rename","cleanup":"temp-renamed"}"#

    static let fileDoneCorrupt = #"{"type":"file.done","id":3,"ok":false,"#
        + #""code":"corrupt","reason":"the bytes did not check out","#
        + #""received":4194304,"cleanup":"temp-discarded"}"#

    // ---- the SEND half (n68_puttx.c) ----------------------------------
    //
    // These three are the transcription of now-guest-68k/tests/test_puttx.c's
    // pinned strings, which is the point of having them here: that test
    // proves the guest BUILDS these bytes, and these tests prove this
    // side DECODES them. Neither half proves anything on its own, and a
    // test that constructs the message it then parses proves less than
    // either (AGENTS.md).
    static let sendOffer = #"{"type":"file.offer","id":3,"name":"Notes","#
        + #""path":"","container":"data","bytes":1000,"#
        + #""fileType":"TEXT","creator":"ttxt"}"#

    // modified is a Mac epoch second past 2^31. It is here because
    // `long` is 32 bits signed on that toolchain, so this field is one
    // of the two that come out NEGATIVE if the unsigned append is ever
    // lost — and a negative date decodes fine and lands a file in 1904.
    static let sendOfferMacBinary =
        #"{"type":"file.offer","id":4,"name":"App","path":"","#
        + #""container":"macbinary","bytes":4,"fileType":"APPL","#
        + #""creator":"MACS","modified":2952790016}"#

    static let sendBegin = #"{"type":"file.begin","id":7,"transfer":9,"#
        + #""name":"Report","container":"data","bytes":300}"#

    // 3419628326 is 0xCBF43926, above the signed-long boundary for the
    // same reason fileDoneOK uses it: a lost unsigned append is a
    // checksum mismatch reported against a file that arrived perfectly.
    // NOW-68K's capture envelopes (n68_shotwire.c), transcribed from the
    // pinned strings in now-guest-68k/tests/test_shotwire.c. That test proves
    // the guest writes these bytes; this one proves this side reads them.
    // Neither proves anything alone, which is the whole point of the pair.
    static let captureBegin68K =
        #"{"type":"capture.begin","id":7,"transfer":3,"# +
        #""width":640,"height":480,"depth":8,"# +
        #""rowBytes":640,"bytes":307968,"paletteBytes":768,"# +
        #""encoding":"raw","captureMs":213,"encodeMs":0}"#

    // The staged lane packs, and says so. This field was hardcoded "raw"
    // until a real receiver decoded 137,794 packed bytes as though they
    // were 307,968 unpacked ones.
    static let captureBeginPacked68K =
        #"{"type":"capture.begin","id":7,"transfer":3,"# +
        #""width":640,"height":480,"depth":8,"# +
        #""rowBytes":640,"bytes":137794,"paletteBytes":768,"# +
        #""encoding":"packbits","captureMs":213,"encodeMs":512}"#

    static let captureEndOK68K =
        #"{"type":"capture.end","id":7,"transfer":3,"ok":true}"#

    static let captureEndFailed68K =
        #"{"type":"capture.end","id":7,"transfer":3,"ok":false}"#

    static let sendEndOK = #"{"type":"file.end","id":7,"transfer":9,"#
        + #""ok":true,"sendMs":42,"crc32":3419628326}"#

    // No crc32, and that is the assertion. A checksum over a stream that
    // stopped early is arithmetically correct about bytes nobody wanted,
    // and a receiver comparing it reports corruption instead of the
    // truncation that actually happened.
    static let sendEndFailed =
        #"{"type":"file.end","id":7,"transfer":9,"ok":false}"#

    /// handle_process_quit() — now-guest-68k/src/core/wire68.c. The drive verb's
    /// reply, and the reason this guest answers process.quit at all: a
    /// PSN names exactly one process, where the name the `quit` command
    /// takes is capped at 31 characters, need not be unique, and cannot
    /// be derived from the version a guest reports in `hello`.
    ///
    /// ok:true means DELIVERED, per the contract — not gone. There is no
    /// field here that could tell a granted quit from a declined one, so
    /// the guest does not pretend to know; a caller confirms by asking
    /// process.list again.
    static let processQuitSent =
        #"{"type":"process.result","id":12,"ok":true}"#

    /// A PSN no live process answers to. Not an error: the asked-for
    /// state already holds, and the reason says which of the refusals
    /// this was.
    static let processQuitStale = #"{"type":"process.result","id":13,"#
        + #""ok":false,"reason":"quit: that process is no longer running"}"#

    /// The refusal that protects the connection: quitting this instance
    /// would sever the reply mid-send. The host knows it before asking
    /// (isSelf on the listing) and should not have offered the button.
    static let processQuitSelf = #"{"type":"process.result","id":14,"#
        + #""ok":false,"reason":"quit: NOW will not ask itself to quit"}"#

    /// process.front's answer, from the same handle_process_drive. The
    /// contract's ok means the verb was APPLIED and no more: here that is
    /// "SetFrontProcess accepted it", not "it is frontmost". The switch is
    /// cooperative and lands when the guest yields, and process.result has
    /// no field that could say which happened — so the guest does not
    /// claim to know, and a caller that needs to re-reads process.list,
    /// where `front` marks the row.
    static let processFrontSent =
        #"{"type":"process.result","id":15,"ok":true}"#

    static let processFrontStale = #"{"type":"process.result","id":16,"#
        + #""ok":false,"reason":"front: that process is no longer running"}"#

    static let byeNormal = #"{"type":"bye","code":"normal"}"#
    static let byeProtocolError = #"{"type":"bye","code":"protocol-error"}"#
    static let byeShuttingDown = #"{"type":"bye","code":"shutting-down"}"#

    /// The guest's own refusal of a host hello it cannot speak to, as
    /// send_refuse_and_close() assembles it. Both reasons handle_host_hello
    /// can produce, because they are different findings: a revision that
    /// disagrees, and a hello that states none at all.
    static let refuseRevision = #"{"type":"refuse","contract":2,"#
        + #""reason":"contract revision 1 != 2"}"#
    static let refuseAbsentRevision = #"{"type":"refuse","contract":2,"#
        + #""reason":"host hello states no contract revision; "#
        + #"this guest speaks 2"}"#

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

    /// n68_proclist_render_ps() — now-guest-68k/src/processes/n68_proclist.c. Two shapes,
    /// because the one conditional part of the reply is the truncation
    /// note: `ps` carries no cursor, so a machine with more processes than
    /// a control frame holds says how many it dropped, in a final row.
    ///
    /// The first row ends ", self" — the same fact process.listing's
    /// isSelf carries, in the sentence a person reads. NOW-68K's own row
    /// always has it, because the guest is always one of the processes it
    /// is listing, and a person (or a handoff) needs to know which.
    static let psReply = #"{"type":"command.result","id":4,"ok":true,"#
        + #""output":{"ps":[["NOW-68K","application, 384 KB, front, self"],"#
        + #"["Finder","finder, 250 KB"]]}}"#
    static let psReplyTruncated = #"{"type":"command.result","id":5,"#
        + #""ok":true,"output":{"ps":["#
        + #"["NOW-68K","application, 384 KB, front, self"],"#
        + #"["...","6 more not shown"]]}}"#

    // ---- the BROWSE half (n68_filelist.c) ------------------------------
    //
    // Transcribed from now-guest-68k/tests/test_filelist.c's pinned strings, the
    // same way the send half's three are: that test proves the guest builds
    // these bytes, these tests prove this side decodes them and that they
    // carry the fields the contract demands.
    //
    // Note what is NOT here: `identity`. It is optional in the schema and
    // it is a precondition token for mutations NOW-68K does not serve, so
    // this guest omits it (n68_filelist.h). A host that needed it to render
    // a listing would be broken against this guest — and nothing in
    // now-host/Sources reads it.
    static let fileListingRoot =
        #"{"type":"file.listing","id":11,"path":"","entries":["#
        + #"{"name":"Projects","kind":"folder","modified":3000000000},"#
        + #"{"name":"Read Me","kind":"file","fileType":"TEXT","#
        + #""creator":"ttxt","dataBytes":4096,"rsrcBytes":0,"#
        + #""modified":3000000000},"#
        + #"{"name":"NOW-68K","kind":"file","fileType":"APPL","#
        + #""creator":"NW68","dataBytes":131072,"rsrcBytes":262144,"#
        + #""modified":3000000000}"#
        + #"],"more":true,"cursor":4,"#
        + #""root":"Macintosh HD:Desktop Folder:"}"#

    // A subfolder listing: no `root` (the caption belongs to the root
    // listing alone) and more:false, which is the page that ENDS a walk.
    static let fileListingSubfolder =
        #"{"type":"file.listing","id":12,"path":"Projects","entries":["#
        + #"{"name":"Read Me","kind":"file","fileType":"TEXT","#
        + #""creator":"ttxt","dataBytes":4096,"rsrcBytes":0,"#
        + #""modified":3000000000}],"more":false,"cursor":5}"#

    // n68_filelist_rows() rendered through n68_cmdrows_render_json() —
    // `ls`, which is to file.list what `ps` is to process.list.
    static let lsReply =
        #"{"type":"command.result","id":13,"ok":true,"output":{"ls":["#
        + #"["Share","Macintosh HD:Desktop Folder:"],"#
        + #"["Folder","(root)"],"#
        + #"["Projects","folder"],"#
        + #"["Read Me","TEXT  4 KB"],"#
        + #"["NOW-68K","APPL  128 KB + 256 KB rsrc"],"#
        + #"["...","more entries follow"]]}}"#

    // send_file_refuse() answering a file.list this guest will not serve.
    static let fileListRefuseBadPath = #"{"type":"file.refuse","id":14,"#
        + #""code":"bad-path","#
        + #""reason":"that path is not one this Mac will list"}"#

    // ---- the exec plane (wire68.c :: exec_flush / handle_exec_request) ----

    /// The first frame of `launch SimpleText`. Text is what
    /// n68_cmdresult_render_text produced, plus the CR exec_emit appends —
    /// byte for byte what the guest's own console window shows, because it
    /// is the same renderer reached through the same dispatch.
    static let execOutputFirst68K = #"{"type":"exec.output","id":7,"#
        + #""seq":0,"text":"Launch: SimpleText launched\r"}"#

    /// A second frame, carrying a MacRoman high byte. `é` is 0x8E on the
    /// guest and leaves as é; the escape is the shared one every other
    /// human-supplied string on this wire goes through.
    static let execOutputEscaped68K = #"{"type":"exec.output","id":7,"#
        + #""seq":1,"text":"Café: 4K\r"}"#

    /// Terminal status, ok. No output field — by schema, and asserted.
    static let execResultOK68K =
        #"{"type":"exec.result","id":7,"ok":true}"#

    /// Terminal status for a line whose verb this Mac does not serve. The
    /// human has already read "! unknown-command: frobnicate" in an
    /// exec.output above; this is the same fact a tool can branch on, and
    /// both come from one return value so they cannot disagree.
    static let execResultUnknown68K = #"{"type":"exec.result","id":8,"#
        + #""ok":false,"code":"unknown-command","#
        + #""message":"this Mac serves no such command"}"#

    /// Every fixture string above, for the contract check next door.
    static let all: [String] = [
        hello, pingFirst, pingLater,
        errorWithID, errorWithoutID, errorNegativeID,
        psReply, psReplyTruncated,
        fileListingRoot, fileListingSubfolder, lsReply,
        fileListRefuseBadPath,
        processQuitSent, processQuitStale, processQuitSelf,
        processFrontSent, processFrontStale,
        execOutputFirst68K, execOutputEscaped68K,
        execResultOK68K, execResultUnknown68K,
        censusReportPram68K, censusReportAbsent68K, censusReportPaged68K,
    ]

    // ---- the hardware census (n68_census.c) ---------------------------
    //
    // Transcribed from the pinned strings in
    // now-guest-68k/tests/test_census.c, which is the point of the pair:
    // that test proves the guest BUILDS these bytes and these prove this
    // side DECODES them. Neither half proves anything alone.
    //
    // Field order is the order of the appends: type, id, probe, outcome,
    // rows, more, then cursor (only when more), total, note.

    /// The probe worth most on this particular machine. `partial` because
    /// 20 of Parameter RAM's 256 bytes are what these Universal Interfaces
    /// can reach, and the note says so rather than the outcome implying it.
    static let censusReportPram68K = """
        {"type":"census.report","id":9,"probe":"pram",\
        "outcome":"partial","rows":[["valid","$A8",\
        "$A8 - Parameter RAM is being retained"],\
        ["Addressing","","24-bit now, 32-bit capable"]],\
        "more":false,"total":2,\
        "note":"20 of 256 bytes - no XPRAM trap in these headers"}
        """

    /// `absent`, which is the MACHINE saying no and is never the same
    /// answer as `refused`. A PowerBook 180c has no PC Card socket; that
    /// is a finding, and the host renders it as content.
    static let censusReportAbsent68K = """
        {"type":"census.report","id":10,"probe":"pccard",\
        "outcome":"absent","rows":[],"more":false,"total":0,\
        "note":"no PC Card sockets - PCMCIA arrived after this Mac"}
        """

    /// A page with more behind it. `cursor` counts the rows this frame
    /// carried, not the rows the probe gathered - the rows a 1024-byte
    /// control frame could not hold are deferred, never dropped.
    static let censusReportPaged68K = """
        {"type":"census.report","id":11,"probe":"drivers",\
        "outcome":"present","rows":[["Unit 3","refNum -4","Sony"]],\
        "more":true,"cursor":1,"total":24}
        """
}
