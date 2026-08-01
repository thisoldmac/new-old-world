import Foundation
import XCTest
@testable import Host
import MirrorKit

/// **Naming the window, or naming nothing.**
///
/// A window act is addressed by a reference only the machine mints, so a
/// gesture on a drawn title bar has to be turned into one — and the whole
/// risk of this file's subject is that the turn can succeed at the WRONG
/// window. Closing the neighbouring document is not a degraded outcome; it
/// is a worse one than doing nothing, and it happens silently.
///
/// So every test below is about a refusal except the two that are about a
/// match. There is deliberately no "best effort" case to assert, because
/// there is no best-effort branch: the resolver answers a reference or a
/// sentence.
@MainActor
final class MirrorWindowResolverTests: XCTestCase {

    private static func target(title: String = "Untitled",
                               psn: String = "0.8192",
                               occurrence: Int = 0) -> WindowTarget {
        WindowTarget(id: "\(psn)/\(title)#\(occurrence)", psn: psn,
                     title: title, occurrence: occurrence)
    }

    /// One `elements` reply, in the shape the guest emits
    /// (`now-guest-ppc/src/observe/observe.c`): a tree under the command's
    /// own key, processes, then windows carrying ref, title and occurrence.
    private static func reply(_ windows: [(String, String, Int)])
        -> CommandResult {
        let rows = windows.map { ref, title, occurrence in
            """
            {"ref":"\(ref)","title":"\(title)","occurrence":\(occurrence),\
            "z":0,"visible":true,"kind":8,\
            "bounds":{"left":0,"top":0,"right":100,"bottom":100},\
            "controls":[]}
            """
        }
        let json = """
        {"elements":{"scope":"front","count":\(windows.count),\
        "truncated":false,"live":\(windows.count),\
        "processes":[{"name":"SimpleText","signature":"ttxt",\
        "serialHi":0,"serialLo":8192,"front":true,"bind":"ok",\
        "stampTicks":42,"windows":[\(rows.joined(separator: ","))]}]}}
        """
        /* Decoded from the guest's own JSON rather than built as values: an
           object-shaped reply lands in `outputObjects`, and a test that
           assembled the tree by hand could pass on a shape no guest sends. */
        let output = try! JSONDecoder().decode(
            [String: JSONValue].self, from: Data(json.utf8))
        return CommandResult(id: 1, ok: true, output: nil,
                             outputObjects: output, error: nil)
    }

    private func resolver(
        answering result: @escaping @MainActor () -> CommandResult,
        seen: @escaping @MainActor ([String: String]) -> Void = { _ in }
    ) -> MirrorWindowResolver {
        MirrorWindowResolver { name, args in
            XCTAssertEqual(name, "elements",
                           "the reference is minted by `elements` and by "
                               + "nothing else")
            seen(args)
            return result()
        }
    }

    /// The ordinary case: one window of that title, and its reference goes
    /// out — aimed at the process the SCENE says owns it, never at "the
    /// frontmost", which is the form the act plane refuses on the strength of
    /// a measurement.
    func testOneMatchResolvesAndTheWalkIsAimedByTheScenesProcess() async {
        var args: [String: String] = [:]
        let resolver = resolver(
            answering: { Self.reply([("now-window-a", "Untitled", 0)]) },
            seen: { args = $0 })
        let resolution = await resolver.reference(for: Self.target())
        XCTAssertEqual(resolution, .reference("now-window-a"))
        XCTAssertEqual(args["serialHi"], "0")
        XCTAssertEqual(args["serialLo"], "8192")
    }

    /// Two windows of one name is ordinary — two untitled documents — and the
    /// occurrence is what tells them apart. Both sides count it the same way
    /// by construction; this is the assertion that the counting is USED.
    func testTheOccurrencePicksBetweenIdenticallyTitledWindows() async {
        let resolver = resolver(answering: {
            Self.reply([("now-window-a", "Untitled", 0),
                        ("now-window-b", "Untitled", 1)])
        })
        let second = await resolver.reference(
            for: Self.target(occurrence: 1))
        XCTAssertEqual(second, .reference("now-window-b"))
    }

    /// …and when it does not pick one out, nothing is sent. This is the test
    /// that stands between a mirror and a closed document nobody asked about.
    func testAnAmbiguousIdentityRefusesRatherThanTakingTheFirst() async {
        let resolver = resolver(answering: {
            Self.reply([("now-window-a", "Untitled", 0),
                        ("now-window-b", "Untitled", 1)])
        })
        let resolution = await resolver.reference(
            for: Self.target(occurrence: 7))
        guard case .unresolved(let reason) = resolution else {
            return XCTFail("""
                an identity that matches two windows resolved to one of them. \
                Acting on whichever came first acts on a window the person is \
                not looking at, and they are never told.
                """)
        }
        XCTAssertTrue(reason.contains("2 windows"), reason)
    }

    /// A title the walk did not see. The drawing is older than the walk, or
    /// the window has closed — either way there is nothing to address, and
    /// saying which is the honest answer rather than picking a neighbour.
    func testAWindowTheWalkDidNotSeeIsRefusedByName() async {
        let resolver = resolver(answering: {
            Self.reply([("now-window-a", "Read Me", 0)])
        })
        let resolution = await resolver.reference(for: Self.target())
        guard case .unresolved(let reason) = resolution else {
            return XCTFail("a missing window resolved to something")
        }
        XCTAssertTrue(reason.contains("\"Untitled\""), reason)
    }

    /// A machine that will not take the observation. The refusal is the
    /// MACHINE's, forwarded — this side does not rewrite it, and does not
    /// turn it into "nothing happened".
    func testAMachineThatWillNotBeObservedIsQuoted() async {
        let resolver = resolver(answering: {
            CommandResult(id: 1, ok: false, output: nil,
                          error: .init(code: "unknown-command",
                                       message: "no such command"))
        })
        let resolution = await resolver.reference(for: Self.target())
        guard case .unresolved(let reason) = resolution else {
            return XCTFail("a refused observation produced a reference")
        }
        XCTAssertTrue(reason.contains("no such command"), reason)
        XCTAssertTrue(reason.contains("unknown-command"), reason)
    }

    /// A process serial that is not one. Nothing is asked of the Mac at all:
    /// half a PSN names no process, and sending it would be a call the guest
    /// refuses after a person was shown a window that looked draggable.
    func testAnUnparseablePsnAsksTheMacNothing() async {
        var asked = false
        let resolver = MirrorWindowResolver { _, _ in
            asked = true
            return Self.reply([])
        }
        let resolution = await resolver.reference(
            for: Self.target(psn: "front"))
        XCTAssertFalse(asked)
        guard case .unresolved(let reason) = resolution else {
            return XCTFail("a malformed serial resolved to a reference")
        }
        XCTAssertTrue(reason.contains("\"front\""), reason)
    }

    func testTheSerialSplitRefusesHalfOfOne() {
        XCTAssertNil(MirrorWindowResolver.serial("8192"))
        XCTAssertNil(MirrorWindowResolver.serial("0."))
        XCTAssertNil(MirrorWindowResolver.serial("0.1.2"))
        let pair = MirrorWindowResolver.serial("0.8192")
        XCTAssertEqual(pair?.hi, 0)
        XCTAssertEqual(pair?.lo, 8192)
    }
}
