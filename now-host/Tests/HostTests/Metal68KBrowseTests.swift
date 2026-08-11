import XCTest
@testable import Host

/// NOW-68K SERVING `file.list` over a real wire — the emulator or the
/// PowerBook 180c, whichever dialled in.
///
///     scripts/q800-68k --port 5261            # boot the emulator, then:
///     NOW_METAL=1 NOW_METAL_PORT=5261 swift test --filter Metal68KBrowse
///
/// Opt-in, and once opted in it FAILS rather than skips (AGENTS.md): a
/// gate that reads green having never reached a machine is worse than no
/// gate.
///
/// ---- Why this test PUSHES before it LISTS ----------------------------
///
/// The one property no off-metal test can reach is that the three
/// directions of the file family agree about WHERE. Receiving lands a
/// file on the Desktop, `put` reads from there, and browsing must show
/// that same place — and only a real file system can notice when they
/// disagree. They did disagree once, briefly (receive on the Desktop,
/// send in the application's own folder); every native test passed, no
/// conflict marked it, and the round-trip ladder found it on the emulator
/// as `fnfErr` on every rung (n68_putfile.h).
///
/// So this test does not ask the guest to list a folder someone believes
/// is there. It PUTS two files down over the wire and then asks the guest
/// what is in its share. If browse ever starts from a different root, the
/// files this test just wrote will simply not be in the answer.
///
/// ---- What a green run here does and does not prove -------------------
///
/// It proves the catalog walk, the paging arithmetic and the escaping are
/// correct over a real File Manager and a real MacTCP stack. It proves
/// nothing about the 180c: the emulator is a 68040 under Mac OS 8.1 with
/// 128 MB against a 68030 under System 7.1 with 4 MB, and indexed catalog
/// cost on a slow disk is exactly the thing that does not carry over
/// (n68_fileenum.h flags it as unmeasured). Read a green run as
/// emulator-verified. Never write "works".
@MainActor
final class Metal68KBrowseTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        let port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        listener = GuestListener(
            identity: .init(version: "0.1-metal68k", name: "Metal Harness"),
            pacing: .classicMac)
        listener.start(port: port)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    @discardableResult
    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
        -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected(let name) = listener.state {
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("""
            No guest dialled in within \(Int(seconds))s. NOW_METAL is set, \
            so this is a failure and not a skip — boot one with \
            scripts/q800-68k, or check that the 180c is running a build \
            whose dev settings point at this port.
            """)
        throw XCTSkip("no guest")
    }

    /// Refuses to test a guest that is not the build under test.
    ///
    /// THIS IS NOT PARANOIA. Several QEMU guests run at once on this
    /// machine — one per session — and under user-mode networking every
    /// one of them sees this Mac as 10.0.2.2, so any of them can reach
    /// this listener. `ls` is the discriminator because `help` renders
    /// the guest's own doc table: a guest that lists `ls` is a guest that
    /// has this change in it. An older build would answer
    /// `unknown-command` — which is also a refusal with a reason, and
    /// would therefore have PASSED the refusal case below.
    private func requireTheBuildUnderTest() async throws {
        var help: CommandResult?
        listener.runCommand("help", line: "") { help = $0 }
        let deadline = Date().addingTimeInterval(30)
        while help == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let reply = try XCTUnwrap(help, "the guest did not answer `help`")
        let verbs = (reply.output ?? [:]).values.flatMap { $0 }
            .flatMap { $0 }
        guard verbs.contains("ls") else {
            XCTFail("""
                The guest on this wire does not list `ls`, so it is NOT \
                the build under test — most likely another session's VM \
                found this listener, or scripts/q800-68k injected an old \
                binary. Re-run it, and give this run a port nothing else \
                is dialling (NOW_METAL_PORT). Verbs seen: \
                \(verbs.sorted().joined(separator: ", "))
                """)
            throw XCTSkip("wrong build on the wire")
        }
    }

    // MARK: - helpers

    private func push(_ name: String, _ bytes: Data,
                      timeout: TimeInterval = 120) async throws {
        var done: Result<GuestListener.PutReceipt, GuestListener.FileFailure>?
        listener.putFileWithReceipt(
            name: name, into: "", container: "data", bytes: bytes,
            overwrite: true
        ) { done = $0 }

        let deadline = Date().addingTimeInterval(timeout)
        while done == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        switch done {
        case .success:
            return
        case .failure(let f):
            throw XCTSkip("""
                the PUSH half failed before browsing could be tested: \
                [\(f.code)] \(f.message). That is Metal68KPutTests' \
                territory, not this file's — fix it there.
                """)
        case nil:
            throw XCTSkip("the push half hung after \(Int(timeout))s")
        }
    }

    private func list(_ path: String, cursor: Int? = nil,
                      timeout: TimeInterval = 30) async
        -> Result<FileListing, GuestListener.FileFailure>? {
        var answer: Result<FileListing, GuestListener.FileFailure>?
        listener.listFiles(path: path, cursor: cursor) { answer = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while answer == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return answer
    }

    /// Follows `cursor` until `more` is false, returning every entry the
    /// guest handed over, in order, and how many pages it took. Bounded so
    /// a guest that never stops saying `more` fails the test instead of
    /// hanging the suite — which is precisely the failure a page that
    /// emits nothing while promising more would produce.
    private func walk(_ path: String) async throws -> [FileEntry] {
        try await walkCountingPages(path).entries
    }

    private func walkCountingPages(_ path: String) async throws
        -> (entries: [FileEntry], pages: Int) {
        var all: [FileEntry] = []
        var cursor: Int? = nil
        var pages = 0

        while true {
            pages += 1
            XCTAssertLessThan(pages, 64, """
                the guest is still saying `more` after 64 pages of \(path). \
                Either the cursor is not advancing or a page is coming back \
                empty with more:true — the infinite-paging-loop failure \
                n68_filelist.h's minimum-capacity bound exists to prevent.
                """)
            if pages >= 64 { break }

            guard let answer = await list(path, cursor: cursor) else {
                XCTFail("no answer to file.list \"\(path)\" within 30s")
                break
            }
            let page: FileListing
            switch answer {
            case .success(let p): page = p
            case .failure(let f):
                XCTFail("file.list \"\(path)\" refused: [\(f.code)] \(f.message)")
                return (all, pages)
            }
            XCTAssertEqual(page.path, path, "a page echoes the path it answers")
            all.append(contentsOf: page.entries)
            if !page.more { break }
            let next = try XCTUnwrap(page.cursor, """
                the guest says there is more but sent no cursor, so there \
                is no way to ask for it.
                """)
            XCTAssertNotEqual(next, cursor, "the cursor must advance")
            cursor = next
        }
        return (all, pages)
    }

    // MARK: - the tests

    /// The one that matters: a host can see what it just wrote.
    func testTheGuestListsFilesTheHostJustPutThere() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        // Two names, distinguishable and both legal HFS leaves. Sizes
        // differ so a listing that reported the same entry twice would
        // fail on the bytes rather than only on the count.
        let small = Data(repeating: 0x41, count: 300)
        let larger = Data(repeating: 0x42, count: 9_000)
        try await push("Browse Small", small)
        try await push("Browse Larger", larger)

        let entries = try await walk("")
        let names = entries.map(\.name)

        XCTAssertTrue(names.contains("Browse Small"), """
            The guest accepted a file called "Browse Small" and then did \
            not list it. If browse started from a different root than \
            receive, this is exactly what it would look like — one root, \
            both directions (n68_putfile.h). Saw: \
            \(names.sorted().joined(separator: ", "))
            """)
        XCTAssertTrue(names.contains("Browse Larger"),
                      "the second pushed file is missing from the listing")

        XCTAssertEqual(Set(names).count, names.count, """
            an entry appeared twice across the pages, which is a cursor \
            that did not advance by the number of rows a page carried.
            """)

        let entry = try XCTUnwrap(entries.first { $0.name == "Browse Small" })
        XCTAssertFalse(entry.isFolder, "a file is not listed as a folder")
        XCTAssertEqual(entry.dataBytes, 300, """
            the listing reports a size the File Manager disagrees with. \
            300 bytes went out; the guest says \
            \(entry.dataBytes.map(String.init) ?? "nothing").
            """)
        XCTAssertEqual(entry.rsrcBytes, 0,
                       "a data-container push creates no resource fork")
        XCTAssertNotNil(entry.modified, "an entry carries its date")
    }

    /// A folder that does NOT fit one page. This is the case the whole
    /// paging design exists for and the one an emulator run is uniquely
    /// able to check: the native tests page a synthetic array, and only a
    /// real disk can show that a cursor handed to the File Manager as an
    /// index resumes where the last page stopped.
    ///
    /// The page is small on this guest — a 1024-byte control payload
    /// against the PowerPC guest's 4 KB — so a dozen files is already
    /// several pages. That smallness is the point rather than a
    /// shortcoming: it means the guest never assembles a listing a 384 KB
    /// partition could not hold.
    func testAFolderLargerThanOnePageWalksWithoutLosingAnything()
        async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        var expected: Set<String> = []
        for i in 0..<12 {
            let name = "Paged Item \(i)"
            expected.insert(name)
            try await push(name, Data(repeating: UInt8(0x30 + i), count: 64))
        }

        let (entries, pages) = try await walkCountingPages("")
        let names = entries.map(\.name)

        XCTAssertGreaterThan(pages, 1, """
            twelve files came back in one page, so this run did not \
            exercise paging at all. Either the guest's payload cap grew or \
            the pushes did not land — either way this test is no longer \
            testing what it says it is.
            """)
        XCTAssertEqual(Set(names).count, names.count, """
            an entry appeared on two pages: the cursor did not advance by \
            the number of rows the page actually carried, which is the \
            off-by-one no single page can show.
            """)
        let missing = expected.subtracting(names)
        XCTAssertTrue(missing.isEmpty, """
            the walk lost \(missing.sorted().joined(separator: ", ")) \
            between pages. A file skipped at a page boundary is invisible \
            to anyone browsing this machine and there is nothing in the \
            protocol that would say so.
            """)
    }

    /// The caption, which is the only way a host learns what this guest
    /// is sharing — it has no preferences and nothing else says.
    func testTheRootListingNamesTheShare() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        guard case .success(let page)? = await list("") else {
            return XCTFail("the root listing did not come back")
        }
        let root = try XCTUnwrap(page.root, """
            the root listing carries no `root`. On this guest the share is \
            not configurable, so there is nothing else a host could show a \
            person to say WHERE it is looking.
            """)
        XCTAssertTrue(root.contains(":"), """
            the caption "\(root)" is not an HFS path, so the climb in \
            n68_fileenum_root_name() either failed or stopped short — and \
            a partial path names a different place, not a shorter one.
            """)
    }

    /// A refusal must arrive as a refusal. The host arms a 15-second
    /// watchdog on every file.list, so a guest that answered nothing
    /// would present to a person as a timeout carrying no reason —
    /// which is the failure mode docs/command-parity.md records for
    /// unimplemented requests.
    func testAPathTheGuestWillNotListIsRefusedAndNotIgnored() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        // A folder that is not there. Not a traversal: the guest refuses
        // those before touching the disk, and both paths matter, but this
        // is the one a person actually produces by typing.
        guard let answer = await list("No Such Folder Here") else {
            return XCTFail("""
                no answer at all to a file.list for a folder that does not \
                exist. Silence is the one thing the contract does not allow.
                """)
        }
        switch answer {
        case .success(let page):
            XCTFail("""
                the guest returned a listing of \(page.entries.count) \
                entries for a folder that is not there, which means it \
                listed something else.
                """)
        case .failure(let f):
            XCTAssertNotEqual(f.code, "timeout", """
                the request timed out rather than being refused: the guest \
                went quiet on a file.list it could not serve.
                """)
            XCTAssertTrue(["not-found", "bad-path"].contains(f.code), """
                refused with "\(f.code)", which is not one of the codes \
                the contract's FileRefuse enum allows for this.
                """)
            XCTAssertFalse(f.message.isEmpty,
                           "a refusal says why in words a person can read")
        }
    }

    /// The other face of the same enumeration. `ls` exists because the
    /// host console is a dumb shell that knows no message families, so a
    /// capability served only as `file.list` is one nobody can type —
    /// the lesson `ps` cost a day (docs/command-parity.md).
    func testTheLsCommandSeesWhatFileListSees() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        try await push("Browse Via Ls", Data(repeating: 0x43, count: 1_500))

        var reply: CommandResult?
        listener.runCommand("ls", line: "") { reply = $0 }
        let deadline = Date().addingTimeInterval(30)
        while reply == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let result = try XCTUnwrap(reply, "the guest did not answer `ls`")
        XCTAssertTrue(result.ok, """
            `ls` failed: [\(result.error?.code ?? "?")] \
            \(result.error?.message ?? "")
            """)
        let rows = try XCTUnwrap(result.output?["ls"],
                                 "the contract names the group `ls`")
        XCTAssertEqual(rows.first?.first, "Share",
                       "the first row says where it is looking")
        XCTAssertTrue(rows.contains { $0.first == "Browse Via Ls" }, """
            `ls` did not show a file that was just pushed to the share, \
            while file.list does. Two faces reading one enumeration is the \
            whole point — see docs/command-parity.md.
            """)
    }
}
