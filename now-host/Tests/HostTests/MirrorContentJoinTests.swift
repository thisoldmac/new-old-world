import XCTest
import MirrorKit
@testable import Host

/// **The join's decisions, with no wire in them.**
///
/// `MirrorContentJoin.apply(_:to:)` is deliberately separable from `join`: the
/// port rule, the cursor arithmetic and the four ways a drain ends short are
/// all decisions, and a decision that can only be exercised through a socket
/// is a decision nobody exercises.
///
/// The `CommandResult`s below are built from JSON that matches
/// `now-guest-ppc/src/content/qdtrace_json.c`'s templates — the same
/// transcription discipline as `QDTraceDecodeTests`, and for the same reason.
///
/// **Nothing here has run against a Macintosh** and neither has the plane it
/// reads. What is proven is that this host does the right thing with a reply
/// shaped the way the guest's source says it shapes them.
@MainActor
final class MirrorContentJoinTests: XCTestCase {

    private func join() -> MirrorContentJoin {
        MirrorContentJoin(listener: GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host")))
    }

    // MARK: - fixtures

    private func window(id: String, front: Bool) -> MirrorKit.Scene.Window {
        .make(id: id, app: "Finder", psn: "0.12345", title: "Untitled",
              rect: Rect(l: 10, t: 40, r: 310, b: 240), front: front,
              z: front ? 0 : 1, visible: true, controls: [])
    }

    private func scene(windows: [MirrorKit.Scene.Window]) -> MirrorKit.Scene {
        .make(version: 1, seq: 1, source: "observe", capturedAt: 0,
              screen: .init(w: 640, h: 480), apps: [], windows: windows,
              meta: .make(errors: [], errorsPresent: false))
    }

    /// A `command.result` carrying a drain, decoded the way the wire decodes
    /// one — through `CommandResult`'s own `Codable`, not hand-built.
    private func result(_ json: String) throws -> CommandResult {
        try JSONDecoder().decode(CommandResult.self, from: Data(json.utf8))
    }

    private func drainResult(ops: [String], cursor: Int = 0,
                             nextCursor: Int = 0, records: Int? = nil,
                             more: Bool = false, resync: Bool = false,
                             torn: Bool = false, busy: Bool = false,
                             lostBytes: Int = 0,
                             dropped: Int = 0) throws -> CommandResult {
        let n = records ?? ops.count
        return try result(
            "{\"type\":\"command.result\",\"id\":1,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"drain\",\"ops\":["
            + ops.joined(separator: ",")
            + "],\"cursor\":\(cursor),\"nextCursor\":\(nextCursor),"
            + "\"writeCursor\":\(nextCursor),\"pending\":0,"
            + "\"records\":\(n),\"wraps\":0,\"more\":\(more),"
            + "\"resync\":\(resync),\"torn\":\(torn),\"busy\":\(busy),"
            + "\"lostBytes\":\(lostBytes),\"dropped\":\(dropped)}}}")
    }

    private func rectOp(port: String, ticks: Int, verb: Int = 0) -> String {
        "{\"op\":\"rect\",\"port\":\"\(port)\",\"ticks\":\(ticks),"
            + "\"verb\":\(verb),\"rect\":[0,0,100,50],\"ext\":[0,0]}"
    }

    // MARK: - the port rule

    /// One port, one front window: the ops land, and they land on the FRONT
    /// window and no other.
    func testOnePortAttachesToTheFrontWindow() throws {
        let model = join()
        let before = scene(windows: [window(id: "back", front: false),
                                     window(id: "front", front: true)])
        let (after, outcome) = model.apply(
            try drainResult(ops: [rectOp(port: "0x0032f4a0", ticks: 1),
                                  rectOp(port: "0x0032f4a0", ticks: 2)],
                            nextCursor: 96),
            to: before)

        guard case .attached(let port, let ops, _) = outcome else {
            return XCTFail("expected an attach, got \(outcome)")
        }
        XCTAssertEqual(port, "0x0032f4a0")
        XCTAssertEqual(ops, 2)
        XCTAssertEqual(after.windows.first(where: \.front)?.display?.count, 2)
        XCTAssertNil(after.windows.first(where: { !$0.front })?.display,
                     "a background window was told nothing and must keep "
                     + "saying so")
        XCTAssertEqual(model.cursor, 96, "the cursor advances to nextCursor")
    }

    /// **The refusal this rule exists for.** Two ports drew; a scene window
    /// carries no port (`Scene.Window.id` is "<psn>/<title>#<z>") and there
    /// is no field common to the two planes. Attaching either set would be a
    /// coin flip presented as a mirror.
    func testTwoPortsAttachNothing() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        let (after, outcome) = model.apply(
            try drainResult(ops: [rectOp(port: "0x0032f4a0", ticks: 1),
                                  rectOp(port: "0x00330b18", ticks: 2)],
                            nextCursor: 96),
            to: before)

        guard case .ambiguous(let ports) = outcome else {
            return XCTFail("expected ambiguity, got \(outcome)")
        }
        XCTAssertEqual(ports, ["0x0032f4a0", "0x00330b18"])
        XCTAssertNil(after.windows.first?.display)
        XCTAssertEqual(after, before, "a join that cannot decide edits nothing")
        XCTAssertTrue(outcome.sentence.contains("which window"),
                      "the sentence must say WHY nothing drew")
        XCTAssertEqual(model.cursor, 96,
                       "an answered drain advances the cursor even when this "
                       + "side declines to use it — the bytes were read")
    }

    func testNoFrontWindowIsNotAskedFor() throws {
        let model = join()
        let before = scene(windows: [window(id: "back", front: false)])
        var asked = false
        model.join(into: before) { _, outcome in
            asked = true
            XCTAssertEqual(outcome, .noFrontWindow)
        }
        XCTAssertTrue(asked, "the refusal is immediate — no round trip is "
                      + "spent on a scene with nothing to draw into")
        XCTAssertEqual(model.cursor, 0)
    }

    // MARK: - the four shortnesses, kept apart

    func testTornDrainSaysSoAndAttachesNothing() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        let (after, outcome) = model.apply(
            try drainResult(ops: [], records: 4, torn: true), to: before)
        guard case .empty(let why) = outcome else {
            return XCTFail("expected empty, got \(outcome)")
        }
        XCTAssertTrue(why.contains("overtook"), why)
        XCTAssertNil(after.windows.first?.display)
    }

    func testBusyDrainIsNotAnError() throws {
        let model = join()
        let (_, outcome) = model.apply(
            try drainResult(ops: [], busy: true),
            to: scene(windows: [window(id: "front", front: true)]))
        guard case .empty(let why) = outcome else {
            return XCTFail("expected empty, got \(outcome)")
        }
        XCTAssertTrue(why.contains("Nothing was lost"), why)
    }

    /// Overrun is reported as loss, with the byte count, and never as an
    /// ordinary empty answer.
    func testResyncReportsTheBytesThatAreGone() throws {
        let model = join()
        let (_, outcome) = model.apply(
            try drainResult(ops: [], resync: true, lostBytes: 12288),
            to: scene(windows: [window(id: "front", front: true)]))
        guard case .empty(let why) = outcome else {
            return XCTFail("expected empty, got \(outcome)")
        }
        XCTAssertTrue(why.contains("12288"), why)
    }

    /// An empty drain with none of the four reasons leaves its sentence blank
    /// on purpose: that is the ONE case worth a second round trip, and `join`
    /// fills it in from a `status`.
    func testUnexplainedEmptyIsLeftForTheStatusToExplain() throws {
        let model = join()
        let (_, outcome) = model.apply(try drainResult(ops: []),
                                       to: scene(windows: [
                                           window(id: "front", front: true)]))
        XCTAssertEqual(outcome, .empty(""))
    }

    /// An overrun can arrive WITH records: the resync lands on the live end
    /// and the drain reads forward from there. The ops that survived are
    /// drawn, and the loss is said beside them rather than instead of them.
    func testResyncWithRecordsDrawsThemAndStillReportsTheLoss() throws {
        let model = join()
        let (after, outcome) = model.apply(
            try drainResult(ops: [rectOp(port: "0x1", ticks: 9)],
                            nextCursor: 200, resync: true, lostBytes: 8192),
            to: scene(windows: [window(id: "front", front: true)]))
        guard case .attached(_, let ops, let note?) = outcome else {
            return XCTFail("expected an attach with a note, got \(outcome)")
        }
        XCTAssertEqual(ops, 1)
        XCTAssertEqual(after.windows.first?.display?.count, 1)
        XCTAssertTrue(note.contains("8192"), note)
        XCTAssertTrue(note.contains("overwritten"), note)
    }

    /// A torn read delivers nothing BY CONTRACT, and this side checks rather
    /// than trusts: a record beside that flag describes a read that was
    /// discarded, and drawing it would put a half-read frame in a window.
    func testTornIsRefusedEvenIfRecordsArriveBesideIt() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        let (after, outcome) = model.apply(
            try drainResult(ops: [rectOp(port: "0x1", ticks: 1)],
                            nextCursor: 32, torn: true),
            to: before)
        guard case .empty = outcome else {
            return XCTFail("expected empty, got \(outcome)")
        }
        XCTAssertNil(after.windows.first?.display)
    }

    // MARK: - what a refusal does

    func testGuestRefusalIsForwardedInItsOwnWords() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        // `now_qdtrace_error_json`, qdtrace_json.c:138.
        let refusal = try result(
            "{\"type\":\"command.result\",\"id\":1,\"ok\":false,"
            + "\"error\":{\"code\":\"content-plane-absent\",\"message\":"
            + "\"the NOW Extension publishes no content block: not "
            + "installed, or built without P3\"}}")
        let (after, outcome) = model.apply(refusal, to: before)
        guard case .refused(let why) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("content-plane-absent"), why)
        XCTAssertTrue(why.contains("built without P3"),
                      "the guest's own sentence, not a rewrite: \(why)")
        XCTAssertEqual(after, before)
        XCTAssertEqual(model.cursor, 0, "a refused drain read no bytes")
    }

    /// An `ok: true` reply whose body is not a drain — a `status`, say — is a
    /// refusal and not an empty content plane. The two are different claims
    /// about the machine and only one of them is about the screen.
    func testAnswerThatIsNotADrainIsRefusedNotEmptied() throws {
        let model = join()
        let status = try result(
            "{\"type\":\"command.result\",\"id\":1,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\",\"plane\":"
            + "{\"format\":1,\"length\":65676,\"ringCap\":65536}}}}")
        let (_, outcome) = model.apply(
            status, to: scene(windows: [window(id: "front", front: true)]))
        guard case .refused = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
    }

    // MARK: - attributing an empty drain

    /// **The A5 gap, as the sentence a person sees.** `active.a5` of zero
    /// means nothing is armed, and this host cannot arm it: `qdtrace start`
    /// requires an A5 and no NOW command reports one.
    func testUnarmedPlaneIsAttributedToTheArmGap() throws {
        // `now_qdtrace_status_json`, qdtrace_json.c:207.
        let status = try result(
            "{\"type\":\"command.result\",\"id\":2,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\",\"active\":"
            + "{\"a5\":\"0x00000000\",\"mode\":\"off\",\"hookedPorts\":0}}}}")
        XCTAssertEqual(MirrorContentJoin.attribution(status),
                       MirrorContentJoin.armGap)
        XCTAssertTrue(MirrorContentJoin.armGap.contains("no NOW command "
                                                        + "reports an A5"))
    }

    /// Count mode counts and records nothing, by design. An empty drain under
    /// it is correct behaviour and must not read as a fault.
    func testCountModeIsNamedRatherThanReportedAsAFault() throws {
        let status = try result(
            "{\"type\":\"command.result\",\"id\":2,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\",\"active\":"
            + "{\"a5\":\"0x0032a000\",\"mode\":\"count\","
            + "\"hookedPorts\":2}}}}")
        let why = MirrorContentJoin.attribution(status)
        XCTAssertTrue(why.contains("counted but not recorded"), why)
        XCTAssertNotEqual(why, MirrorContentJoin.armGap)
    }

    func testArmedAndIdleIsSaidPlainly() throws {
        let status = try result(
            "{\"type\":\"command.result\",\"id\":2,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\",\"active\":"
            + "{\"a5\":\"0x0032a000\",\"mode\":\"record\","
            + "\"hookedPorts\":2}}}}")
        let why = MirrorContentJoin.attribution(status)
        XCTAssertTrue(why.contains("0x0032a000"), why)
        XCTAssertTrue(why.contains("nothing has drawn"), why)
    }

    /// The two errors are not symmetric. An A5 this side cannot parse reads
    /// as UNARMED, because calling it armed would report "the plane is armed
    /// and nothing drew" about a machine that never said so — and would hide
    /// the one gap this join actually has.
    func testAnUnparseableA5ReadsAsUnarmed() throws {
        let status = try result(
            "{\"type\":\"command.result\",\"id\":2,\"ok\":true,"
            + "\"output\":{\"qdtrace\":{\"cmd\":\"status\",\"active\":"
            + "{\"a5\":\"nonsense\",\"mode\":\"record\","
            + "\"hookedPorts\":0}}}}")
        XCTAssertEqual(MirrorContentJoin.attribution(status),
                       MirrorContentJoin.armGap)
    }

    /// A status that did not answer must not be read as "nothing is armed" —
    /// that would report the arm gap on a machine that never said so.
    func testUnansweredStatusSaysItCouldNotFindOut() throws {
        let refused = try result(
            "{\"type\":\"command.result\",\"id\":2,\"ok\":false,"
            + "\"error\":{\"code\":\"timeout\",\"message\":\"no answer\"}}")
        let why = MirrorContentJoin.attribution(refused)
        XCTAssertTrue(why.contains("did not answer"), why)
        XCTAssertNotEqual(why, MirrorContentJoin.armGap)
    }

    // MARK: - the note beside a successful attach

    /// Loss, truncation and undrawn families are said out loud, and the two
    /// kinds of loss stay two.
    func testNoteNamesLossTruncationAndUndrawnFamilies() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        let ops = [
            rectOp(port: "0x1", ticks: 1),
            "{\"op\":\"arc\",\"port\":\"0x1\",\"ticks\":2,\"verb\":0,"
                + "\"rect\":[0,0,10,10],\"ext\":[0,90]}",
            "{\"op\":\"text\",\"port\":\"0x1\",\"ticks\":3,\"pen\":[2,10],"
                + "\"font\":3,\"size\":9,\"face\":0,\"len\":64,"
                + "\"fullLen\":200,\"trunc\":true,\"text\":\"aa\"}",
            "{\"op\":\"comment\",\"port\":\"0x1\",\"ticks\":4,"
                + "\"detail\":false}"
        ]
        let (_, outcome) = model.apply(
            try drainResult(ops: ops, nextCursor: 128, more: true,
                            dropped: 3),
            to: before)
        guard case .attached(_, _, let note?) = outcome else {
            return XCTFail("expected an attach with a note, got \(outcome)")
        }
        XCTAssertTrue(note.contains("more operations are waiting"), note)
        XCTAssertTrue(note.contains("could not fit 3"), note)
        XCTAssertTrue(note.contains("without geometry"), note)
        XCTAssertTrue(note.contains("text run was"), note)
        XCTAssertTrue(note.contains("arc"), note)
    }

    /// A note that always fires is a note nobody reads.
    func testACleanDrainCarriesNoNote() throws {
        let model = join()
        let (_, outcome) = model.apply(
            try drainResult(ops: [rectOp(port: "0x1", ticks: 1)],
                            nextCursor: 32),
            to: scene(windows: [window(id: "front", front: true)]))
        guard case .attached(_, _, let note) = outcome else {
            return XCTFail("expected an attach, got \(outcome)")
        }
        XCTAssertNil(note)
    }

    // MARK: - the cursor

    /// Successive joins read FORWARD. A cursor that did not advance would
    /// re-read the same records into the same window every press.
    func testTheCursorCarriesBetweenJoins() throws {
        let model = join()
        let before = scene(windows: [window(id: "front", front: true)])
        _ = model.apply(try drainResult(ops: [rectOp(port: "0x1", ticks: 1)],
                                        cursor: 0, nextCursor: 32),
                        to: before)
        XCTAssertEqual(model.cursor, 32)
        _ = model.apply(try drainResult(ops: [rectOp(port: "0x1", ticks: 2)],
                                        cursor: 32, nextCursor: 64),
                        to: before)
        XCTAssertEqual(model.cursor, 64)
    }

    /// A ring cursor is a byte count into ONE machine's ring. Carried to the
    /// next Mac it reads as a colossal overrun or as bytes never written.
    func testAChangeOfGuestResetsTheCursor() throws {
        let model = join()
        _ = model.apply(try drainResult(ops: [rectOp(port: "0x1", ticks: 1)],
                                        nextCursor: 4096),
                        to: scene(windows: [window(id: "front", front: true)]))
        XCTAssertEqual(model.cursor, 4096)
        model.guestChanged()
        XCTAssertEqual(model.cursor, 0)
    }
}
