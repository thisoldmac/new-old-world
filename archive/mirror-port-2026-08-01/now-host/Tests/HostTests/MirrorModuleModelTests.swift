import XCTest
import MirrorKit
import NOWAgentIntegration
@testable import Host

/// The Mirror page's **state selection** — which of its states it is in, and
/// what it says there. Not its pixels: SwiftUI bodies are not instantiable
/// here, and a test that claimed to check the drawing would be checking that
/// a call is spelled.
///
/// What is testable, and what these cover:
///
/// - every resting state is reachable, and they are reachable in the ladder's
///   order rather than all collapsing onto one;
/// - **only the fault state is drawn as a fault**, which is the specific
///   defect this page was designed against (`docs/metal-and-ux-review.md` §1:
///   *"0 companions, 0 calls, last seen never is the visual shape of a thing
///   that failed to load"*);
/// - every resting state says what would change it;
/// - a replay never claims to be live.
@MainActor
final class MirrorModuleModelTests: XCTestCase {

    // MARK: - the resting ladder

    func testNothingConnectedRestsOnNoGuest() {
        let model = MirrorModuleModel()
        XCTAssertEqual(model.state, .noGuest)
    }

    /// A connected Mac nobody has asked about is "not looked yet" — never
    /// "no extension". This host has no probe, and reporting an unasked
    /// question as an answer would invent a fact about someone's machine.
    func testConnectedButUnaskedIsNotReportedAsAbsent() {
        let model = MirrorModuleModel()
        model.connection = .connected(named: "Quadra")
        XCTAssertEqual(model.state, .notLookedYet(guest: "Quadra"))
    }

    func testTheDiscoveryLadderHasFourDistinctRungs() {
        let model = MirrorModuleModel()
        model.connection = .connected(named: "Quadra")

        model.record(extensionEvidence: .absent)
        XCTAssertEqual(model.state, .extensionAbsent(guest: "Quadra"))

        model.record(extensionEvidence: .present)
        XCTAssertEqual(model.state, .notLookedYet(guest: "Quadra"),
                       "Extension present, plane unasked: still unasked.")

        model.record(planeEvidence: .unarmed)
        XCTAssertEqual(model.state, .planeUnarmed(guest: "Quadra"))

        model.record(planeEvidence: .armed)
        XCTAssertEqual(model.state, .armedNoSceneYet(guest: "Quadra"))
    }

    // MARK: - the defect this page is designed against

    /// **Only a fault is drawn as a fault.** Every other state is idle, and
    /// idle is not an error. A new state joining the wrong side of this is
    /// exactly the regression the assertion exists for.
    func testNoRestingStateIsDrawnAsAFault() {
        let idle: [MirrorPaneState] = [
            .noGuest,
            .notLookedYet(guest: "Quadra"),
            .extensionAbsent(guest: "Quadra"),
            .planeUnarmed(guest: "Quadra"),
            .armedNoSceneYet(guest: "Quadra"),
            .looking(guest: "Quadra"),
            /* A refusal is an ANSWER. The commonest one is the Mac being
               busy with the other thing its single transfer lane carries,
               which is the system working, and drawing it as a fault would
               be this page reporting normal operation as damage. */
            .refused(guest: "Quadra", reason: "a transfer is in flight"),
            .sceneWithoutScreen(provenance: .fixture(name: "a.json")),
        ]
        for state in idle {
            XCTAssertFalse(state.isFault,
                           "\(state) is idle, not broken.")
            XCTAssertNotEqual(state.resting?.symbol,
                              "exclamationmark.triangle",
                              "\(state) must not wear the fault glyph.")
        }
        XCTAssertTrue(
            MirrorPaneState.unreadable(reason: "bad",
                                       provenance: .fixture(name: "a.json"))
                .isFault)
    }

    /// Every state that shows words says all four: a glyph, a headline, what
    /// is true, and what would change it. The fourth is the one that keeps a
    /// resting page from reading as a dead one, so it is asserted non-empty.
    func testEveryRestingStateSaysWhatWouldChangeIt() {
        let states: [MirrorPaneState] = [
            .noGuest,
            .notLookedYet(guest: "Quadra"),
            .extensionAbsent(guest: "Quadra"),
            .planeUnarmed(guest: "Quadra"),
            .armedNoSceneYet(guest: "Quadra"),
            .looking(guest: "Quadra"),
            .refused(guest: "Quadra", reason: "a transfer is in flight"),
            .sceneWithoutScreen(provenance: .fixture(name: "a.json")),
            .unreadable(reason: "bad", provenance: .fixture(name: "a.json")),
        ]
        for state in states {
            let copy = state.resting
            XCTAssertNotNil(copy, "\(state) reaches the screen with no words.")
            XCTAssertFalse(copy?.symbol.isEmpty ?? true)
            XCTAssertFalse(copy?.title.isEmpty ?? true)
            XCTAssertFalse(copy?.message.isEmpty ?? true)
            XCTAssertFalse(copy?.next.isEmpty ?? true,
                           "\(state) says what is true and not what would "
                               + "change it, which is how a page reads broken.")
        }
    }

    /// The state that draws has no resting copy, and vice versa: the pane
    /// branches on exactly one of them.
    func testShowingHasNoRestingCopy() {
        let scene = MirrorSceneAdapter.scene(from: document())
        XCTAssertNil(MirrorPaneState.showing(scene: scene,
                                             provenance: .fixture(name: "a"))
            .resting)
    }

    /// **A named Mac appears in its own copy.** The states are about one
    /// machine, and a page that says "the Mac" while a picker offers two is
    /// the ambiguity this product spends real effort avoiding elsewhere.
    func testTheConnectedMacIsNamedInTheCopy() {
        for state in [MirrorPaneState.notLookedYet(guest: "Quadra"),
                      .extensionAbsent(guest: "Quadra"),
                      .planeUnarmed(guest: "Quadra"),
                      .armedNoSceneYet(guest: "Quadra"),
                      .looking(guest: "Quadra"),
                      .refused(guest: "Quadra", reason: "busy")] {
            XCTAssertTrue(state.resting?.message.contains("Quadra") ?? false,
                          "\(state) does not name the machine it is about.")
        }
    }

    // MARK: - showing a scene

    func testAReplayedDocumentIsShownAndNamedAsARecording() throws {
        let model = MirrorModuleModel()
        model.show(document: try bytes(), provenance: .fixture(name: "07.json"))

        XCTAssertTrue(model.state.hasScene)
        XCTAssertFalse(model.state.isFault)
        XCTAssertEqual(model.provenance, .fixture(name: "07.json"))
        XCTAssertEqual(model.provenance?.isLive, false)
        let banner = try XCTUnwrap(model.provenance?.banner)
        XCTAssertTrue(banner.contains("Replayed"),
                      "A recording must never read as this Mac, now.")
        XCTAssertTrue(banner.contains("not this Mac now"))
    }

    /// A scene outranks the discovery ladder: a page with something to draw
    /// draws it, whatever this host does or does not know about the machine.
    func testASceneOutranksTheDiscoveryLadder() throws {
        let model = MirrorModuleModel()
        model.record(extensionEvidence: .absent)
        model.show(document: try bytes(), provenance: .fixture(name: "a.json"))
        XCTAssertTrue(model.state.hasScene)
    }

    /// Absence survives all the way to the page: the scene the pane holds is
    /// the adapter's, flags intact, so the footer can say "not reported"
    /// rather than "none".
    func testThePaneHoldsThePresenceFlagsNotJustTheRows() throws {
        let model = MirrorModuleModel()
        model.show(document: try bytes(), provenance: .fixture(name: "a.json"))
        let scene = try XCTUnwrap(model.scene)

        XCTAssertFalse(scene.appsPresent, "The fixture has no apps key.")
        XCTAssertTrue(scene.windowsPresent)
        XCTAssertEqual(scene.windows.first?.controlsPresent, false)
    }

    func testASceneWithNoScreenSizeIsNotAFault() {
        let model = MirrorModuleModel()
        let noScreen = Data("""
        {"version":1,"windows":[],"meta":{}}
        """.utf8)
        model.show(document: noScreen, provenance: .fixture(name: "a.json"))

        XCTAssertEqual(model.state,
                       .sceneWithoutScreen(provenance: .fixture(name: "a.json")))
        XCTAssertFalse(model.state.isFault)
        XCTAssertFalse(model.state.hasScene,
                       "There is nothing to fit the drawing into.")
    }

    // MARK: - the one real fault

    func testAnUnknownMajorIsRefusedWholeAndSaidPlainly() {
        let model = MirrorModuleModel()
        model.show(document: Data(#"{"version":9}"#.utf8), irVersion: 9,
                   provenance: .fixture(name: "future.json"))

        XCTAssertTrue(model.state.isFault)
        XCTAssertNil(model.scene, "Nothing is drawn from a refused document.")
        XCTAssertTrue(model.failure?.contains("9") ?? false)
        XCTAssertTrue(model.state.resting?.next.contains("whole") ?? false)
    }

    /// A file with no `version` at all does not get to be assumed IR 1: the
    /// reader passes 0, and the gate refuses it before parsing the body.
    func testAnUndeclaredVersionIsRefusedRatherThanGuessed() {
        XCTAssertNil(MirrorSceneFile.declaredVersion(
            in: Data(#"{"windows":[]}"#.utf8)))
        XCTAssertEqual(MirrorSceneFile.declaredVersion(
            in: Data(#"{"version":1}"#.utf8)), 1)

        let model = MirrorModuleModel()
        model.show(document: Data(#"{"windows":[]}"#.utf8), irVersion: 0,
                   provenance: .fixture(name: "a.json"))
        XCTAssertTrue(model.state.isFault)
    }

    func testGarbageIsAFaultAndClearsAnyEarlierScene() throws {
        let model = MirrorModuleModel()
        model.show(document: try bytes(), provenance: .fixture(name: "a.json"))
        XCTAssertTrue(model.state.hasScene)

        model.show(document: Data("not json".utf8),
                   provenance: .fixture(name: "b.json"))
        XCTAssertTrue(model.state.isFault)
        XCTAssertNil(model.scene,
                     "A page must not draw the previous scene under the new "
                         + "file's name.")
    }

    // MARK: - the wire's own events

    /// A guest leaving takes a LIVE scene with it and leaves a replay alone:
    /// a recording is this Mac's document and has nothing to do with who is
    /// on the wire. The evidence resets either way — it was a claim about a
    /// machine that is gone.
    func testAGuestLeavingClearsALiveSceneButNotAReplay() throws {
        let key = GuestKey.synthetic("Quadra")
        let live = MirrorModuleModel()
        live.record(extensionEvidence: .present)
        live.record(planeEvidence: .armed)
        live.show(document: try bytes(), provenance: .guest(name: "Quadra"))
        live.guestLeft(key)
        XCTAssertNil(live.scene)
        XCTAssertEqual(live.state, .noGuest)

        let replay = MirrorModuleModel()
        replay.show(document: try bytes(),
                    provenance: .fixture(name: "a.json"))
        replay.guestLeft(key)
        XCTAssertNotNil(replay.scene)
        XCTAssertTrue(replay.state.hasScene)
    }

    func testClosingASceneReturnsToTheRestingLadder() throws {
        let model = MirrorModuleModel()
        model.connection = .connected(named: "Quadra")
        model.record(extensionEvidence: .absent)
        model.show(document: try bytes(), provenance: .fixture(name: "a.json"))
        model.clearScene()
        XCTAssertEqual(model.state, .extensionAbsent(guest: "Quadra"))
    }

    // MARK: - folder items (the draw half; the aim half is
    // MirrorFolderItemsAimTests, deliberately elsewhere)

    /// Split out and pure so the wording is testable without a join, a
    /// listener, or a socket — `joinFolderItems` itself needs a live
    /// `GuestListener` and is exercised through `MirrorFolderItemsJoinTests`.
    func testFolderItemsSentenceNamesCountsAndIsNilWhenThereIsNothingToSay() {
        XCTAssertNil(MirrorModuleModel.folderItemsSentence(
            windows: 0, items: 0, ambiguous: []))
        XCTAssertEqual(MirrorModuleModel.folderItemsSentence(
            windows: 1, items: 3, ambiguous: []),
            "3 items across 1 folder window.")
        XCTAssertEqual(MirrorModuleModel.folderItemsSentence(
            windows: 2, items: 1, ambiguous: []),
            "1 item across 2 folder windows.")
    }

    /// A window skipped for ambiguity is said even when nothing joined —
    /// the gap is not the same as "no Finder folder window was open".
    func testFolderItemsSentenceNamesAnAmbiguousTitleEvenWithNoWindowsJoined() {
        let sentence = MirrorModuleModel.folderItemsSentence(
            windows: 0, items: 0, ambiguous: ["TimBotTu"])
        XCTAssertNotNil(sentence)
        XCTAssertTrue(sentence!.contains("\"TimBotTu\""))
        XCTAssertTrue(sentence!.contains("cannot tell them apart"))
    }

    /// `clearScene` puts the page all the way back to resting — the folder
    /// note describes a scene that is no longer on screen, same as
    /// `contentNote` does beside it.
    func testClosingASceneClearsTheFolderItemsNoteToo() throws {
        let model = MirrorModuleModel()
        model.connection = .connected(named: "Quadra")
        model.show(document: try bytes(), provenance: .fixture(name: "a.json"))
        model.clearScene()
        XCTAssertNil(model.folderItemsNote)
    }

    // MARK: - registration

    /// The page is a module, not a view somebody can only reach by knowing
    /// it exists.
    func testMirrorIsRegisteredAsAListModule() {
        let module = ModuleRegistry.standard.module(id: "mirror")
        XCTAssertEqual(module?.title, "Mirror")
        XCTAssertEqual(module?.placement, .list)
    }

    // MARK: - a NOW-shaped document, as sparse as the real producer's

    private func document() -> NOWSceneDocument {
        NOWSceneDocument(version: 1, seq: 1, capturedAt: 0, source: "peek",
                         screen: .init(w: 640, h: 480),
                         windows: [],
                         meta: .init(errors: []))
    }

    /// Deliberately the shape NOW's guest actually sends: `windows` with no
    /// `controls`, no `apps` key at all, no `display`.
    private func bytes() throws -> Data {
        Data("""
        {"version":1,"seq":7,"source":"peek","capturedAt":1.0,
         "screen":{"w":640,"h":480},
         "windows":[{"id":"w1","app":"Finder","psn":"0:1","title":"Macintosh HD",
                     "rect":{"l":40,"t":60,"r":400,"b":300},"front":true,
                     "z":0,"visible":true}],
         "meta":{"plane":"peek","errors":[]}}
        """.utf8)
    }
}

/*
 Mutations run against the pane, each watched failing (17 tests in this
 class, 9 in ModuleRegistryTests):

 A. Delete the `case "mirror":` arm from HostRootView — a registry row with
    no detail pane, i.e. a sidebar entry that lands on "Module Unavailable".
    RED in ModuleRegistryTests.testEveryModuleHasADetailPane.
 B. `extensionEvidence == .unasked` reports `.extensionAbsent` — an unasked
    question rendered as an answer. RED in
    testConnectedButUnaskedIsNotReportedAsAbsent.
 C. `.extensionAbsent` becomes `isFault` and wears the warning triangle —
    idle drawn as broken, the exact defect this page is designed against.
    RED in testNoRestingStateIsDrawnAsAFault (2 assertions).
 D. `.extensionAbsent`'s `next` emptied — a state that says what is true and
    not what would change it. RED in
    testEveryRestingStateSaysWhatWouldChangeIt.
 E. A fixture's banner reads "Live from …" — a recording claiming to be this
    Mac now. RED in testAReplayedDocumentIsShownAndNamedAsARecording (2).

 Restored: 26/26 green.
*/
