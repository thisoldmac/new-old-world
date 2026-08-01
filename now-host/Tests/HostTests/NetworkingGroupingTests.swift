import XCTest
@testable import Host

/// The one piece of real logic on the host's Networking page: turning the
/// guest's flat `[label, value]` rows back into its four groups.
///
/// It parses SHAPE rather than matching titles — a header is a row whose
/// label is not indented, a member is indented by two, and a group
/// explaining its own emptiness sends `  (token)` with the sentence as its
/// value. That choice is what keeps this side from knowing the guest's
/// vocabulary, and these tests are what make it true rather than intended.
@MainActor
final class NetworkingGroupingTests: XCTestCase {

    /// A fully-configured Mac, in the shape `run_net` emits.
    private let configured: [[String]] = [
        ["This Connection", ""],
        ["  Peer", "PowerBook 1400"],
        ["  Port", "1400"],
        ["  Up", "1h 30m"],
        ["  Round trip", "31 ms"],
        ["TCP/IP", ""],
        ["  Address", "10.91.5.115"],
        ["  Subnet mask", "255.255.255.0"],
        ["  Hardware address", "00:05:02:1a:2b:3c"],
        ["Ports", ""],
        ["  enet", "DP83916  slot E"],
        ["Connections", ""],
        ["  (undocumented)",
         "Open Transport publishes no way to list a Mac's connections. "
         + "Nothing is wrong with this Mac."]
    ]

    func testTheGuestsFourGroupsSurviveTheFlattening() {
        let out = NetworkingModel.group(configured)

        XCTAssertEqual(out.map(\.title),
                       ["This Connection", "TCP/IP", "Ports", "Connections"],
                       "the guest's order and titles come through untouched")
        XCTAssertEqual(out[0].rows.count, 4)
        XCTAssertEqual(out[1].rows.count, 3)
        XCTAssertEqual(out[2].rows.count, 1)
    }

    func testAnIndentedLabelLosesItsIndentButNotItsSpaces() {
        let out = NetworkingModel.group(configured)

        XCTAssertEqual(out[1].rows.map(\.label),
                       ["Address", "Subnet mask", "Hardware address"],
                       "only the two-space indent is removed")
        XCTAssertEqual(out[1].rows[2].value, "00:05:02:1a:2b:3c")
    }

    /// The page's whole argument. A group that cannot be filled sends a
    /// token and a sentence rather than nothing, and both must survive:
    /// the token so this side can style on it without matching prose, the
    /// sentence because it is the guest's wording and exonerates the Mac.
    func testAnEmptyGroupCarriesItsReasonAndItsSentence() {
        let out = NetworkingModel.group(configured)
        let connections = out[3]

        XCTAssertTrue(connections.rows.isEmpty,
                      "the connections group has no rows, by construction")
        XCTAssertEqual(connections.reason, "undocumented",
                       "the token is kept apart from the prose")
        XCTAssertTrue(
            connections.sentence?.contains("Nothing is wrong with this Mac")
                == true,
            "and the sentence that exonerates the machine survives")
    }

    /// Parsing shape rather than titles is what lets the guest grow a
    /// group without a host change. If this test needs editing to add a
    /// section, the parser has started knowing the vocabulary.
    func testAGroupThisSideHasNeverHeardOfStillRenders() {
        var rows = configured
        rows.append(["AppleTalk", ""])
        rows.append(["  Node", "65.128"])

        let out = NetworkingModel.group(rows)

        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out[4].title, "AppleTalk")
        XCTAssertEqual(out[4].rows.first?.label, "Node")
    }

    func testRowsBeforeAnyHeaderAreDroppedRatherThanCrashing() {
        let out = NetworkingModel.group([["  Orphan", "x"],
                                         ["Real", ""],
                                         ["  Kept", "y"]])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "Real")
        XCTAssertEqual(out[0].rows.count, 1)
    }

    func testMalformedRowsAreSkipped() {
        let out = NetworkingModel.group([["Header", ""],
                                         ["  only-one-element"],
                                         [],
                                         ["  Good", "v"]])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rows.map(\.label), ["Good"],
                       "a row without a value pair is skipped, not guessed at")
    }

    func testRowIdentifiersAreUniqueAcrossGroups() {
        let out = NetworkingModel.group(configured)
        let ids = out.flatMap { $0.rows.map(\.id) }

        XCTAssertEqual(ids.count, Set(ids).count,
                       "SwiftUI would silently drop rows sharing an id")
    }

    func testAnEmptyAnswerIsAnEmptyPageRatherThanAFabricatedOne() {
        XCTAssertTrue(NetworkingModel.group([]).isEmpty)
    }
}
