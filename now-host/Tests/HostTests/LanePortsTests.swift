import Foundation
import XCTest
@testable import Host

/// The attribution the machine guards print, pinned against fixtures.
///
/// Fixtures rather than the real registry, because the interesting cases
/// — a stranger's live block, a lane whose worktree is gone — cannot be
/// arranged on this Mac without starting and killing other people's VMs.
/// The parse-and-decide half is where the guard's usefulness lives; the
/// process half is exercised by `testTheToolAnswersForThisLane` below.
final class LanePortsTests: XCTestCase {

    private func lane(_ block: Int, _ root: String, _ branch: String,
                      base: UInt16, state: String = "idle",
                      rootExists: Bool = true) -> LanePorts.Lane {
        let roles = ["anchor", "wire", "anchor_b", "wire_b",
                     "metal", "spare0", "spare1", "spare2"]
        var ports: [String: UInt16] = [:]
        for (index, role) in roles.enumerated() {
            ports[role] = base + UInt16(index)
        }
        return LanePorts.Lane(
            block: block, laneRoot: root, branch: branch, ports: ports,
            qmpSockets: [], runDirs: [],
            liveness: .init(state: state, laneRootExists: rootExists))
    }

    // MARK: - ownership

    func testAPortIsOwnedByExactlyTheLaneWhoseBlockContainsIt() {
        let lanes = [lane(0, "/w/a", "claude/a", base: 12000),
                     lane(1, "/w/b", "claude/b", base: 12008)]
        XCTAssertEqual(LanePorts.owner(ofPort: 12001, in: lanes)?.laneRoot, "/w/a")
        XCTAssertEqual(LanePorts.owner(ofPort: 12015, in: lanes)?.laneRoot, "/w/b")
        XCTAssertNil(LanePorts.owner(ofPort: 5250, in: lanes))
    }

    /// The distinction the directive is about, and the one the guard
    /// could not make: a port held inside your own block and a port held
    /// inside somebody else's are not the same situation and do not have
    /// the same next step.
    func testSelfAndStrangerGetDifferentInstructions() {
        let mine = lane(0, "/w/a", "claude/a", base: 12000)
        let other = lane(1, "/w/b", "claude/b", base: 12008, state: "busy")
        let lanes = [mine, other]

        let own = LanePorts.attribution(ofPort: 12001, mine: mine, lanes: lanes)
        XCTAssertTrue(own.contains("YOUR OWN lane block"), own)
        XCTAssertTrue(own.contains("tools/lane-ports reclaim"), own)

        let theirs = LanePorts.attribution(ofPort: 12009, mine: mine, lanes: lanes)
        XCTAssertTrue(theirs.contains("claude/b"), theirs)
        XCTAssertFalse(theirs.contains("reclaim"),
                       "reclaiming a stranger's block is the collision this "
                       + "scheme removes; the text must not suggest it: \(theirs)")
        XCTAssertTrue(theirs.contains("12000"),
                      "it should name the ports this lane should be using "
                      + "instead: \(theirs)")
    }

    /// A hand-assigned port has no owner, and saying so plainly is the
    /// whole finding of 2026-08-06 — not "the port is busy" but "nobody
    /// can tell you whose this is".
    func testAnUnclaimedPortSaysItCannotBeAttributed() {
        let mine = lane(0, "/w/a", "claude/a", base: 12000)
        let text = LanePorts.attribution(ofPort: 1840, mine: mine, lanes: [mine])
        XCTAssertTrue(text.contains("No lane claims"), text)
        XCTAssertTrue(text.contains("assigned by hand"), text)
    }

    /// A lane with no claim of its own still gets a usable sentence about
    /// somebody else's port. `mine` is optional because `tools/lane-ports`
    /// may be absent (an old checkout, a stripped tree) and a guard that
    /// crashes when its helper is missing is worse than one that degrades.
    func testAttributionSurvivesHavingNoLaneOfOurOwn() {
        let other = lane(1, "/w/b", "claude/b", base: 12008)
        let text = LanePorts.attribution(ofPort: 12009, mine: nil, lanes: [other])
        XCTAssertTrue(text.contains("claude/b"), text)
    }

    /// A detached HEAD has no branch name, and the label must still name
    /// the lane. The worktree path is the identity; the branch is decoration.
    func testADetachedLaneIsStillNamedByItsWorktree() {
        var detached = lane(2, "/w/c", "", base: 12016)
        detached.branch = nil
        XCTAssertTrue(detached.label.contains("/w/c"), detached.label)
        XCTAssertTrue(detached.label.contains("(detached)"), detached.label)
    }

    // MARK: - the tool itself

    /// `tools/lane-ports` answers, and its answer is stable.
    ///
    /// Determinism is the property the whole scheme rests on: ask twice,
    /// get the same block, with no coordinator between the two questions.
    func testTheToolAnswersForThisLane() throws {
        guard let first = LanePorts.mine() else {
            throw XCTSkip("tools/lane-ports is not executable in this tree")
        }
        let second = try XCTUnwrap(LanePorts.mine())
        XCTAssertEqual(first.block, second.block)
        XCTAssertEqual(first.ports, second.ports)
        XCTAssertEqual(first.ports.count, 8,
                       "a lane gets a block of 8; two is not enough for an "
                       + "A/B drive and a third port is back to guessing")
        let anchor = try XCTUnwrap(first.anchor)
        let wire = try XCTUnwrap(first.wire)
        XCTAssertEqual(wire, anchor + 1)
        XCTAssertTrue((12000..<20000).contains(Int(anchor)),
                      "the region must stay below testListenPort's 20000 "
                      + "floor and out of the ephemeral range: \(anchor)")
    }

    /// The lane's own port is not one of the hand-assigned ones still in
    /// flight, so adopting the scheme cannot walk into a running lane.
    @MainActor
    func testTheDerivedRegionAvoidsEveryPortThisProjectSpellsByHand() throws {
        guard let mine = LanePorts.mine() else {
            throw XCTSkip("tools/lane-ports is not executable in this tree")
        }
        // 1400 anchor worker, 1700–1899 the hand-assigned hostfwds,
        // 5250–5253 the product wire and the metal harnesses.
        let byHand = Set([1400] + Array(1700...1899) + Array(5250...5253)
                         + [Int(SettingsModel.defaultPort)])
        for (role, port) in mine.ports {
            XCTAssertFalse(byHand.contains(Int(port)),
                           "\(role) \(port) collides with a hand-assigned port")
        }
    }
}
