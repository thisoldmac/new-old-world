import XCTest
import MirrorKit
@testable import Host

/// **The aim discipline, proven rather than asserted.**
///
/// The one rule `MirrorFolderItemsAim` exists to keep is that it never reads
/// `Scene.Window.items` — every position it acts on comes from a `script`
/// call it makes itself. Every test below sets the CACHE (`chrome.items`,
/// where passed) and the FRESH walk (the injected `ask`'s answer) to
/// DIFFERENT and sometimes CONTRADICTORY stories, and asserts on the fresh
/// one. A version of this file that only tested with the two in agreement
/// would pass just as well against the bug it exists to catch.
@MainActor
final class MirrorFolderItemsAimTests: XCTestCase {

    // MARK: - fixtures

    /// The measured geometry `FinderItemsTests` uses, so "in view" and "out
    /// of view" below mean the same thing they mean there.
    private func chrome(items: [MirrorKit.Scene.DesktopItem]? = nil)
        -> MirrorKit.Scene.Window {
        .make(id: "0.1/TimBotTu#0", app: "Finder", psn: "0.1",
             title: "TimBotTu",
             rect: Rect(l: 13, t: 47 - SceneBuilder.titleBarHeight,
                        r: 417, b: 265),
             front: true, z: 0, visible: true, controls: [], items: items)
    }

    private func scriptResult(_ raw: String) -> CommandResult {
        CommandResult(id: 1, ok: true,
                     output: ["script": [["output", raw]]])
    }

    private func aesendOK() -> CommandResult {
        CommandResult(id: 2, ok: true, output: ["aesend": [["sent", "true"]]])
    }

    /// Records every call the aim makes, in order, and answers each from a
    /// queue — so a test can tell a "script" (the fresh walk) apart from the
    /// "aesend" (the dispatch) without caring which the aim asks first.
    private func aim(answering results: [CommandResult],
                     seen: @escaping ([String: [String: String]]) -> Void = { _ in })
        -> MirrorFolderItemsAim {
        var queue = results
        var calls: [String: [String: String]] = [:]
        return MirrorFolderItemsAim { name, args in
            calls[name] = args
            seen(calls)
            guard !queue.isEmpty else {
                XCTFail("asked for more than \(results.count) commands")
                return CommandResult(id: 0, ok: false, error: .init(
                    code: "test-exhausted", message: "no more answers queued"))
            }
            return queue.removeFirst()
        }
    }

    // MARK: - the ordinary case

    func testDispatchesAnOdocAddressedAtTheFindersPSNWithTheComposedPath() async {
        var seenArgs: [String: [String: String]] = [:]
        let aim = aim(answering: [
            scriptResult(
                "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,25;;\""),
            aesendOK(),
        ], seen: { seenArgs = $0 })
        let outcome = await aim.open(item: "tbt-worker", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome())
        guard case .dispatched = outcome else {
            return XCTFail("expected .dispatched, got \(outcome)")
        }
        XCTAssertEqual(seenArgs["aesend"]?["event"], "odoc")
        XCTAssertEqual(seenArgs["aesend"]?["serialHi"], "0")
        XCTAssertEqual(seenArgs["aesend"]?["serialLo"], "512")
        XCTAssertEqual(seenArgs["aesend"]?["path"],
                       "Macintosh HD:TimBotTu:tbt-worker",
                       "the folder path already ends in a colon; the item "
                           + "name is appended, not a second one inserted")
    }

    // MARK: - what force-refresh is FOR

    /// **The mutation-watch test.** The cache says the item is safely inside
    /// the icon field; the FRESH walk says the Finder has scrolled it out of
    /// it since. If this type ever reads `chrome.items` for the position
    /// instead of the walk it just ran, this assertion flips from `.refused`
    /// to `.dispatched` — which is why it is spelled as an equality on the
    /// whole outcome rather than a looser "is not dispatched".
    func testFreshOutOfViewPositionRefusesEvenWhenTheCacheSaysInView() async {
        let cachedInView = MirrorKit.Scene.DesktopItem.make(
            name: "tbt-worker", kind: "file", x: 53, y: 25, placed: true,
            alias: false, invisible: false)
        let aim = aim(answering: [
            // "scrolled-away" from FinderItemsTests: above the fold entirely.
            scriptResult(
                "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,-103;;\""),
        ])
        let outcome = await aim.open(
            item: "tbt-worker", windowTitle: "TimBotTu", finderPSN: "0.512",
            chrome: chrome(items: [cachedInView]))
        guard case .refused(let sentence) = outcome else {
            return XCTFail("expected .refused (scrolled out on the FRESH "
                           + "walk), got \(outcome) — the aim read the "
                           + "cached in-view position instead of its own "
                           + "walk")
        }
        XCTAssertTrue(sentence.contains("scrolled out"))
    }

    /// The inverse: an empty or absent cache does not stop the aim, because
    /// nothing here is read from it. A version that force-unwrapped
    /// `chrome.items` would crash this test instead of passing it.
    func testDispatchesEvenWhenTheCacheHasNothingForThisWindow() async {
        let aim = aim(answering: [
            scriptResult(
                "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,25;;\""),
            aesendOK(),
        ])
        let outcome = await aim.open(item: "tbt-worker", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome(items: nil))
        guard case .dispatched = outcome else {
            return XCTFail("expected .dispatched, got \(outcome)")
        }
    }

    // MARK: - refusals

    func testItemAbsentFromTheFreshWalkIsUnavailable() async {
        let aim = aim(answering: [
            scriptResult("\"W|TimBotTu|Macintosh HD:TimBotTu:;;\""),
        ])
        let outcome = await aim.open(item: "renamed-away", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome())
        guard case .unavailable = outcome else {
            return XCTFail("expected .unavailable, got \(outcome)")
        }
    }

    func testAmbiguousWindowTitleOnTheFreshWalkIsUnavailable() async {
        let aim = aim(answering: [
            scriptResult(
                "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|a|1,2;;"
                    + "W|TimBotTu|Macintosh HD:Other:TimBotTu:;;I|b|3,4;;\""),
        ])
        let outcome = await aim.open(item: "a", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome())
        guard case .unavailable(let sentence) = outcome else {
            return XCTFail("expected .unavailable, got \(outcome)")
        }
        XCTAssertTrue(sentence.contains("2 Finder windows"))
    }

    func testRefusedWalkIsForwardedInTheGuestsOwnWords() async {
        let aim = aim(answering: [
            CommandResult(id: 1, ok: false, error: .init(
                code: "busy", message: "the Mac is elsewhere")),
        ])
        let outcome = await aim.open(item: "tbt-worker", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome())
        guard case .refused(let sentence) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertTrue(sentence.contains("the Mac is elsewhere [busy]"))
    }

    func testUnparseableFinderPSNIsUnavailableAndAsksNothing() async {
        let aim = aim(answering: [])
        let outcome = await aim.open(item: "tbt-worker", windowTitle: "TimBotTu",
                                     finderPSN: "not-a-psn", chrome: chrome())
        guard case .unavailable = outcome else {
            return XCTFail("expected .unavailable, got \(outcome)")
        }
    }

    func testAesendRefusalIsForwardedInTheGuestsOwnWords() async {
        let aim = aim(answering: [
            scriptResult(
                "\"W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,25;;\""),
            CommandResult(id: 2, ok: false, error: .init(
                code: "no-target", message: "kNoProcess is refused")),
        ])
        let outcome = await aim.open(item: "tbt-worker", windowTitle: "TimBotTu",
                                     finderPSN: "0.512", chrome: chrome())
        guard case .refused(let sentence) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertTrue(sentence.contains("kNoProcess is refused"))
    }
}
