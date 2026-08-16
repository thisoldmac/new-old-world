import XCTest
@testable import Host

/// The vocabulary rule, pinned. These are copy decisions, so the assertions
/// are the exact strings a person will read — a test that only checked "the
/// name appears somewhere in it" would pass on every register mistake this
/// file exists to prevent.
final class MachineNamingTests: XCTestCase {

    func testNamedMachineBeatsBothFallbackRegisters() {
        XCTAssertEqual(MachineNaming.title("Zulu"), "Zulu")
        XCTAssertEqual(MachineNaming.sentence("Zulu"), "Zulu")
        XCTAssertEqual(MachineNaming.possessive("Zulu"), "Zulu’s")
    }

    /// The two registers are the whole point: a title says the proper noun,
    /// a sentence says the plain reference, and neither borrows the other.
    func testUnnamedMachineTakesTheRegisterOfItsPosition() {
        XCTAssertEqual(MachineNaming.title(""), "Guest")
        XCTAssertEqual(MachineNaming.sentence(""), "the guest")
        XCTAssertEqual(MachineNaming.possessive(""), "the guest’s")
    }

    func testNoMachineReadsTheSameAsAnUnnamedOne() {
        XCTAssertEqual(MachineNaming.title(nil), "Guest")
        XCTAssertEqual(MachineNaming.sentence(nil), "the guest")
        XCTAssertEqual(MachineNaming.several([]), "no guest")
    }

    /// The host's own placeholder reaches display code as an ordinary
    /// string; treating it as a name would print "Guest" beside real
    /// machine names as though a Mac had chosen it.
    func testHostPlaceholdersAreNotNames() {
        XCTAssertEqual(MachineNaming.sentence(Session.unnamedGuest),
                       "the guest")
        XCTAssertEqual(MachineNaming.sentence("   "), "the guest")
        XCTAssertEqual(MachineNaming.title("Guest"), "Guest")
    }

    func testSeveralMachinesReadAsAList() {
        XCTAssertEqual(MachineNaming.several(["Zulu"]), "Zulu")
        XCTAssertEqual(MachineNaming.several(["Zulu", "Atlas"]),
                       "Zulu and Atlas")
        XCTAssertEqual(MachineNaming.several(["Zulu", "Atlas", "pb1400c"]),
                       "Zulu, Atlas and pb1400c")
    }

    /// Unnamed machines collapse instead of repeating, so a roster of two
    /// silent Macs cannot read as one Mac counted twice.
    func testUnnamedMachinesCollapseInAList() {
        XCTAssertEqual(MachineNaming.several([nil]),
                       "an unnamed Guest")
        XCTAssertEqual(MachineNaming.several(["Zulu", nil]),
                       "Zulu and an unnamed Guest")
        XCTAssertEqual(MachineNaming.several([nil, nil, "Zulu"]),
                       "Zulu and 2 unnamed Guests")
    }

    /// A machine called Atlas must not become "Atlas's".
    func testPossessiveOfANameEndingInS() {
        XCTAssertEqual(MachineNaming.possessive("Atlas"), "Atlas’")
        XCTAssertEqual(MachineNaming.possessive("PB 180cs"), "PB 180cs’")
        XCTAssertEqual(MachineNaming.possessive("pb1400c"), "pb1400c’s")
    }

    /// The overload a module actually calls: it holds a connection, not a
    /// name, and disconnected must reach the same fallback as an empty one.
    func testAConnectionNamesItselfOrFallsBack() {
        XCTAssertEqual(MachineNaming.title(.connected(named: "Zulu")), "Zulu")
        XCTAssertEqual(MachineNaming.possessive(.connected(named: "Atlas")),
                       "Atlas’")
        XCTAssertEqual(MachineNaming.sentence(.disconnected),
                       "the guest")
        XCTAssertEqual(MachineNaming.title(.connecting), "Guest")
    }

    /// A sentence may start with the plain reference; the noun inside it
    /// stays lowercase, and a machine's own spelling is never touched.
    func testSentenceStartMovesOnlyTheFirstCharacter() {
        XCTAssertEqual(
            MachineNaming.startingSentence(MachineNaming.possessive(nil)),
            "The guest’s")
        XCTAssertEqual(MachineNaming.startingSentence("pb1400c’s"),
                       "Pb1400c’s")
    }

    func testThisMacHasOneSpelling() {
        XCTAssertEqual(MachineNaming.thisMac, "this Mac")
    }
}
