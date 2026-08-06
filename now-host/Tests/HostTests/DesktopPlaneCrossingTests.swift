import XCTest
import MirrorKit
import MirrorKitUI
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

    /// The roster as `readIcons` builds it: pages parsed on their own, the
    /// type pass parsed on its OWN blob, joined by name.
    ///
    /// Not `parseIcons(page + types)`. Concatenating them leaves a quote pair
    /// inside the text and the first `F` row parses as `"F` and is dropped —
    /// which is why "Browse the Internet" alone lost its icon in a render
    /// built that way, on a desktop where every other item had one.
    private func placedItems(_ roster: Roster)
        -> [MirrorKit.Scene.DesktopItem] {
        let types = Dictionary(uniqueKeysWithValues:
            NOWMirrorSource.parseIconTypes(roster.types.output))
        return NOWMirrorSource.applyingArt(
            roster.pages.flatMap { NOWMirrorSource.parseIcons($0.output) },
            types: types)
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

        // THE TYPE PASS ANSWERS IN APPLESCRIPT'S WORDS, AND THE HOST UNDOES
        // IT. `file type` is a `type class`, so this machine said
        // `«class APPL»` for an application and `string` for a text file —
        // and the host used to take the first four characters, giving every
        // icon on every desktop a type of `«cla` or `stri`, which names no
        // file type at all. It cost art rather than contents, which is why
        // nothing ever failed over it.
        //
        // These two assertions were pinned to the WRONG values on 2026-08-06
        // so the defect could not be discovered a third time; they moved with
        // the fix, which is what that note asked for.
        let withArt = placedItems(roster)
        XCTAssertEqual(withArt.first { $0.name == "HELLO_CLAUDE.txt" }?.type,
                       "TEXT",
                       "AppleScript's word for the code, back to the code")
        XCTAssertEqual(withArt.first { $0.name == "HELLO_CLAUDE.txt" }?.creator,
                       "ttxt",
                       "`text returned` is what this Mac called SimpleText's "
                           + "creator — the rendering table is not closed by "
                           + "construction, and that row is the proof")
        XCTAssertEqual(withArt.first { $0.name == "harness" }?.type, "APPL")
        XCTAssertEqual(withArt.first { $0.name == "harness" }?.creator, "????")
    }

    /// What the type is FOR. The pack carries 914 per-application icons keyed
    /// `creator__type`; a mangled type missed every one of them and the whole
    /// desktop drew as generic-by-kind. This asserts the join, over the same
    /// machine's own roster — not over a message this test wrote.
    func testTheRealTypesReachThePerApplicationIconPack() throws {
        let roster = try JSONDecoder().decode(
            Roster.self, from: try fixture("now-finder-desktop-roster"))
        let items = placedItems(roster)

        /* Against the GENERIC art, not against nil. `icon(for:)` never
           answers nil for a file — it falls through to the generic page or
           application — so "an icon came back" was true the whole time the
           mirror was drawing twenty identical pages. The pack's art and the
           generic art are distinct cached instances, so identity is the
           question worth asking. */
        let generic = IconAtlas.namedIcon("document")
        let genericApp = IconAtlas.namedIcon("application")

        // SimpleText's own document icon: creator `ttxt`, type `TEXT`. Under
        // the mangling this asked the pack for `stri`, missed, and drew the
        // generic page.
        let hello = try XCTUnwrap(items.first { $0.name == "HELLO_CLAUDE.txt" })
        XCTAssertFalse(IconAtlas.icon(for: hello) === generic,
                       "ttxt__TEXT is in the pack, and this drew the generic "
                           + "document page instead")

        // The aliases on that desktop resolve through their target's creator
        // (QuickTime Player is `TVOD`, Sherlock 2 is `fndf`).
        for name in ["QuickTime Player", "Sherlock 2"] {
            let item = try XCTUnwrap(items.first { $0.name == name })
            let art = IconAtlas.icon(for: item)
            XCTAssertNotNil(art)
            XCTAssertFalse(art === generic || art === genericApp,
                           "\(name): \(item.creator ?? "nil")__"
                               + "\(item.type ?? "nil") drew generic art")
        }

        // Every file the type pass named got its type — all fourteen. The
        // six without one are the folders and the disk, which the pass
        // deliberately never asks about.
        XCTAssertEqual(items.filter { $0.type != nil }.count, 14)

        // And nothing carries a mangled code any more.
        for item in items {
            for code in [item.type, item.creator].compactMap({ $0 }) {
                XCTAssertEqual(code.count, 4, "\(item.name): \(code)")
                XCTAssertFalse(code.contains("«"), "\(item.name): \(code)")
            }
        }
    }

    /// The decoder's own edges, including the one that must stay honest: a
    /// rendering it does not know answers nil rather than a guess, because a
    /// wrong OSType is a wrong icon drawn confidently.
    func testAnUnknownRenderingRefusesRatherThanGuessing() {
        XCTAssertEqual(NOWMirrorSource.osType(fromAppleScript: "«class APPL»"),
                       "APPL")
        XCTAssertEqual(NOWMirrorSource.osType(fromAppleScript: "«class ????»"),
                       "????")
        XCTAssertEqual(NOWMirrorSource.osType(fromAppleScript: "string"),
                       "TEXT")
        XCTAssertEqual(NOWMirrorSource.osType(fromAppleScript: "MooV"), "MooV",
                       "a guest that one day coerces properly passes through")
        XCTAssertNil(NOWMirrorSource.osType(fromAppleScript: ""))
        XCTAssertNil(NOWMirrorSource.osType(fromAppleScript: "some word"))
        XCTAssertNil(NOWMirrorSource.osType(fromAppleScript: "«class APP»"),
                     "a code that is not four characters is not a code")
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

    /// The same desktop, drawn, for eyes rather than assertions — one
    /// machine's own roster over one machine's own scene. Opt-in:
    /// NOW_RENDER_DIR names a directory.
    func testRenderTheDesktopFromThatMachinesRoster() throws {
        guard let dir = ProcessInfo.processInfo
            .environment["NOW_RENDER_DIR"] else { return }
        let roster = try JSONDecoder().decode(
            Roster.self, from: try fixture("now-finder-desktop-roster"))
        var scene = try JSONDecoder().decode(
            MirrorKit.Scene.self, from: try fixture("now-scene-desktop-bare"))
        scene.desktopItems = placedItems(roster)
        let png = try RenderShot.png(scene: scene)
        try png.write(to: URL(fileURLWithPath: "\(dir)/desktop-roster.png"))
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
