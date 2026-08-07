import XCTest
@testable import MirrorKit

/// Three states used to share one error word.
///
/// A faceless background application, an application with a face and
/// nothing open right now, and an application whose windows we failed to
/// read all arrived as `ax_oracle_not_found`. Two of those are normal. The
/// middle one changes from moment to moment on a healthy machine, so
/// folding it into either neighbour is wrong half the time — which is the
/// case these tests exist to hold apart.
final class ProcessPresenceTests: XCTestCase {

    private func app(_ name: String, backgroundOnly: Bool? = nil,
                     error: String? = nil,
                     front: Bool = false) -> Scene.AppRef {
        Scene.AppRef(psn: "0.\(name.count)", name: name, front: front,
                     backgroundOnly: backgroundOnly, error: error)
    }

    // MARK: - The three states, held apart

    /// State 1. The process's OWN declaration answers, and it answers even
    /// though the anchor was not found — because for a process with no user
    /// interface there was never an anchor to find.
    func testDeclaredFacelessIsHeadlessNotAFailure() {
        let verdict = ProcessPresence.classify(
            app("Folder Actions", backgroundOnly: true,
                error: "ax_oracle_not_found"),
            windowCount: 0)
        XCTAssertEqual(verdict.presence, .headless)
        XCTAssertNil(verdict.reason)
        XCTAssertTrue(verdict.presence.hasNothingToCover,
                      "a headless process is why the census could never settle")
    }

    /// State 2. Enumerated — no error — and nothing open. The guest said so;
    /// this side did not guess it from a window count it could not interpret.
    func testAFaceWithNothingOpenIsEmpty() {
        let verdict = ProcessPresence.classify(
            app("SimpleText", backgroundOnly: false), windowCount: 0)
        XCTAssertEqual(verdict.presence, .empty)
        XCTAssertFalse(verdict.presence.hasNothingToCover,
                       "an application with a face HAS a visibility answer to give")
    }

    /// State 3. The only failure of the three, and it keeps its token.
    func testAFaceWeCouldNotReadIsUnknownWithTheGuestsOwnReason() {
        for token in ["ax_oracle_not_found", "ax_oracle_ambiguous",
                      "ax_oracle_mismatch", "ax_read", "now_no_plane",
                      "now_not_walked", "now_unknown_verdict"] {
            let verdict = ProcessPresence.classify(
                app("SimpleText", backgroundOnly: false, error: token),
                windowCount: 0)
            XCTAssertEqual(verdict.presence, .unknown, token)
            XCTAssertEqual(verdict.reason, token,
                           "the guest's own word, never a word of ours")
        }
    }

    func testWindowsMakeItWindowed() {
        XCTAssertEqual(
            ProcessPresence.classify(app("Finder", backgroundOnly: false),
                                     windowCount: 3).presence,
            .windowed)
    }

    /// Staleness is reported BESIDE data rather than instead of it, so a
    /// stale row that carried windows was enumerated — it is old, not
    /// unread. With nothing carried there is nothing to call old.
    func testStaleWithWindowsIsStillAnEnumeration() {
        XCTAssertEqual(
            ProcessPresence.classify(
                app("Finder", backgroundOnly: false, error: "ax_oracle_stale"),
                windowCount: 2).presence,
            .windowed)
        XCTAssertEqual(
            ProcessPresence.classify(
                app("Finder", backgroundOnly: false, error: "ax_oracle_stale"),
                windowCount: 0).presence,
            .unknown)
    }

    // MARK: - What we do not know, we say

    /// A scene from a guest that predates the declaration, with nothing open
    /// and no error, is genuinely ambiguous between `headless` and `empty`.
    /// Reported as unknown rather than given the comfortable answer:
    /// inventing a classification for something we could not read is the
    /// plausible-wrong-answer this work exists to kill.
    func testNoDeclarationAndNothingOpenIsUnknown() {
        let verdict = ProcessPresence.classify(app("Mystery"), windowCount: 0)
        XCTAssertEqual(verdict.presence, .unknown)
        XCTAssertEqual(verdict.reason, ProcessPresence.noDeclarationReason)
    }

    /// Absence of the key is NOT `false`. An old guest whose row has windows
    /// is still honestly `windowed` — the ambiguity only bites at zero.
    func testNoDeclarationWithWindowsIsStillAnswerable() {
        XCTAssertEqual(
            ProcessPresence.classify(app("Mystery"), windowCount: 1).presence,
            .windowed)
    }

    // MARK: - Never inferred from an empty window list

    /// The inference that produced the false alarm, stated as a test: two
    /// processes with identical observable shape — no windows, no error —
    /// and opposite classifications, decided by the declaration alone. A
    /// classifier that reached for the window count could not tell these
    /// two apart, which is exactly what went wrong.
    func testTheDeclarationAloneSeparatesIdenticalShapes() {
        let faceless = ProcessPresence.classify(
            app("Control Strip Extension", backgroundOnly: true),
            windowCount: 0)
        let empty = ProcessPresence.classify(
            app("SimpleText", backgroundOnly: false), windowCount: 0)
        XCTAssertEqual(faceless.presence, .headless)
        XCTAssertEqual(empty.presence, .empty)
    }

    /// THE FOURTH CONDITION, and the one that looks exactly like state 2.
    ///
    /// An application acquires an anchor slot only after it has been
    /// frontmost at least once since NOW armed — 451 armed passes produced
    /// ONE slot scan, because `capture_anchor`'s A5 fast path skips the
    /// scan unless the context changed. A process that has never come
    /// forward is not failing to be observed; the filter has never run
    /// inside it. In the scene it arrives as `ax_oracle_not_found` with no
    /// windows, which is observationally identical to an application with
    /// nothing open — and calling it `empty` would be a confident claim
    /// about a machine we have never looked at.
    ///
    /// `empty` is EARNED by a successful enumeration, never assumed from a
    /// zero count. This is the assertion that keeps it that way.
    func testAProcessWeHaveNeverBeenAbleToInspectIsUnknownNotEmpty() {
        let neverFront = ProcessPresence.classify(
            app("Apple System Profiler", backgroundOnly: false,
                error: "ax_oracle_not_found"),
            windowCount: 0)
        XCTAssertEqual(neverFront.presence, .unknown,
                       "no windows AND no anchor is a fact about us, not "
                       + "about the machine")
        XCTAssertEqual(neverFront.reason, "ax_oracle_not_found")

        // The difference between them is the ERROR, not the count: same
        // zero, opposite answers.
        XCTAssertEqual(
            ProcessPresence.classify(app("SimpleText", backgroundOnly: false),
                                     windowCount: 0).presence,
            .empty)
    }

    // MARK: - Over a whole scene

    func testAWholeSceneIsClassifiedByPsn() {
        let scene = Scene(
            version: 2, seq: 1, source: "axtree", capturedAt: 0,
            screen: .init(w: 800, h: 600),
            apps: [
                Scene.AppRef(psn: "0.1", name: "Finder", front: true,
                             backgroundOnly: false),
                Scene.AppRef(psn: "0.2", name: "SimpleText", front: false,
                             backgroundOnly: false),
                Scene.AppRef(psn: "0.3", name: "tbt-worker", front: false,
                             backgroundOnly: true),
            ],
            processes: nil, menubar: nil,
            windows: [Scene.Window(id: "0.1/HD#0", app: "Finder", psn: "0.1",
                                   title: "HD", kind: 0,
                                   rect: Rect(l: 0, t: 0, r: 10, b: 10),
                                   front: true, z: 0, visible: true,
                                   controls: [])],
            desktopItems: nil,
            meta: Scene.Meta(latencyMs: nil, bytes: nil, errors: [],
                             plane: nil))
        let byPsn = ProcessPresence.classify(scene)
        XCTAssertEqual(byPsn["0.1"]?.presence, .windowed)
        XCTAssertEqual(byPsn["0.2"]?.presence, .empty)
        XCTAssertEqual(byPsn["0.3"]?.presence, .headless)
    }
}
