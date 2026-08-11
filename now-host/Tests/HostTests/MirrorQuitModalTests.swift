import XCTest
import MirrorKit
@testable import Host

/// A real document, captured off a real guest, that CONTAINS the window a
/// person could not find in the Mirror.
///
/// Date & Time raises `Set Time Zone` as a modal — on this image when it
/// opens, on Michelle's when it quits — and on 2026-08-06 the Mirror drew
/// the panel and not the modal, while its own status line read `same`.
/// `same` means the guest was asked and answered "you already hold this",
/// so the first thing worth settling is whether the guest ever said it at
/// all. It did: `Fixtures/scene-quit-modal.json` is the guest's own whole
/// document from that moment, wire-captured on port 5490 against build
/// c5c39f61dbbf, and the modal is in it with its title, nine dialog items
/// and a reference on each.
///
/// So this file asks the only question left on this side: does OUR decode,
/// reduce and project keep it?
final class MirrorQuitModalTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "scene-quit-modal",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func scene() throws -> MirrorKit.Scene {
        try NOWMirrorSceneDecoder.decode(irVersion: 2,
                                         document: try fixture())
    }

    func testTheDecoderKeepsTheModalWindow() throws {
        let scene = try scene()
        let titles = scene.windows.map(\.title)
        XCTAssertTrue(titles.contains("Set Time Zone"),
                      "the decoder dropped a window the guest sent: \(titles)")
        let modal = try XCTUnwrap(
            scene.windows.first { $0.title == "Set Time Zone" })
        XCTAssertEqual(modal.kind, 2, "a Dialog Manager window")
        XCTAssertNotNil(modal.ref, "a drawn window with no ref cannot be hit")
        XCTAssertNotNil(modal.incarnation,
                        "the reducer refuses to key a window with no "
                        + "incarnation, so an absent one is a dropped window")
        XCTAssertEqual(modal.dialogItems?.count, 9)
    }

    // MARK: - The lapse

    /// THE SECOND HALF, and the one that explains the frame Michelle saw.
    ///
    /// The anchor plane is held by a LEASE the scene owner renews on every
    /// `scene.request` and which runs for 600 ticks — ten seconds
    /// (`peek.c :: kNowPeekOwnerLeaseTicks`). Go quiet for longer and the
    /// next walk is BLIND: measured on the wire, port 5490, build
    /// c5c39f61dbbf, with the modal up the whole time —
    ///
    ///     gap  3s  → Set Time Zone, Date & Time, New Old World  (95b9a08b)
    ///     gap  8s  → Set Time Zone, Date & Time, New Old World  (95b9a08b)
    ///     gap 12s  → New Old World only                         (ae3f00e1)
    ///     gap 20s  → New Old World only                         (ae3f00e1)
    ///
    /// and the scene straight after each blind one is right again, because
    /// the blind walk is the one that RE-claimed: the extension only arms
    /// on its next pass, so re-claiming costs exactly one scene.
    ///
    /// Both fixtures are that measurement. What this test pins is what THIS
    /// side does with the pair, because the guest's half is honest — every
    /// foreign process reports `now_no_plane` and coverage
    /// `unavailable/not-observed`, which is "I could not look", not "there
    /// is nothing there".
    func testALapsedPlaneDoesNotDeleteWhatItCouldNotObserve() throws {
        let session = MirrorGuestSession(guest: "wire-5490",
                                         incarnation: "session-a")
        func reduce(_ name: String, previous: MirrorReplica?) throws
            -> MirrorReplica {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: "json",
                                  subdirectory: "Fixtures"))
            let scene = try NOWMirrorSceneDecoder.decode(
                irVersion: 2, document: try Data(contentsOf: url))
            let observation = GuestSceneObservation(
                session: session, scene: scene,
                receivedAt: Date(timeIntervalSince1970: Double(scene.seq)))
            guard case .accepted(let replica) =
                MirrorReplicaReducer.reduce(observation, previous: previous)
            else {
                throw UnexpectedTestResult(
                    description: "the reducer rejected a real document")
            }
            return replica
        }

        let held = try reduce("scene-plane-held", previous: nil)
        XCTAssertTrue(held.windows.values.contains { $0.window.title
            == "Set Time Zone" }, "the held scene carries the modal")

        let lapsed = try reduce("scene-plane-lapsed", previous: held)
        let modal = try XCTUnwrap(lapsed.windows.values.first {
            $0.window.title == "Set Time Zone"
        }, "a window whose owner reported `unavailable/not-observed` must "
            + "not be deleted — an unobserved process cannot say a window "
            + "is gone")
        XCTAssertEqual(modal.freshness, .expectedStale,
                       "and it must be RETAINED AS STALE, not as current: "
                       + "this is the whole difference between a mirror that "
                       + "says it lost sight of the machine and one that "
                       + "quietly keeps drawing the last thing it saw")
        XCTAssertFalse(modal.actionable,
                       "nothing that stale may be clicked")
        XCTAssertFalse(lapsed.snapshot.baseComplete,
                       "the snapshot must not claim complete coverage of a "
                       + "machine half of which it could not observe")
    }

    /// THE THIRD HALF: the person has to be able to tell the two apart.
    ///
    /// The pair above is a mirror that correctly keeps drawing windows it
    /// could no longer see. On 2026-08-06 the status line over that exact
    /// state read `5 windows · walk 0ms · transfer 36ms · same` — every
    /// word true, the sentence a lie by omission. The reducer knew;
    /// nothing carried it to the face.
    func testTheStatusLineSaysHowManyWindowsAreOnlyRetained() throws {
        let session = MirrorGuestSession(guest: "wire-5490",
                                         incarnation: "session-a")
        func reduce(_ name: String, previous: MirrorReplica?) throws
            -> MirrorReplica {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: name, withExtension: "json",
                                  subdirectory: "Fixtures"))
            let scene = try NOWMirrorSceneDecoder.decode(
                irVersion: 2, document: try Data(contentsOf: url))
            let observation = GuestSceneObservation(
                session: session, scene: scene,
                receivedAt: Date(timeIntervalSince1970: Double(scene.seq)))
            guard case .accepted(let replica) =
                MirrorReplicaReducer.reduce(observation, previous: previous)
            else {
                throw UnexpectedTestResult(
                    description: "the reducer rejected a real document")
            }
            return replica
        }

        let held = try reduce("scene-plane-held", previous: nil)
        XCTAssertEqual(
            NOWMirrorSource.observationPhrase(held.windows.count,
                                              replica: held),
            "\(held.windows.count) windows",
            "a fully observed machine gets no qualifier — a warning that is "
            + "always on is not a warning")

        let lapsed = try reduce("scene-plane-lapsed", previous: held)
        let stale = lapsed.windows.values.filter {
            $0.freshness == .expectedStale
        }.count
        XCTAssertGreaterThan(stale, 0, "the lapsed fixture retains windows")
        XCTAssertEqual(
            NOWMirrorSource.observationPhrase(lapsed.windows.count,
                                              replica: lapsed),
            "\(lapsed.windows.count) windows, \(stale) expected-stale",
            "a mirror that could not see the machine must say so on the "
            + "line a person actually reads")
    }

    func testTheReducerKeepsTheModalWindow() throws {
        let scene = try scene()
        let session = MirrorGuestSession(guest: "wire-5490",
                                         incarnation: "session-a")
        let observation = GuestSceneObservation(
            session: session, scene: scene,
            receivedAt: Date(timeIntervalSince1970: 1))
        guard case .accepted(let replica) =
            MirrorReplicaReducer.reduce(observation, previous: nil) else {
            return XCTFail("the reducer rejected a real guest document")
        }
        let titles = replica.windows.values.map(\.window.title).sorted()
        XCTAssertTrue(titles.contains("Set Time Zone"),
                      "the reducer dropped the modal: \(titles)")
        let projected = replica.snapshot.scene.windows.map(\.title)
        XCTAssertTrue(projected.contains("Set Time Zone"),
                      "the projection dropped the modal: \(projected)")
    }
}
