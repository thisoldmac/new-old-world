import XCTest
import MirrorKit
@testable import Host

/// The desktop plane, from one live Macintosh's own bytes to a published
/// scene — the two halves meeting in a test.
///
/// Every input here was captured in ONE connection to ONE build-verified
/// guest (`1bff0bd2ca39`, mac99/OS 9.1 emulated, VM `nowvm-dtop`,
/// 2026-08-06) and committed as fixtures:
///
/// - `now-finder-desktop-roster.json` — the guest's verbatim replies to the
///   four AppleScripts `NOWMirrorSource.readIcons` sends for the desktop
///   container: three paged item passes and the type pass.
/// - `now-scene-desktop-bare.json` — one structural scene from the same
///   connection. It carries **no `desktopItems` key at all**, which is the
///   guest being honest rather than failing: no producer reports that plane.
///
/// Nothing in this file constructs the messages it then parses, which is
/// what the older icon tests do — they are good tests of the parser and can
/// say nothing about a real desktop. That mattered: `desktopItems` read nil
/// on every drive from 2026-08-01, the roster read was blamed, and the
/// roster read had been working the whole time.
@MainActor
final class DesktopPlaneCrossingTests: XCTestCase {

    private struct Roster: Decodable {
        struct Page: Decodable { let output: String }
        let pages: [Page]
        let types: Page
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures"),
            "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    /// The read the 2026-08-05 entry called a whole failure. It is not one:
    /// the guest answers `osaErr 0` and three complete pages, and the host's
    /// own parser turns them into twenty placed icons.
    func testTheGuestsOwnPagesParseIntoTheWholeDesktop() throws {
        let roster = try JSONDecoder().decode(
            Roster.self, from: try fixture("now-finder-desktop-roster"))

        var items: [MirrorKit.Scene.DesktopItem] = []
        for (index, page) in roster.pages.enumerated() {
            XCTAssertEqual(NOWMirrorSource.iconPageTotal(page.output), 20,
                           "every page must agree on the total; page "
                               + "\(index + 1) did not")
            items += NOWMirrorSource.parseIcons(page.output)
        }
        // 8 + 8 + 4: the paging the host asks for, as the Finder served it.
        XCTAssertEqual(items.count, 20)
        XCTAssertEqual(items.map(\.name).prefix(2), ["Trash", "Macintosh HD"])
        XCTAssertEqual(items.first { $0.name == "Macintosh HD" }?.kind, "disk")
        XCTAssertTrue(
            items.contains { $0.name == "NOW-DTOP-9c41" },
            "the marker folder made on that VM's desktop, which is how a "
                + "render is attributed to this machine and no other")

        // THE TYPE PASS ANSWERS, AND ITS ANSWER IS NOT A TYPE CODE. Recorded
        // rather than asserted away, because it is what this machine said and
        // a test that expected "TEXT" here would be describing a Macintosh
        // nobody has: OSADoScript renders its result in SOURCE form, so
        // `file type of` comes back as the AppleScript literal `«class APPL»`
        // (or `string` for a coerced one), and the host takes the first four
        // characters of it. Every icon on this desktop therefore carries a
        // type of `«cla` or `stri`, which names no file type at all.
        //
        // It costs art, not contents, which is why it never showed up as a
        // failure — and it is a SEPARATE defect from the retention this file
        // exists for. Pinned here so it cannot be re-discovered a third time.
        let withArt = NOWMirrorSource.parseIcons(
            roster.pages[0].output + roster.types.output)
        XCTAssertEqual(withArt.first { $0.name == "HELLO_CLAUDE.txt" }?.type,
                       "stri",
                       "if this ever reads TEXT the art join has been fixed "
                           + "and this expectation should move with it")
        XCTAssertEqual(withArt.first { $0.name == "harness" }?.type, "«cla")
    }

    /// The defect, end to end. The roster crosses, and then an ordinary
    /// poll arrives carrying no desktop plane — and the icons must still be
    /// there. Before the retention landed this assertion read nil.
    func testTheRosterSurvivesTheNextRealSceneFromTheSameMachine() throws {
        let sceneData = try fixture("now-scene-desktop-bare")
        let roster = try JSONDecoder().decode(
            Roster.self, from: try fixture("now-finder-desktop-roster"))
        let icons = roster.pages.flatMap {
            NOWMirrorSource.parseIcons($0.output)
        }

        let session = MirrorGuestSession(guest: "nowvm-dtop",
                                         incarnation: "1bff0bd2ca39")
        var scene = try JSONDecoder().decode(MirrorKit.Scene.self,
                                             from: sceneData)
        XCTAssertNil(scene.desktopItems,
                     "the fixture's value is the ABSENT key; a scene that "
                         + "reported the plane would prove nothing about "
                         + "retaining it")
        scene.seq = 1
        let first = try accept(scene, session: session, previous: nil)

        // What `withIcons` does on the real path: the roster is added to
        // the scene the guest just published, and enriched in.
        var contributed = first.snapshot.scene
        contributed.desktopItems = icons
        let enriched = try XCTUnwrap(
            MirrorReplicaReducer.enrich(contributed, previous: first),
            "the enrichment must be accepted at the sequence it describes")
        XCTAssertEqual(enriched.snapshot.scene.desktopItems?.count, 20)

        // The next poll: the SAME real scene one sequence later, which is
        // what a machine sitting still actually sends.
        scene.seq = 2
        let next = try accept(scene, session: session, previous: enriched)

        XCTAssertEqual(next.snapshot.scene.desktopItems?.count, 20,
                       "a scene that never reports the desktop plane erased "
                           + "it, so the Mirror drew a bare desktop over a "
                           + "machine showing twenty icons")
        XCTAssertTrue(
            next.snapshot.scene.desktopItems?
                .contains { $0.name == "NOW-DTOP-9c41" } ?? false)
    }

    private func accept(_ scene: MirrorKit.Scene,
                        session: MirrorGuestSession,
                        previous: MirrorReplica?) throws -> MirrorReplica {
        let observation = GuestSceneObservation(session: session,
                                                scene: scene,
                                                receivedAt: Date())
        switch MirrorReplicaReducer.reduce(observation, previous: previous) {
        case .accepted(let replica): return replica
        case .rejected(let reason):
            throw NSError(domain: "reduce", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reason)"])
        }
    }
}
