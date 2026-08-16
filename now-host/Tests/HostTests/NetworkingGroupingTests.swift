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
        XCTAssertEqual(out[0].rows.count, 3,
                       "Peer, port and uptime. The link's TIMING row is not "
                           + "here any more — see the test below.")
        XCTAssertEqual(out[1].rows.count, 3)
        XCTAssertEqual(out[2].rows.count, 1)
    }

    /// **The link's timing rows are not on this page.** Round trip, receive
    /// window, window peak and quiet time measure the WIRE, not this
    /// machine's networking, and they are read on Diagnostics beside
    /// `wirestat` now (034, G-1). Networking keeps the facts.
    ///
    /// Dropped in the grouping rather than hidden in the view, so the page's
    /// own "3 of 4 groups answered" verdict counts what it actually draws.
    /// One list decides it — `GuestLinkTiming` — read from here and from
    /// `DiagnosticsModel`, so the four rows cannot land on both pages or on
    /// neither.
    func testTheLinksTimingRowsAreLeftForDiagnostics() {
        let out = NetworkingModel.group(configured + [
            ["  Receive window", "8192 bytes"],
            ["  Window peak", "16384 bytes"],
            ["  Quiet for", "4s"],
        ])
        let everyLabel = out.flatMap { $0.rows.map(\.label) }

        for timing in GuestLinkTiming.labels {
            XCTAssertFalse(everyLabel.contains(timing),
                           "\(timing) belongs to the wire, not to this "
                               + "machine's networking.")
        }
        XCTAssertTrue(everyLabel.contains("Peer"),
                      "Only the timing goes. Who is on the link, and on "
                          + "which port, is still a fact this page shows.")
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

    // MARK: - Degrading honestly

    /// A Mac with no Open Transport — the shape a lesser machine sends.
    ///
    /// Not a hypothetical: the guest emits exactly this when
    /// `now_net_probe` finds no OT, and it is the difference between the
    /// two guests this page has to survive. The link group is measured by
    /// the wire itself and is always there; everything that needs OT to be
    /// asked comes back as a token and a sentence.
    private let withoutOpenTransport: [[String]] = [
        ["This Connection", ""],
        ["  Peer", "Macintosh IIci"],
        ["  Port", "1400"],
        ["  Up", "4m"],
        ["TCP/IP", ""],
        ["  (noOpenTransport)",
         "Open Transport is not available. CarbonLib 1.6 or later "
         + "provides it."],
        ["Ports", ""],
        ["  (noOpenTransport)",
         "Open Transport is not available. CarbonLib 1.6 or later "
         + "provides it."],
        ["Connections", ""],
        ["  (undocumented)",
         "Open Transport publishes no way to list a Mac's connections. "
         + "Nothing is wrong with this Mac."]
    ]

    /// The two machines produce DIFFERENT pages, and both are correct.
    ///
    /// The failure this guards against is a page that renders the smaller
    /// machine as the larger one minus some blanks — same four cards, same
    /// rows, three of them empty. Here the smaller machine's cards carry a
    /// state and a sentence instead of rows, and no row is missing a value.
    func testALesserMachineGetsFewerRowsRatherThanEmptyOnes() {
        let full = NetworkingModel.group(configured)
        let lesser = NetworkingModel.group(withoutOpenTransport)

        XCTAssertEqual(full.map(\.title), lesser.map(\.title),
                       "both machines answer with the same four groups")
        XCTAssertEqual(full.map(\.state),
                       [.reported, .reported, .reported, .undocumented])
        XCTAssertEqual(lesser.map(\.state),
                       [.reported, .unavailable, .unavailable, .undocumented])

        XCTAssertEqual(NetworkingModel.reportedCount(of: full), 3)
        XCTAssertEqual(NetworkingModel.reportedCount(of: lesser), 1)
        XCTAssertEqual(NetworkingModel.health(of: full), .partial)
        XCTAssertEqual(NetworkingModel.health(of: lesser), .partial)

        for page in [full, lesser] {
            for section in page where !section.rows.isEmpty {
                XCTAssertTrue(section.rows.allSatisfy { !$0.value.isEmpty },
                              "no card shows a labelled blank")
            }
            for section in page where section.rows.isEmpty {
                XCTAssertNotNil(section.sentence,
                                "an empty group always says why, in the "
                                + "guest's words")
            }
        }
    }

    /// A field the guest could not measure must not arrive as a label with
    /// nothing beside it. The PowerPC guest omits the row outright; a guest
    /// that sends the label anyway would otherwise draw a measurement that
    /// was never taken.
    func testAMemberRowWithNoValueIsDroppedRatherThanShownBlank() {
        let out = NetworkingModel.group([["TCP/IP", ""],
                                         ["  Address", "10.91.5.115"],
                                         ["  Router", ""],
                                         ["  Name server", "   "],
                                         ["  MTU", "1500 bytes"]])

        XCTAssertEqual(out[0].rows.map(\.label), ["Address", "MTU"],
                       "a value-less field is absent, not blank")
    }

    /// A wholly blank pair is indistinguishable from a header by shape, so
    /// without this guard it opens a nameless group and every row after it
    /// lands inside it — under the previous group's real rows, silently.
    func testABlankPairDoesNotOpenANamelessGroup() {
        let out = NetworkingModel.group([["TCP/IP", ""],
                                         ["  Address", "10.91.5.115"],
                                         ["", ""],
                                         ["  Subnet mask", "255.255.255.0"]])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "TCP/IP")
        XCTAssertEqual(out[0].rows.count, 2,
                       "the rows after the blank stay in the real group")
    }

    // MARK: - What the page says about a state

    /// The state comes from the guest's TOKEN. Deriving it from the
    /// sentence would make the page's chip change the day somebody
    /// reworded a string, and the reword would look like a behaviour
    /// change to nobody.
    func testAnUnknownTokenSaysNothingRatherThanAccusingTheMachine() {
        let out = NetworkingModel.group([["AppleTalk", ""],
                                         ["  (zoneless)", "No zones here."]])

        XCTAssertEqual(out[0].state, .silent)
        XCTAssertFalse(out[0].state.isProblem,
                       "a token this side has never met is not a fault")
        XCTAssertEqual(out[0].sentence, "No zones here.",
                       "and the guest's sentence is still what is shown")
    }

    /// The page's whole argument, as an assertion. `undocumented` means
    /// nobody can ask — the machine is fine — so it must never be the one
    /// state the page colours as trouble.
    func testOnlyADeclineIsColouredAsAProblem() {
        let problems = NetworkingModel.Section.State.allTestCases
            .filter(\.isProblem)

        XCTAssertEqual(problems, [.declined])
    }

    func testEveryStateHasAWordAndNoneOfThemIsError() {
        for state in NetworkingModel.Section.State.allTestCases {
            XCTAssertFalse(state.label.isEmpty)
            XCTAssertFalse(state.label.lowercased().contains("error"),
                           "exactly one of these states is the machine's "
                           + "doing, and none of them is a crash")
        }
    }

    func testHealthCountsGroupsRatherThanJudgingThem() {
        XCTAssertEqual(NetworkingModel.health(of: []), .unknown)
        XCTAssertEqual(
            NetworkingModel.health(of: NetworkingModel.group(
                [["TCP/IP", ""], ["  Address", "10.0.0.1"]])),
            .reporting)
        XCTAssertEqual(
            NetworkingModel.health(of: NetworkingModel.group(
                [["TCP/IP", ""], ["  (refused)", "This Mac declined."]])),
            .silent)
    }
}

private extension NetworkingModel.Section.State {
    /// Written out rather than derived from `CaseIterable`: the point of
    /// the two tests above is to fail when a state is ADDED without
    /// somebody deciding whether it is the machine's fault, and a
    /// conformance that enumerated itself would quietly absorb the new
    /// one.
    static let allTestCases: [Self] = [
        .reported, .unavailable, .declined, .notMeasured, .undocumented,
        .silent
    ]
}
