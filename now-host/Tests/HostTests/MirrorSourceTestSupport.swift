import XCTest
import MirrorKit
@testable import Host

/// **A guest cycle a test drives by hand.**
///
/// `NOWMirrorSource`'s poll is a sequence of asynchronous joins, and the
/// interesting states are the ones BETWEEN them — a scene delivered but
/// its content not yet joined is when an act is held, and that window is
/// where both of the 2026-08-05 face defects lived. Nothing about it is
/// reachable from a source that runs its own cycle to completion, so the
/// completions are held here and released by the test.
///
/// Extracted from `NOWMirrorSourceTests`, where it was private, when
/// `MirrorFaceParityTests` needed the same thing. It is the same harness;
/// only its name changed.
@MainActor
final class MirrorCycleHarness {
    var activeKey: GuestKey?
    /// Whether the pinned session still holds a connection, as the lane's
    /// dead-guest check sees it. Tests flip it to kill the guest.
    var guestConnected = true
    var globalScenePending = false
    var sceneRequests: [(GuestKey, Bool, Bool)] = []
    var sceneCompletions: [
        (Result<GuestListener.SceneDelivery,
                GuestListener.SceneFailure>) -> Void
    ] = []
    var joinedScenes: [Scene] = []
    var joinCompletions: [(NOWMirrorContentPlane.Update) -> Void] = []

    init(activeKey: GuestKey) { self.activeKey = activeKey }

    var io: NOWMirrorCycleIO {
        .init(
            activeKey: { self.activeKey },
            isGuestConnected: { _ in self.guestConnected },
            isScenePending: { self.globalScenePending },
            requestScene: { key, semantics, interaction, completion in
                self.globalScenePending = true
                self.sceneRequests.append((key, semantics, interaction))
                self.sceneCompletions.append(completion)
            },
            guestChanged: {},
            disableContent: { completion in completion(nil) },
            joinContent: { scene, completion in
                self.joinedScenes.append(scene)
                self.joinCompletions.append(completion)
            })
    }

    func completeScene(
        _ index: Int,
        with result: Result<GuestListener.SceneDelivery,
                            GuestListener.SceneFailure>
    ) {
        globalScenePending = false
        sceneCompletions[index](result)
    }

    /// Release the content join for the scene at `index`, which is what
    /// ends the cycle and lets a held act into the lane.
    func completeJoin(_ index: Int, sentence: String = "content") {
        joinCompletions[index](.init(scene: joinedScenes[index],
                                     sentence: sentence))
    }
}

/// The corpus scene, stamped with the durable identities and the complete
/// coverage claims a settlement needs.
///
/// IR v2, because v1 is `isApproximateReadOnly` — identities and coverage
/// are what v2 added, and they are the whole point here.
@MainActor
func identifiedSceneDocument(seq: Int, without absent: String? = nil)
    throws -> Data {
    let fixture = try XCTUnwrap(
        Bundle.module.url(forResource: "now-scene-ir-v1",
                          withExtension: "json",
                          subdirectory: "Fixtures"))
    var scene = try XCTUnwrap(JSONSerialization.jsonObject(
        with: try Data(contentsOf: fixture)) as? [String: Any])
    scene["seq"] = seq
    scene["version"] = 2

    func incarnation(_ psn: String) -> String {
        "process-" + psn.replacingOccurrences(of: ".", with: "-")
    }
    /* Both rosters, and that is not belt-and-braces: the replica's
       applications come from `apps` while the window/owner join reads
       `processes`, so stamping one leaves every window ownerless and
       nothing can ever be proven absent. */
    for roster in ["apps", "processes"] {
        var rows = try XCTUnwrap(scene[roster] as? [[String: Any]])
        for index in rows.indices {
            let psn = try XCTUnwrap(rows[index]["psn"] as? String)
            rows[index]["incarnation"] = incarnation(psn)
        }
        scene[roster] = rows
    }

    var windows = try XCTUnwrap(scene["windows"] as? [[String: Any]])
    if let absent {
        windows.removeAll { $0["title"] as? String == absent }
    }
    var owners = Set<String>()
    for index in windows.indices {
        let psn = try XCTUnwrap(windows[index]["psn"] as? String)
        let id = try XCTUnwrap(windows[index]["id"] as? String)
        windows[index]["incarnation"] = "window-" + id
        owners.insert(incarnation(psn))
    }
    scene["windows"] = windows

    /* A settlement needs a claim whose scope is COMPLETE: retained stale
       state must never settle a mutation, so an absent window in a scene
       that does not claim to have walked that process proves nothing.
       Every owner that had windows in the FULL scene claims one,
       including the owner whose last window this scene drops — that claim
       is exactly the evidence a close is waiting for. */
    var meta = try XCTUnwrap(scene["meta"] as? [String: Any])
    let full = try XCTUnwrap(
        (try JSONSerialization.jsonObject(with: try Data(
            contentsOf: fixture)) as? [String: Any])?["windows"]
            as? [[String: Any]])
    for window in full {
        owners.insert(incarnation(
            try XCTUnwrap(window["psn"] as? String)))
    }
    meta["coverage"] = owners.sorted().map {
        ["scope": "windows", "owner": $0, "status": "complete"]
    } + [["scope": "processes", "status": "complete"]]
    scene["meta"] = meta

    return try JSONSerialization.data(withJSONObject: scene)
}

@MainActor
func sceneDelivery(_ document: Data, seq: Int, for key: GuestKey)
    -> GuestListener.SceneDelivery {
    .init(document: document, irVersion: 2, seq: seq, capturedAt: 1,
          source: "test", walkMs: 1, settlements: nil, transferMs: 1,
          guestName: "Test Mac", guestKey: key)
}
