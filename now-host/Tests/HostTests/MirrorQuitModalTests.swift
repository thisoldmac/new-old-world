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
