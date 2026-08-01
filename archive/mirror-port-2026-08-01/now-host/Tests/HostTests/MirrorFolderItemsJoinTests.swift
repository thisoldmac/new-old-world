import XCTest
import MirrorKit
@testable import Host

/// **The draw half's decisions, with no wire in them.**
///
/// `MirrorFolderItemsJoin.apply(_:to:)` is deliberately separable from
/// `join` the way `MirrorContentJoin.apply` is — the title match and the
/// duplicate-title rule are decisions, and a decision that can only be
/// exercised through a socket is a decision nobody exercises.
@MainActor
final class MirrorFolderItemsJoinTests: XCTestCase {

    private func join() -> MirrorFolderItemsJoin {
        MirrorFolderItemsJoin(listener: GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host")))
    }

    // MARK: - fixtures

    /// A Finder folder window, the same measured geometry
    /// `FinderItemsTests.folderWindow` uses, so a `clickPoint` assertion
    /// elsewhere in this lane reads against one set of numbers.
    private func folderWindow(id: String = "0.1/TimBotTu#0",
                             title: String = "TimBotTu") -> MirrorKit.Scene.Window {
        .make(id: id, app: "Finder", psn: "0.1", title: title,
             rect: Rect(l: 13, t: 47 - SceneBuilder.titleBarHeight,
                        r: 417, b: 265),
             front: true, z: 0, visible: true, controls: [])
    }

    private func scene(windows: [MirrorKit.Scene.Window]) -> MirrorKit.Scene {
        .make(version: 1, seq: 1, source: "observe", capturedAt: 0,
             screen: .init(w: 640, h: 480), apps: [], windows: windows,
             meta: .make(errors: [], errorsPresent: false))
    }

    /// A `script` reply carrying the Finder's own record stream in its
    /// `output` row — the shape `input_cmds.c:437`'s `reply_rows` emits.
    private func scriptResult(_ raw: String) -> CommandResult {
        CommandResult(id: 1, ok: true,
                     output: ["script": [
                        ["output", raw],
                        ["osaErr", "0"],
                        ["truncated", "false"],
                        ["timeoutMs", "15000"],
                        ["wrapped", "false"],
                     ]])
    }

    // MARK: - the ordinary case

    func testJoinsItemsOntoTheMatchingWindowByTitle() {
        let win = folderWindow()
        let before = scene(windows: [win])
        let reply = scriptResult(
            "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,25;;\"")
        let (joined, outcome) = join().apply(reply, to: before)
        guard case .joined(let windows, let items) = outcome else {
            return XCTFail("expected .joined, got \(outcome)")
        }
        XCTAssertEqual(windows, 1)
        XCTAssertEqual(items, 1)
        XCTAssertEqual(joined.windows[0].items?.map(\.name), ["tbt-worker"])
        XCTAssertEqual(joined.windows[0].items?[0].x, 53)
        XCTAssertEqual(joined.windows[0].items?[0].y, 25)
    }

    /// A window this join has nothing to say about — not Finder, or the
    /// desktop backdrop — is left exactly as it arrived.
    func testLeavesNonFolderWindowsUntouched() {
        var dialog = folderWindow(id: "0.9/Preferences#0", title: "Preferences")
        dialog.app = "SimpleText"
        let before = scene(windows: [dialog])
        let reply = scriptResult("\"\"")
        let (joined, outcome) = join().apply(reply, to: before)
        guard case .joined(let windows, let items) = outcome else {
            return XCTFail("expected .joined, got \(outcome)")
        }
        XCTAssertEqual(windows, 0)
        XCTAssertEqual(items, 0)
        XCTAssertNil(joined.windows[0].items)
    }

    /// Two open windows sharing a title are a Finder limit this layer
    /// inherits, not one it papers over: `window "X"` cannot pick one out of
    /// two either, so NEITHER gets items, and the title is recorded rather
    /// than one report winning by accident of ordering.
    func testAmbiguousTitleGetsNoItemsAndIsRecorded() {
        let a = folderWindow(id: "0.1/TimBotTu#0", title: "TimBotTu")
        let b = folderWindow(id: "0.1/TimBotTu#1", title: "TimBotTu")
        let before = scene(windows: [a, b])
        let reply = scriptResult(
            "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|one|1,2;;"
                + "W|TimBotTu|Macintosh HD:Other:TimBotTu:;;I|two|3,4;;\"")
        let join = self.join()
        let (joined, outcome) = join.apply(reply, to: before)
        guard case .joined(let windows, let items) = outcome else {
            return XCTFail("expected .joined, got \(outcome)")
        }
        XCTAssertEqual(windows, 0, "neither ambiguous window is joined")
        XCTAssertEqual(items, 0)
        XCTAssertNil(joined.windows[0].items)
        XCTAssertNil(joined.windows[1].items)
        XCTAssertEqual(join.lastAmbiguous, ["TimBotTu"])
    }

    func testRefusalIsForwardedInTheGuestsOwnWords() {
        let before = scene(windows: [folderWindow()])
        let refusal = CommandResult(
            id: 1, ok: false, output: nil,
            error: .init(code: "busy", message: "the Mac is elsewhere"))
        let (_, outcome) = join().apply(refusal, to: before)
        XCTAssertEqual(outcome, .refused("the Mac is elsewhere [busy]"))
    }

    func testUnreadableReplyIsUnavailableRatherThanCrashing() {
        let before = scene(windows: [folderWindow()])
        let odd = CommandResult(id: 1, ok: true, output: ["script": []])
        let (_, outcome) = join().apply(odd, to: before)
        guard case .unavailable = outcome else {
            return XCTFail("expected .unavailable, got \(outcome)")
        }
    }

    /// A scene with no Finder folder window asks the Mac nothing — proven
    /// through `join(into:)` rather than `apply`, since this is the one path
    /// that short-circuits before the wire.
    func testNoFolderWindowsJoinsNothingAndAsksNothing() {
        var dialog = folderWindow()
        dialog.app = "SimpleText"
        let before = scene(windows: [dialog])
        let expectation = expectation(description: "completion fires")
        join().join(into: before) { _, outcome in
            guard case .joined(let windows, let items) = outcome else {
                return XCTFail("expected .joined, got \(outcome)")
            }
            XCTAssertEqual(windows, 0)
            XCTAssertEqual(items, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - a real Finder, not a transcription

    /// **Captured verbatim from a live guest**, 2026-08-01, `mac99-os91`
    /// (QEMU `mac99`, Mac OS 9.1), build `67368e24beb2 2026-08-01T08:58:22Z` —
    /// the emulator-validation wave's `script` reply for two open Finder
    /// windows (`Macintosh HD`, then `TBTRunner` opened inside it), run
    /// through the exact `FinderItems.windowsScript()` body the host sends.
    /// Everything before this test was transcribed from `FinderItems`'s own
    /// measured numbers; this string is the first capture from a Mac that
    /// was never told what the parser expected. It matches
    /// `FinderItems.parse`'s assumed shape byte for byte — quote-wrapped
    /// `W|`/`I|` records, `;;`-terminated — so this is corroboration, not a
    /// fix: see `docs/open-issues.md`, "Folder windows are modelled" entry.
    private static let realFinderScriptReply =
        "\"W|Macintosh HD|Macintosh HD:;;I|System Folder|34,25;;" +
        "I|TimBotTu|290,89;;I|Applications (Mac OS 9)|162,25;;" +
        "I|Documents|290,25;;I|Late Breaking News|34,89;;" +
        "I|Rumpus PRO 2.0|162,89;;I|TBT|34,153;;" +
        "I|TBT-paced-dev|162,153;;I|TBT-sndbuf-dev|290,153;;" +
        "I|TBTRunner|34,217;;W|TBTRunner|Macintosh HD:TBTRunner:;;" +
        "I|runner.debug|19,25;;I|runner.port|147,25;;\""

    func testParsesARealFinderReplyVerbatim() {
        let reports = MirrorKit.FinderItems.parse(Self.realFinderScriptReply)
        XCTAssertEqual(reports.count, 2)

        XCTAssertEqual(reports[0].title, "Macintosh HD")
        XCTAssertEqual(reports[0].path, "Macintosh HD:")
        XCTAssertEqual(reports[0].items.count, 10)
        XCTAssertEqual(reports[0].items.first?.name, "System Folder")
        XCTAssertEqual(reports[0].items.first?.x, 34)
        XCTAssertEqual(reports[0].items.first?.y, 25)
        XCTAssertEqual(reports[0].items.last?.name, "TBTRunner")
        XCTAssertEqual(reports[0].items.last?.x, 34)
        XCTAssertEqual(reports[0].items.last?.y, 217)
        XCTAssertFalse(reports[0].truncated)

        XCTAssertEqual(reports[1].title, "TBTRunner")
        XCTAssertEqual(reports[1].path, "Macintosh HD:TBTRunner:")
        XCTAssertEqual(reports[1].items.map(\.name), ["runner.debug", "runner.port"])
        XCTAssertEqual(reports[1].items.map(\.x), [19, 147])
        XCTAssertEqual(reports[1].items.map(\.y), [25, 25])
    }

    /// Feeding the real capture through the same `join` path
    /// `testJoinsItemsOntoTheMatchingWindowByTitle` exercises with a
    /// transcribed fixture — the join logic does not care where the text
    /// came from, and this is the proof.
    func testJoinsARealFinderReplyOntoAMatchingScene() {
        let win = folderWindow(id: "0.29949953/Macintosh HD#0",
                               title: "Macintosh HD")
        let before = scene(windows: [win])
        let reply = scriptResult(Self.realFinderScriptReply)
        let (joined, outcome) = join().apply(reply, to: before)
        guard case .joined(let windows, let items) = outcome else {
            return XCTFail("expected .joined, got \(outcome)")
        }
        XCTAssertEqual(windows, 1)
        XCTAssertEqual(items, 10)
        XCTAssertEqual(joined.windows[0].items?.map(\.name).first, "System Folder")
        XCTAssertEqual(joined.windows[0].items?[0].x, 34)
        XCTAssertEqual(joined.windows[0].items?[0].y, 25)
    }
}
