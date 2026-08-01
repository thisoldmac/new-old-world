import XCTest
@testable import Host

/// The name bridge: every name this Mac can hold must project to a name
/// the classic Mac can hold, and every projected name must resolve back
/// to the file it came from. The failure this guards against is a
/// listing that advertises a file no file.get can reach.
final class ClassicNameTests: XCTestCase {

    // MARK: - Pass-through

    func testALegalNamePassesThroughUntouched() {
        XCTAssertEqual(ClassicName.project("Report.txt"), "Report.txt")
        XCTAssertEqual(ClassicName.project("\u{F8FF} Notes"),
                       "\u{F8FF} Notes",
                       "the Apple logo exists only in MacRoman")
    }

    func testADecomposedNamePassesThroughComposed() {
        // As the file system yields it: e + combining acute.
        let name = ClassicName.project("cafe\u{301}.txt")
        XCTAssertEqual(name, "café.txt")
        XCTAssertEqual(name.data(using: .macOSRoman)?.count, 8)
    }

    /// The limit is MacRoman bytes, the unit HFS enforces — not UTF-8
    /// bytes, which would refuse accented names the other machine holds.
    func testTheCapCountsMacRomanBytesNotUTF8() {
        let name = String(repeating: "é", count: 31)
        XCTAssertEqual(ClassicName.project(name), name,
                       "31 MacRoman bytes fits, though it is 62 in UTF-8")
    }

    // MARK: - Projection

    func testProjectionIsDeterministic() {
        let name = "A very long file name that HFS could never store.txt"
        XCTAssertEqual(ClassicName.project(name), ClassicName.project(name))
    }

    func testAMangledNameIsLegalAndKeepsItsExtension() {
        let out = ClassicName.project(
            "A very long file name that HFS could never store.txt")
        XCTAssertLessThanOrEqual(
            out.data(using: .macOSRoman)?.count ?? .max, 31)
        XCTAssertFalse(out.contains(":"))
        XCTAssertTrue(out.hasSuffix(".txt"))
        XCTAssertTrue(out.contains("#"), "a mangled name says so")
    }

    /// Two names that agree for their first 31 bytes must not project to
    /// one name — that was the silent failure of truncation alone.
    func testNamesSharingALongPrefixStayDistinct() {
        let prefix = String(repeating: "x", count: 40)
        XCTAssertNotEqual(ClassicName.project(prefix + " draft.txt"),
                          ClassicName.project(prefix + " final.txt"))
    }

    func testAllUnicodeNamesStayDistinct() {
        // Both substitute to underscores; only the fingerprint tells
        // them apart.
        XCTAssertNotEqual(ClassicName.project("日本語.txt"),
                          ClassicName.project("中文字.txt"))
    }

    func testARenameChangesTheProjection() {
        let long = String(repeating: "y", count: 40)
        XCTAssertNotEqual(ClassicName.project(long + "a.txt"),
                          ClassicName.project(long + "b.txt"),
                          "the fingerprint covers the whole original")
    }

    // MARK: - Directory projection and collisions

    func testDirectoryProjectionLeavesLegalNamesAlone() {
        let map = ClassicName.projectDirectory(["a.txt", "b.txt"])
        XCTAssertEqual(map["a.txt"], "a.txt")
        XCTAssertEqual(map["b.txt"], "b.txt")
    }

    /// A real file may already bear the exact name a sibling's
    /// projection would take. The real name owns it — a name that fits
    /// is never altered — and the projection widens its fingerprint.
    func testAProjectionCollidingWithARealNameWidens() {
        let long = String(repeating: "z", count: 40) + ".txt"
        let squatter = ClassicName.project(long)
        let map = ClassicName.projectDirectory([long, squatter])
        XCTAssertEqual(map[squatter], squatter)
        XCTAssertNotEqual(map[long], squatter,
                          "two entries, two names")
        XCTAssertLessThanOrEqual(
            map[long]?.data(using: .macOSRoman)?.count ?? .max, 31)
    }

    func testDirectoryProjectionIsOrderIndependent() {
        let long = String(repeating: "z", count: 40) + ".txt"
        let squatter = ClassicName.project(long)
        let one = ClassicName.projectDirectory([long, squatter])
        let two = ClassicName.projectDirectory([squatter, long])
        XCTAssertEqual(one, two)
    }

    // MARK: - Resolution

    func testResolveIsTheInverseOfProjection() {
        let names = [
            "ordinary.txt",
            "A very long file name that HFS could never store.txt",
            "日本語.txt",
            "colon: in a name.txt",
            "cafe\u{301} decomposed on disk.txt",
        ]
        let map = ClassicName.projectDirectory(names)
        for real in names {
            XCTAssertEqual(
                ClassicName.resolve(map[real]!, among: names), real,
                "the listing's spelling must find the file")
        }
    }

    func testResolveMatchesComposedSpellingOfADecomposedName() {
        // Disk: decomposed. Wire: what MacRoman round-trips, composed.
        let disk = "cafe\u{301}.txt"
        XCTAssertEqual(ClassicName.resolve("café.txt", among: [disk]), disk)
    }

    func testResolveRefusesANameNothingProjectsTo() {
        XCTAssertNil(ClassicName.resolve("ghost.txt", among: ["real.txt"]))
    }
}
