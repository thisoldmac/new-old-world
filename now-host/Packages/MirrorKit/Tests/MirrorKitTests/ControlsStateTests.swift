import XCTest
@testable import MirrorKit

/// **Which kind of empty an empty `controls` array is.**
///
/// `controls` is required by the IR, so `[]` has carried three different
/// facts since the plane was written: never walked, walked and none there,
/// and — since the shared control pool was measured filling — a window
/// skipped for want of a slot, which is not a fact about that window at
/// all. The producer's verdict prose could name two of them in a sentence
/// in `meta.errors`, keyed on a window title, readable by a person and by
/// nothing else.
///
/// The producer sends the word only where the array cannot speak for
/// itself, so the rules that make absence unambiguous live on this side,
/// in `controlsKnowledge`, and this is the gate on them.
final class ControlsStateTests: XCTestCase {

    private func window(controls: [Scene.Control],
                        state: String?) -> Scene.Window {
        var w = Scene.Window(
            id: "0.1/W#0", app: "A", psn: "0.1", title: "W", kind: 2,
            rect: Rect(l: 0, t: 0, r: 10, b: 10), front: true, z: 0,
            visible: true, controls: controls,
            text: nil, items: nil, display: nil)
        w.controlsState = state
        return w
    }

    private var aControl: Scene.Control {
        Scene.Control(ref: "r", role: "button", title: "OK",
                      rect: Rect(l: 0, t: 0, r: 5, b: 5),
                      enabled: true, visible: true, value: 0, min: 0, max: 1,
                      checked: false)
    }

    /// **The four states, read the way the producer means them.**
    func testTheFourStatesAreDistinct() {
        XCTAssertEqual(window(controls: [aControl], state: nil)
                        .controlsKnowledge, .complete,
                       "a non-empty array is complete by construction; the "
                       + "producer does not spend a word saying so")
        XCTAssertEqual(window(controls: [], state: "empty")
                        .controlsKnowledge, .empty)
        XCTAssertEqual(window(controls: [], state: "unknown")
                        .controlsKnowledge, .unknown)
        XCTAssertEqual(window(controls: [], state: "notFetched")
                        .controlsKnowledge, .notFetched)
    }

    /// **The one that would undo the whole field.** An empty array from a
    /// producer that does not report this is `unknown` — it could not tell
    /// us. Reading it as `empty` would reintroduce, one layer up, exactly
    /// the conflation the key was added to end: a window nobody walked
    /// becoming a window proven to have no controls.
    ///
    /// Watched failing by mutation 2026-08-07: returning `.empty` from the
    /// `guard` in `controlsKnowledge` passes every other test in this file
    /// and fails only this one.
    func testAnOldProducersEmptyArrayIsUnknownNotEmpty() {
        XCTAssertEqual(window(controls: [], state: nil).controlsKnowledge,
                       .unknown,
                       "absence of the word means the producer could not "
                       + "say, which is not the same as saying none")
    }

    /// A word this build has never heard of is `unknown`. The IR is
    /// accretive; a newer guest naming a state we cannot interpret is the
    /// textbook case for admitting we do not know, not for defaulting.
    func testAnUnrecognisedWordIsUnknown() {
        XCTAssertEqual(window(controls: [], state: "deferred")
                        .controlsKnowledge, .unknown)
    }

    /// `complete` beside an empty array is not a state the producer can be
    /// in. Taking it at its word would assert "walked, and here they are"
    /// over nothing at all.
    func testCompleteOverAnEmptyArrayIsNotBelieved() {
        XCTAssertEqual(window(controls: [], state: "complete")
                        .controlsKnowledge, .unknown)
    }

    /// The wire half: the guest omits the key beside a populated array and
    /// sends it beside an empty one, and both must decode.
    func testTheGuestsTwoShapesDecode() throws {
        let json = #"""
        {"version":2,"seq":1,"source":"peek","capturedAt":0,
         "screen":{"w":640,"h":480},"apps":[],
         "windows":[
           {"id":"a","app":"A","psn":"0.1","title":"Spent It","rect":
            {"l":0,"t":0,"r":9,"b":9},"front":true,"z":0,"visible":true,
            "controls":[{"ref":"r","role":"button","title":"OK","rect":
             {"l":0,"t":0,"r":5,"b":5},"enabled":true,"visible":true}]},
           {"id":"b","app":"A","psn":"0.1","title":"Lost Out","rect":
            {"l":0,"t":0,"r":9,"b":9},"front":false,"z":1,"visible":true,
            "controlsState":"notFetched","controls":[]}],
         "meta":{"errors":[]}}
        """#
        let s = try JSONDecoder().decode(Scene.self, from: Data(json.utf8))
        XCTAssertNil(s.windows[0].controlsState)
        XCTAssertEqual(s.windows[0].controlsKnowledge, .complete)
        XCTAssertEqual(s.windows[1].controlsKnowledge, .notFetched,
                       "the window that lost the pool was not asked, and "
                       + "asking again with room would answer it")
    }
}
