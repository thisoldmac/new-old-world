import XCTest
@testable import Host

/// The machine-busy guard's own tests, and they run in the ordinary
/// suite with no metal and no sockets.
///
/// That is deliberate. The guard's job is to fire on a day when a
/// PowerBook is contended, which is exactly the day nobody is going to
/// notice that it silently stopped parsing `lsof`. So the parts that can
/// be wrong without anything crashing — the field-mode parse, the
/// leftover names — are pinned here against text and names taken from
/// real output and from the code that writes them.
///
/// What this file cannot cover is the two guards' live half: whether
/// `/usr/sbin/lsof` is where it is expected and answers what it answered
/// yesterday. `testTheLiveQueryAnswersAtAll` covers the part of that
/// which needs no contention to observe.
final class MetalMachineGuardTests: XCTestCase {

    // MARK: - parsing what lsof actually prints

    /// Verbatim `lsof -nP -FpcnT -iTCP:5252` output shape: a `p` opens a
    /// process, `c` names it, and each `f` opens a descriptor whose `n`
    /// and `TST=` follow.
    private let twoHolders = """
        p4711
        cxctest
        f9
        n*:5252
        TST=LISTEN
        TQR=0
        TQS=0
        p832
        cpython3.11
        f7
        n10.91.5.15:63194->10.91.5.180:5252
        TST=ESTABLISHED
        TQR=0
        TQS=131072
        """

    func testItReadsProcessCommandEndpointAndState() {
        let held = MetalMachineGuard.parse(twoHolders, excluding: 1)
        XCTAssertEqual(held, [
            .init(pid: 4711, command: "xctest",
                  endpoint: "*:5252", state: "LISTEN"),
            .init(pid: 832, command: "python3.11",
                  endpoint: "10.91.5.15:63194->10.91.5.180:5252",
                  state: "ESTABLISHED"),
        ])
    }

    /// The one exclusion that has to work, because this process is
    /// always in the answer once its own listener is up — and a guard
    /// that reported itself as contention would fail every metal run
    /// rather than none, which is the same uselessness facing the other
    /// way.
    func testItExcludesTheRunningProcess() {
        let held = MetalMachineGuard.parse(twoHolders, excluding: 4711)
        XCTAssertEqual(held.map(\.pid), [832],
                       "the harness's own socket is not contention")
    }

    /// A process holding the port on several descriptors — IPv4 and IPv6
    /// for one listener is the common case — is several holders, and all
    /// of them must survive the parse. The `f` line is what closes the
    /// previous descriptor, so dropping it would silently collapse them
    /// to one and understate what is on the port.
    func testEachDescriptorIsItsOwnHolder() {
        let both = """
            p672
            cControlCenter
            f9
            n*:5250
            TST=LISTEN
            f10
            n[::1]:5250
            TST=LISTEN
            """
        let held = MetalMachineGuard.parse(both, excluding: 1)
        XCTAssertEqual(held.count, 2)
        XCTAssertEqual(held.map(\.endpoint), ["*:5250", "[::1]:5250"])
        XCTAssertEqual(Set(held.map(\.command)), ["ControlCenter"],
                       "the command name carries across descriptors")
    }

    /// A command name with a space in it. This is the reason the guard
    /// reads field mode instead of the table: in the table, "Google
    /// Chrome H" moves every later column and the PID is read out of the
    /// wrong one. Here it is one tagged line and cannot.
    func testACommandNameWithASpaceSurvives() {
        let spaced = """
            p91
            cGoogle Chrome Helper
            f42
            n*:5251
            TST=LISTEN
            """
        XCTAssertEqual(MetalMachineGuard.parse(spaced, excluding: 1),
                       [.init(pid: 91, command: "Google Chrome Helper",
                              endpoint: "*:5251", state: "LISTEN")])
    }

    /// lsof exits non-zero and prints nothing when no socket matches,
    /// which is the ordinary answer for a free port.
    func testNothingMatchedIsNoHolders() {
        XCTAssertEqual(MetalMachineGuard.parse("", excluding: 1), [])
    }

    /// A descriptor lsof gave no `TST=` for is still a holder. Dropping
    /// it because the state was missing would mean a port held by
    /// something whose state lsof could not read reads as free — the
    /// exact failure this guard exists to prevent, produced by the guard.
    func testAStatelessDescriptorIsStillAHolder() {
        let stateless = """
            p5
            cnc
            f3
            n*:5253
            """
        XCTAssertEqual(MetalMachineGuard.parse(stateless, excluding: 1),
                       [.init(pid: 5, command: "nc",
                              endpoint: "*:5253", state: "")])
    }

    /// The `TQS=` line is a queue depth and shares its first letter with
    /// the state. Reading it as one would report every socket's state as
    /// `Q=131072`.
    func testQueueDepthsAreNotMistakenForState() {
        let held = MetalMachineGuard.parse(twoHolders, excluding: 1)
        XCTAssertEqual(held.last?.state, "ESTABLISHED")
    }

    // MARK: - whose side of the socket the port is on

    /// The false positive that fired against a live emulator the first
    /// time this guard ran, and would have failed the second test of
    /// every suite: under QEMU the emulator process connects OUT to the
    /// harness port, so the guest dialling in perfectly is in every
    /// answer lsof gives for that port.
    func testAGuestDiallingInIsNotAPortHolder() {
        let dialledIn = MetalMachineGuard.Holder(
            pid: 33934, command: "qemu-system-m68k",
            endpoint: "127.0.0.1:50095->127.0.0.1:5252",
            state: "ESTABLISHED")
        XCTAssertFalse(dialledIn.holdsLocally(5252),
                       "the port is on the far side — this is the guest "
                       + "reaching a listener, not a second listener")
    }

    /// The two that ARE contention: somebody else listening on the port,
    /// and somebody else already answering a guest on it.
    func testListeningAndAnsweringBothCount() {
        XCTAssertTrue(
            MetalMachineGuard.Holder(pid: 1, command: "xctest",
                                     endpoint: "*:5252", state: "LISTEN")
                .holdsLocally(5252))
        XCTAssertTrue(
            MetalMachineGuard.Holder(
                pid: 1, command: "xctest",
                endpoint: "10.91.5.15:5252->10.91.5.180:1401",
                state: "ESTABLISHED").holdsLocally(5252),
            "another session's harness already has the machine")
        XCTAssertTrue(
            MetalMachineGuard.Holder(pid: 1, command: "xctest",
                                     endpoint: "[::1]:5252", state: "LISTEN")
                .holdsLocally(5252),
            "IPv6 listeners hold the port too")
    }

    /// The colon is what anchors the match. An ephemeral local port of
    /// 15252 would otherwise read as 5252 and stop a run for nothing.
    func testAnEphemeralPortEndingInTheSameDigitsIsNotAMatch() {
        XCTAssertFalse(
            MetalMachineGuard.Holder(pid: 1, command: "curl",
                                     endpoint: "127.0.0.1:15252->1.2.3.4:443",
                                     state: "ESTABLISHED").holdsLocally(5252))
    }

    // MARK: - what counts as talking to a machine

    /// `lsof -iTCP@<addr>` returns sockets merely BOUND to the address as
    /// well as conversations with it. Pointing `NOW_METAL_MACHINE` at
    /// 127.0.0.1 for a forwarded emulator then produced a page of
    /// unrelated local daemons as evidence of contention — watched,
    /// 2026-07-26. A guard whose failures are noise gets routed around.
    func testAListenerBoundToTheAddressIsNotTalkingToIt() {
        XCTAssertFalse(
            MetalMachineGuard.Holder(pid: 910, command: "figma_agent",
                                     endpoint: "127.0.0.1:44950",
                                     state: "LISTEN")
                .talksTo("127.0.0.1"))
    }

    func testAConversationWithTheMachineCounts() {
        XCTAssertTrue(
            MetalMachineGuard.Holder(
                pid: 832, command: "python3.11",
                endpoint: "10.91.5.15:63194->10.91.5.180:21",
                state: "ESTABLISHED").talksTo("10.91.5.180"),
            "an FTP deploy in flight is the case this exists for")
    }

    /// The address on OUR side of the socket is not the machine being
    /// talked to. It matters for a forwarded emulator, where both halves
    /// are 127.0.0.1 and only the far one means anything.
    func testTheAddressOnTheNearSideDoesNotCount() {
        XCTAssertFalse(
            MetalMachineGuard.Holder(
                pid: 1, command: "x",
                endpoint: "10.91.5.180:5252->10.91.5.15:1401",
                state: "ESTABLISHED").talksTo("10.91.5.180"))
    }

    /// The colon anchors this one too: 10.91.5.18 must not match a
    /// conversation with 10.91.5.180.
    func testAnAddressThatIsAPrefixOfAnotherIsNotAMatch() {
        XCTAssertFalse(
            MetalMachineGuard.Holder(
                pid: 1, command: "x",
                endpoint: "10.91.5.15:1000->10.91.5.180:21",
                state: "ESTABLISHED").talksTo("10.91.5.18"))
    }

    // MARK: - the live half

    /// Not a contention test — it is the "is the tool still there" test.
    /// Everything above proves the parse; this proves the thing being
    /// parsed can be obtained at all, so a guard that has quietly stopped
    /// running lsof shows up here rather than as a green metal run.
    func testTheLiveQueryAnswersAtAll() throws {
        // Port 0 is never bound, so the answer is a definite empty one.
        let held = try XCTUnwrap(
            MetalMachineGuard.holders(ofPort: 0),
            "/usr/sbin/lsof could not be run — the guard cannot see this "
            + "Mac's sockets, so no metal run from here is attributable.")
        XCTAssertEqual(held, [], "nothing holds port 0")
    }

    // MARK: - leftovers

    /// Every name here is written by code in this repository, and the
    /// reference is in the guard's comment: if one of these prefixes
    /// changes, this test is where it is noticed.
    func testItRecognisesEachStagingAndLadderName() {
        for name in [".now-8B0C-4E11.part",           // InboundFileSink
                     "NOW incoming a1b2c3d4",         // n68_putfile.c
                     "N68 4194304",                   // the push ladder
                     "N68 mb 12000-200000",           // the MacBinary rungs
                     "RT4194304"] {                   // the round trip
            XCTAssertTrue(MetalMachineGuard.looksLikeTransferLeftover(name),
                          "\(name) is a transfer leftover")
        }
    }

    /// The guard prints a warning naming these files, so a false positive
    /// spends a human's attention on their own document. `RT` alone, or
    /// `RTFReader`, is not a ladder rung.
    func testOrdinaryFilesAreNotLeftovers() {
        for name in ["Report.rtf", "RT", "RTFReader", "notes.txt",
                     "now-guest.bin", "NOW incoming"] {
            XCTAssertFalse(MetalMachineGuard.looksLikeTransferLeftover(name),
                           "\(name) is somebody's file, not a leftover")
        }
    }

    /// AGE IS THE SIGNAL, and it is the whole reason this check is worth
    /// having: a ladder rung from last week says the suite has been run,
    /// and one modified ninety seconds ago says it is being run RIGHT
    /// NOW, by somebody else.
    func testOnlyRecentlyTouchedLeftoversAreReported() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guardtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        func write(_ name: String, agedBy seconds: TimeInterval) throws {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-seconds)],
                ofItemAtPath: url.path)
        }
        try write("N68 4194304", agedBy: 90)
        try write("RT1048576", agedBy: 7 * 24 * 3600)
        try write("Michelle's notes.txt", agedBy: 30)

        XCTAssertEqual(
            MetalMachineGuard.recentLeftovers(in: directory, within: 600,
                                              now: now),
            ["N68 4194304"],
            "a week-old rung is history; a ninety-second-old one is a "
            + "second session mid-ladder")
    }

    func testAMissingDirectoryIsNotAnAlarm() {
        XCTAssertEqual(
            MetalMachineGuard.recentLeftovers(
                in: URL(fileURLWithPath: "/no/such/share")),
            [],
            "a share root that does not exist yet is the first-run case")
    }
}
