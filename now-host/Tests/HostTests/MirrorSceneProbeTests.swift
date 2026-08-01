import Foundation
import XCTest
@testable import Host

/// **The cheap question's answer, and the two fields that must not be in it.**
///
/// The probe's whole purpose is a ratio: many control round trips, few
/// transfers. Two fields of `axsnap`'s reply would destroy that ratio
/// silently — the token would change on every call, the loop would fetch on
/// every tick, and every behavioural test would still pass because the page
/// WOULD be up to date. It would just be a poll again, with an extra round
/// trip per fetch for the privilege.
///
/// So they are asserted here, at the one place the ratio is decided.
final class MirrorSceneProbeTests: XCTestCase {

    private func reply(front: String = "Finder",
                       stampTicks: Int = 1_000,
                       minted: Int = 4,
                       hasWindows: Bool = true) -> CommandResult {
        CommandResult(
            id: 1, ok: true, output: nil,
            outputObjects: ["axsnap": .object([
                "front": .object([
                    "name": .string(front),
                    "signature": .string("MACS"),
                    "serialHi": .number(0),
                    "serialLo": .number(8_192),
                    "front": .bool(true),
                    "bind": .string("psn"),
                    "stampTicks": .number(Double(stampTicks)),
                    "hasWindows": .bool(hasWindows),
                    "hasMenus": .bool(true),
                ]),
                "references": .object([
                    "live": .number(Double(minted)),
                    "minted": .number(Double(minted)),
                    "evicted": .number(0),
                    "capacity": .number(32),
                ]),
            ])],
            error: nil)
    }

    private func token(_ result: CommandResult) throws -> String {
        guard case .token(let token) = MirrorSceneProbe.read(result) else {
            throw Unexpected()
        }
        return token
    }

    private struct Unexpected: Error {}

    /// **`stampTicks` is the sample's own clock and moves every call.**
    /// Folding it in would make every probe report a change.
    func testTheTokenIgnoresTheSampleClock() throws {
        XCTAssertEqual(
            try token(reply(stampTicks: 1_000)),
            try token(reply(stampTicks: 999_999)),
            "the token moved because the guest's tick counter moved. Nothing "
                + "on the screen changed; this loop would now fetch a scene "
                + "on every tick and call it change detection.")
    }

    /// **The reference counters are somebody else's activity.** An agent
    /// taking an observation moves them without anything on screen moving.
    func testTheTokenIgnoresWhatOtherCallersObserved() throws {
        XCTAssertEqual(try token(reply(minted: 4)),
                       try token(reply(minted: 4_000)))
    }

    /// What it does see: who is in front, and whether that program has
    /// windows at all.
    func testTheTokenSeesTheFrontProcessAndItsWindows() throws {
        XCTAssertNotEqual(try token(reply(front: "Finder")),
                          try token(reply(front: "SimpleText")))
        XCTAssertNotEqual(try token(reply(hasWindows: true)),
                          try token(reply(hasWindows: false)))
    }

    /// A missing key is a different token, not the same one shorter. Two
    /// replies that differ only in which field is absent must not collide.
    func testAnAbsentFieldIsNotTheSameAsAnEmptyOne() {
        let named = MirrorSceneProbe.token(front: ["name": .string("Finder")])
        let bound = MirrorSceneProbe.token(front: ["bind": .string("Finder")])
        XCTAssertNotEqual(named, bound)
    }

    // MARK: - the three readings

    /// A guest that does not serve the command has ANSWERED. The loop stops
    /// asking and says so.
    func testAnUnknownCommandIsAnAnswerAndNotSilence() {
        let result = CommandResult(
            id: 1, ok: false, output: nil,
            error: .init(code: "unknown-command",
                         message: "this Mac serves no axsnap"))
        guard case .unsupported(let reason) = MirrorSceneProbe.read(result)
        else {
            return XCTFail("a refusal read as something else")
        }
        XCTAssertTrue(reason.contains("axsnap"))
    }

    /// **A dropped wire is not a statement about the command.** Reading it
    /// as one would let a reconnect race permanently downgrade the loop to
    /// its ceiling.
    func testATransportFailureLeavesTheProbeAlone() {
        for code in ["not-connected", "disconnected", "timeout"] {
            let result = CommandResult(
                id: 1, ok: false, output: nil,
                error: .init(code: code, message: "no Mac is connected"))
            XCTAssertEqual(MirrorSceneProbe.read(result), .unanswered,
                           "\(code) was read as a guest that cannot answer "
                               + "the probe")
        }
    }

    /// ok:true carrying nothing readable is a guest this probe cannot be run
    /// against — not silence, and not a token made of empty fields.
    func testAnUnreadableAnswerIsNotAToken() {
        let result = CommandResult(id: 1, ok: true, output: nil,
                                   outputObjects: nil, error: nil)
        guard case .unsupported = MirrorSceneProbe.read(result) else {
            return XCTFail("an answer with no front process read as a token")
        }
    }
}
