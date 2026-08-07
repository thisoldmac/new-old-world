import XCTest
import MirrorKit
import MirrorKitUI
import NOWAgentIntegration
@testable import Host

/// **One machine, one answer: nothing on this side decides how big the
/// guest's screen is.**
///
/// The guest measures its own `gdRect` and sends `scene.screen.w/h`.
/// That is the only statement of the fact, and every consumer here reads
/// it. On 2026-08-07 four places had decided for themselves instead —
/// 800×600 in the host's mirror window, 800×600 in `ScenePoller`,
/// 1024×768 in `PlatinumTheme.logicalSize`, 640×480 in the sentence a
/// language model reads before it aims a click — and nothing was
/// visibly wrong, which is precisely the state AGENTS.md's
/// most-repeated rule describes: *the control-frame cap lived in prose,
/// in the sender, and as a different number in the receiver's buffer;
/// nothing was wrong until a message grew past the smallest of the
/// three.*
///
/// A hand-fixed set of four rots the moment somebody adds a fifth, so
/// this maintains **no list**: it walks the source trees and derives the
/// vocabulary it looks for from MirrorKit's own type name.
///
/// **What this gate does NOT cover** — stated plainly, because an
/// overstated gate is worse than none:
///
/// - **It reads text; it does not evaluate.** A screen size assembled at
///   runtime (`let w = 800; ScreenSize(w: w, h: 600)`), read from a
///   defaults key, or arrived at by arithmetic passes. The literal pair
///   is the shape the defect has actually taken four times, not the only
///   shape it could take.
/// - **It gates the HOST side only** — `now-host/Sources` and
///   `mirror/host/MirrorKit/Sources`. It says nothing about the guests'
///   C, where a screen literal would also be wrong; the PowerPC guest's
///   two `SetRect(…, 800, 600)` fallbacks were fixed in the same commit
///   by routing every measurement through `core/screen_bounds.c`, and
///   nothing here would notice them coming back.
/// - **It exempts tests and fixtures entirely**, and with them the
///   `MirrorApp` dev CLI, whose `--render-ops` and `--display-demo`
///   paths build synthetic scenes and are entitled to state the surface
///   they render onto. A fixture that says 832×624 is stating *its own*
///   screen and is correct to; which of those are fixtures and which are
///   assumptions is a judgement no scan can make, so this does not try.
///   `MirrorApp`'s one LIVE path is covered by the poller pairing check
///   instead.
/// - **Zero passes.** `ScreenSize.unknown` has to be written down
///   somewhere, so the scan objects only to a *plausible* size.
/// - **The prompt half proves the string, not the plumbing.** It proves
///   `ChatSystemPrompt` says what it was told and refuses to invent; it
///   does not prove `HostAppState` hands it the live screen, and a
///   provider wired to `{ nil }` would satisfy it while telling every
///   model "unknown" forever.
/// - **It cannot see prose.** A doc comment or a README asserting a
///   screen size is invisible here — `GateSource` strips comments on
///   purpose, for the reason that file explains.
final class GuestScreenIsOneAnswerGateTests: XCTestCase {

    // MARK: - The trees this walks, derived rather than listed

    private static let productionRoots = [
        "now-host/Sources",
        "mirror/host/MirrorKit/Sources",
    ]

    private func swiftFiles(under relative: String) throws -> [String] {
        let root = GateSource.repoRoot.appendingPathComponent(relative)
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            XCTFail("no such tree: \(relative)")
            return []
        }
        var out: [String] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            /* Relative to the repo, NEVER the absolute path. This
               checkout is itself a worktree under `.claude/worktrees/`,
               so an absolute-path exclusion for `/.claude/` skipped
               every file in the tree and the scan passed by reading
               nothing. Watched, while mutating: a fifth screen size in
               HostRootView.swift went unnamed. */
            let file = String(url.path.dropFirst(
                GateSource.repoRoot.path.count + 1))
            guard !file.hasPrefix(".claude/"),
                  !file.hasPrefix("archive/"),
                  !file.contains("/Tests/"),
                  /* MirrorApp is a dev CLI, and its `--render-ops` /
                     `--display-demo` paths BUILD scenes rather than
                     receive them: their screen is the fixture's own
                     surface, which the fixture is entitled to state.
                     Its one live path is covered instead by
                     `testEveryLivePollerAsksTheGuestItsScreen`. */
                  !file.contains("/MirrorApp/") else { continue }
            out.append(file)
        }
        return out.sorted()
    }

    /// The type a guest screen size is spelled as, read from MirrorKit's
    /// own source rather than typed here — so renaming it renames what
    /// this gate hunts for, instead of quietly ending the hunt.
    private func screenSizeTypeName() throws -> String {
        let scene = try GateSource.hostSwift(
            "mirror/host/MirrorKit/Sources/MirrorKit/Scene.swift")
        let pattern = #"struct\s+(\w*ScreenSize\w*)\s*:"#
        let re = try NSRegularExpression(pattern: pattern)
        let ns = scene as NSString
        guard let m = re.firstMatch(
            in: scene, range: NSRange(location: 0, length: ns.length)) else {
            XCTFail("MirrorKit no longer declares a ScreenSize type; this "
                    + "gate derives its vocabulary from that declaration "
                    + "and has just stopped looking for anything")
            return "ScreenSize"
        }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - No host-side source states the guest's screen

    /// A screen size built out of integer literals is this side deciding
    /// a fact about another machine. Watched fail by adding a fifth.
    func testNoProductionSourceConstructsAGuestScreenFromLiterals() throws {
        let typeName = try screenSizeTypeName()
        /* Three shapes, all of them "two numbers, written down":
             ScreenSize(w: 800, h: 600)
             screen: .init(w: 800, h: 600)
             <name with screen/logical in it> = CGSize(width: 1024, …) */
        /* `[1-9]` and not `\d`: ZERO IS ALLOWED, because zero is how
           `unknown` is spelled — `ScreenSize.unknown` has to be written
           down somewhere, and a screen of no pixels is not a plausible
           machine anybody could mistake for an answer. What this
           objects to is a believable size. */
        let patterns = [
            #"\#(typeName)\s*\(\s*w:\s*[1-9]"#,
            #"screen[A-Za-z]*\s*:\s*\.init\(\s*w:\s*[1-9]"#,
            #"(?i)(screen|logical)\w*\s*(:\s*CGSize)?\s*=\s*CGSize\("#
                + #"\s*width:\s*[1-9]\d*\s*,\s*height:\s*[1-9]"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        var offences: [String] = []
        var scanned = 0
        for root in Self.productionRoots {
            for file in try swiftFiles(under: root) {
                scanned += 1
                let text = try GateSource.hostSwift(file)
                let ns = text as NSString
                for re in patterns {
                    for m in re.matches(
                        in: text,
                        range: NSRange(location: 0, length: ns.length)) {
                        let line = 1 + text.prefix(m.range.location)
                            .filter { $0 == "\n" }.count
                        offences.append(
                            "\(file):\(line): \(ns.substring(with: m.range))")
                    }
                }
            }
        }
        /* A SCAN THAT READ NOTHING PASSES. That is how the first cut of
           this gate reported green while a fifth screen size sat in
           HostRootView.swift, so the count is asserted before the
           finding. */
        XCTAssertGreaterThan(scanned, 200,
                             "this gate scanned \(scanned) files; it is "
                                + "not reading the source trees it names")
        XCTAssertEqual(
            offences, [],
            """
            A host-side source states how big the guest's screen is. \
            The guest measures it and sends scene.screen.w/h; read that. \
            Where the answer is needed before any scene has arrived, the \
            state is `unknown` — Scene.ScreenSize.unknown, or nil — and \
            it must stay legible as unknown rather than become a \
            plausible number. Offending sites:
            \(offences.joined(separator: "\n"))
            """)
    }

    /// The fallback that fed the mirror's whole drawing surface. Gone,
    /// and it must not come back under any name — `SceneRenderer`
    /// answers nil for an unmeasured screen and the callers refuse.
    @MainActor
    func testTheRendererHasNoSurfaceOfItsOwnToFallBackOn() throws {
        XCTAssertNil(
            SceneRenderer(scene: try scene(screenJSON: nil)).logicalSize,
            "a scene whose guest never said its screen size still "
                + "produced a logical surface, so every rect in it was "
                + "placed in an invented coordinate space")
        XCTAssertEqual(
            SceneRenderer(scene: try scene(screenJSON: #"{"w":832,"h":624}"#))
                .logicalSize,
            CGSize(width: 832, height: 624))
    }

    /// A scene as the wire delivers one. `screenJSON: nil` is a guest that
    /// said nothing about its screen — which decodes to `unknown`, and
    /// that decode is half of what this gate is checking.
    private func scene(screenJSON: String?) throws -> MirrorKit.Scene {
        let document = """
            {"version":2,"seq":1,"capturedAt":1,"source":"peek",
             "screen":\(screenJSON ?? #"{"w":0,"h":0}"#),
             "apps":[],"windows":[],
             "meta":{"errors":[],"coverage":[]}}
            """
        return try JSONDecoder().decode(
            MirrorKit.Scene.self, from: Data(document.utf8))
    }

    /// `unknown` and `empty` are different words here on purpose.
    func testUnknownIsAStateAndNotAZeroSizedScreen() {
        XCTAssertFalse(MirrorKit.Scene.ScreenSize.unknown.isKnown)
        XCTAssertNil(MirrorKit.Scene.ScreenSize.unknown.known)
        XCTAssertNil(MirrorKit.Scene.ScreenSize(w: 800, h: 0).known,
                     "half a size is not a size")
        XCTAssertEqual(MirrorKit.Scene.ScreenSize(w: 832, h: 624).known?.w,
                       832)
    }

    /// **A poller that never asked publishes `unknown` forever.**
    /// `ScenePoller.screen` starts unknown by design — nothing has asked
    /// the machine yet — so the construction is only half of it. Derived
    /// by pairing, per file, rather than by naming the five call sites.
    func testEveryLivePollerAsksTheGuestItsScreen() throws {
        var missing: [String] = []
        var checked = 0
        for root in Self.productionRoots {
            for file in try swiftFiles(under: root)
            where !file.hasSuffix("ScenePoller.swift") {
                let text = try GateSource.hostSwift(file)
                guard text.contains("ScenePoller(") else { continue }
                checked += 1
                if !text.contains("detectScreen()") { missing.append(file) }
            }
        }
        XCTAssertGreaterThan(checked, 0,
                             "no file constructs a ScenePoller; this "
                                + "pairing check just stopped checking")
        XCTAssertEqual(
            missing, [],
            "a ScenePoller is built and never asked the guest how big "
                + "its screen is, so every scene it publishes carries "
                + "`unknown`: \(missing)")
    }

    // MARK: - What the model is told

    private func wirePrompt(screen: ChatSystemPrompt.Screen?) -> String {
        ChatSystemPrompt.compose(
            health: .unavailable(.host),
            origin: .guestWire, screen: screen)
    }

    /// **The most consequential of the four.** A model told the screen is
    /// 640×480 while it is 800×600 aims at the wrong place and is
    /// confident about it, and the miss looks like an act-plane defect —
    /// which this arc has spent days chasing twice.
    func testAnUnmeasuredScreenIsSaidToBeUnknownRatherThanGuessed() throws {
        let prompt = wirePrompt(screen: nil)
        XCTAssertTrue(prompt.contains("not known"),
                      "the prompt does not tell the model the screen size "
                        + "is unestablished:\n\(prompt)")
        let sizes = try NSRegularExpression(pattern: #"\d{2,4}\s*[xX]\s*\d{2,4}"#)
        let ns = prompt as NSString
        let found = sizes.matches(
            in: prompt, range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) }
        XCTAssertEqual(
            found, [],
            "the prompt states a screen size nothing measured: \(found)")
    }

    func testAMeasuredScreenReachesTheModelExactly() throws {
        let screen = try XCTUnwrap(ChatSystemPrompt.Screen(w: 832, h: 624))
        let prompt = wirePrompt(screen: screen)
        XCTAssertTrue(prompt.contains("832x624"), prompt)
        let sizes = try NSRegularExpression(pattern: #"\d{2,4}\s*[xX]\s*\d{2,4}"#)
        let ns = prompt as NSString
        let found = Set(sizes.matches(
            in: prompt, range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) })
        XCTAssertEqual(found, ["832x624"],
                       "the prompt carries a second screen size beside the "
                        + "one the guest measured: \(found.sorted())")
    }

    /// Zero is not a size, and a caller that has zeroes has `unknown`.
    func testTheModelIsNeverToldAboutAZeroSizedScreen() {
        XCTAssertNil(ChatSystemPrompt.Screen(w: 0, h: 0))
        XCTAssertNil(ChatSystemPrompt.Screen(w: 800, h: 0))
    }

    /// The prompt's own source, read past its comments, must not carry a
    /// screen size at all: the sentence is composed from what it was
    /// given or it says unknown, and there is no third branch.
    func testThePromptSourceHoldsNoScreenSizeOfItsOwn() throws {
        let source = try GateSource.hostSwift(
            "now-host/Sources/Host/Chat/ChatSystemPrompt.swift")
        let re = try NSRegularExpression(pattern: #"\d{2,4}\s*[xX]\s*\d{2,4}"#)
        let ns = source as NSString
        let found = re.matches(
            in: source, range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) }
        XCTAssertEqual(
            found, [],
            "ChatSystemPrompt states a screen size in its own text: "
                + "\(found). It is handed one or it says so.")
    }
}
