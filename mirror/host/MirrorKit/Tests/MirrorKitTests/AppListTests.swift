import XCTest
@testable import MirrorKit

/// `mirror.app {op:"list"}` — the agent's app enumeration.
///
/// The rule under test is not a new one: a row qualifies exactly when
/// `HitTester.switchableApps` says so, which is what the mirror's own
/// Application menu lists. These pin that the two cannot drift, that the
/// faceless processes the guest really runs stay out by default, and that a
/// row is directly actionable (`psn` is what `activate` takes).
final class AppListTests: XCTestCase {

    private func app(_ psn: String, _ name: String,
                     front: Bool = false, error: String? = nil) -> Scene.AppRef {
        Scene.AppRef(psn: psn, name: name, front: front, error: error)
    }

    private func win(_ psn: String, _ title: String,
                     app: String = "SimpleText") -> Scene.Window {
        Scene.Window(id: "\(psn)/\(title)#0", app: app, psn: psn,
                     title: title, kind: 0,
                     rect: Rect(l: 10, t: 40, r: 300, b: 200),
                     front: false, z: 0, visible: true, controls: [])
    }

    private func scene(apps: [Scene.AppRef],
                       processes: [Scene.ProcessRef]? = nil,
                       windows: [Scene.Window] = []) -> Scene {
        Scene(version: 0, seq: 1, source: "axtree", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: apps,
              processes: processes,
              menubar: nil, windows: windows,
              desktopItems: nil,
              meta: Scene.Meta(latencyMs: nil, bytes: nil, errors: [],
                               plane: nil))
    }

    /// The shape the guest actually presents (STATUS.md: `observe` saw 9
    /// processes against 2 real GUI apps): a couple of windowed apps plus the
    /// faceless crowd — the mirror's OWN agent among them.
    private func realisticScene() -> Scene {
        scene(apps: [app("0.1", "Finder", front: true),
                     app("0.2", "SimpleText"),
                     app("0.3", "mirror-agent"),
                     app("0.4", "tbt-worker"),
                     app("0.5", "Control Strip Extension")],
              windows: [win("0.1", "Macintosh HD", app: "Finder"),
                        win("0.2", "Untitled 1")])
    }

    // MARK: - The default: what a user would see in the Application menu

    func testFacelessProcessesAreExcludedByDefault() {
        let rows = AppList.rows(realisticScene())
        XCTAssertEqual(rows.map(\.name), ["Finder", "SimpleText"],
                       "the faceless crowd must not pad the default list")
    }

    /// The specific hazard the default exists to prevent: an agent handed a
    /// list containing the process it is talking THROUGH can quit its own wire.
    func testTheMirrorsOwnAgentIsNotListedByDefault() {
        let rows = AppList.rows(realisticScene())
        XCTAssertFalse(rows.contains { $0.name == "mirror-agent" })
    }

    /// The contract that matters most: this list and the human Application
    /// menu are ONE predicate, so they cannot drift apart.
    func testDefaultRowsMatchSwitchableAppsExactly() {
        let s = realisticScene()
        XCTAssertEqual(AppList.rows(s).map(\.psn),
                       HitTester.switchableApps(s).map(\.psn))
    }

    // MARK: - includeBackground

    func testIncludeBackgroundKeepsEveryProcessAndFlagsIt() {
        let rows = AppList.rows(realisticScene(), includeBackground: true)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.filter(\.background).map(\.name),
                       ["mirror-agent", "tbt-worker",
                        "Control Strip Extension"])
    }

    /// The row shape is stable across the flag — `background` is always
    /// carried, so a consumer reads the field rather than inferring it from
    /// which request it made.
    func testBackgroundIsCarriedInBothModes() {
        let plain = AppList.rows(realisticScene())
        XCTAssertFalse(plain.isEmpty)
        XCTAssertTrue(plain.allSatisfy { $0.background == false },
                      "a default row is by definition not background")
    }

    // MARK: - Row content

    /// The list must be directly actionable: `psn` is the handle
    /// `mirror.app {op:"activate"}` takes, and there are no coordinates on it.
    func testRowsCarryTheActivationHandle() {
        let rows = AppList.rows(realisticScene())
        let simpleText = rows.first { $0.name == "SimpleText" }
        XCTAssertEqual(simpleText?.psn, "0.2")
        XCTAssertEqual(simpleText?.windows, 1)
        XCTAssertEqual(simpleText?.front, false)
        XCTAssertEqual(rows.first { $0.front }?.name, "Finder")
    }

    /// `windows > 0 || front` is exactly the qualifying rule, so the count
    /// explains the row's own classification rather than being decoration.
    func testWindowCountExplainsQualification() {
        for row in AppList.rows(realisticScene()) {
            XCTAssertTrue(row.windows > 0 || row.front,
                          "\(row.name) qualified without a window or the front")
        }
    }

    /// A frontmost app with no window still qualifies — that is the second
    /// half of the switchable rule, and the case a window-count-only filter
    /// would silently drop.
    func testFrontmostWithoutAWindowStillQualifies() {
        let s = scene(apps: [app("0.9", "Apple System Profiler", front: true),
                             app("0.4", "tbt-worker")])
        let rows = AppList.rows(s)
        XCTAssertEqual(rows.map(\.name), ["Apple System Profiler"])
        XCTAssertEqual(rows.first?.windows, 0)
    }

    func testProcessFallbackDoesNotOfferFacelessBackgroundProcesses() {
        let s = scene(
            apps: [app("0.2", "New Old World", front: true)],
            processes: [
                .init(psn: "0.1", name: "Finder", front: false,
                      signature: "MACS"),
                .init(psn: "0.3", name: "FBC Indexing Scheduler",
                      front: false, signature: "FBCl"),
            ],
            windows: [win("0.1", "Desktop", app: "Finder"),
                      win("0.2", "New Old World", app: "New Old World")])

        XCTAssertEqual(HitTester.switchableApps(s).map(\.name),
                       ["New Old World", "Finder"])
    }

    /// Stale beats guessed (AGENTS.md): an app whose AXPeek sample errored is
    /// still running, so it keeps its row and carries the error rather than
    /// vanishing from the enumeration.
    func testOracleErrorIsSurfacedNotHidden() {
        let s = scene(apps: [app("0.1", "Finder", front: true),
                             app("0.2", "SimpleText",
                                 error: "ax_oracle_not_found")],
                      windows: [win("0.2", "Untitled 1")])
        let row = AppList.rows(s).first { $0.name == "SimpleText" }
        XCTAssertEqual(row?.error, "ax_oracle_not_found")
        XCTAssertNil(AppList.rows(s).first { $0.name == "Finder" }?.error,
                     "a clean app must not carry an empty error key")
    }

    // MARK: - The declaration, not the window count

    /// THE BUG THIS ARC EXISTS FOR, on the agent surface.
    ///
    /// `background` used to be `!(windows > 0 || front)` — which says
    /// "faceless" about SimpleText with every document closed. An agent
    /// asking what it can talk to was handed a list that dropped a running
    /// application because it happened to have nothing open, and kept the
    /// mistake invisible by calling it a background process.
    ///
    /// The declaration decides now. Same observable shape — no windows, not
    /// frontmost — and opposite answers.
    func testAnIdleApplicationIsNotFiledAsFaceless() {
        let s = scene(apps: [
            Scene.AppRef(psn: "0.1", name: "Finder", front: true,
                         backgroundOnly: false),
            Scene.AppRef(psn: "0.2", name: "SimpleText", front: false,
                         backgroundOnly: false),
            Scene.AppRef(psn: "0.3", name: "tbt-worker", front: false,
                         backgroundOnly: true),
        ], windows: [win("0.1", "Macintosh HD", app: "Finder")])

        let rows = AppList.rows(s)
        XCTAssertEqual(rows.map(\.name), ["Finder", "SimpleText"],
                       "an application with nothing open is still an "
                       + "application an agent can talk to")
        XCTAssertEqual(rows.first { $0.name == "SimpleText" }?.presence, .idle)
        XCTAssertEqual(rows.first { $0.name == "Finder" }?.presence, .windowed)

        let all = AppList.rows(s, includeBackground: true)
        XCTAssertEqual(all.first { $0.name == "tbt-worker" }?.presence,
                       .headless)
        XCTAssertEqual(all.first { $0.name == "tbt-worker" }?.background, true)
    }

    /// A guest that never sent the declaration keeps the old predicate — the
    /// fallback is explicit, so nobody reads a nil as a `false`.
    func testAGuestWithoutTheDeclarationFallsBackToTheSwitchablePredicate() {
        let rows = AppList.rows(realisticScene(), includeBackground: true)
        XCTAssertEqual(rows.first { $0.name == "tbt-worker" }?.background, true)
        XCTAssertEqual(rows.first { $0.name == "tbt-worker" }?.presence,
                       .unclassified,
                       "without a declaration we say we do not know, rather "
                       + "than dressing the guess up as an answer")
        XCTAssertEqual(rows.first { $0.name == "tbt-worker" }?.presenceReason,
                       ProcessPresence.noDeclarationReason)
    }

    func testEmptySceneListsNothingRatherThanFailing() {
        XCTAssertTrue(AppList.rows(scene(apps: [])).isEmpty)
        XCTAssertTrue(AppList.rows(scene(apps: []),
                                   includeBackground: true).isEmpty)
    }
}
