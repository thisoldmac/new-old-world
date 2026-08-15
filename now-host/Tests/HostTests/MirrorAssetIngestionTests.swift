import XCTest
@testable import Host

/// Ingesting a pack from the connected machine.
///
/// The wire itself is not exercised here — that needs a Macintosh, and
/// nothing in this file should be read as evidence one has answered. What
/// IS covered is the seam either side of the wire, which is where this
/// route can fail silently: the name the pack is written under, and the
/// account it gives of what it collected.
@MainActor
final class MirrorAssetIngestionTests: XCTestCase {

    // MARK: - the pack's name is load-bearing

    /// `AssetPack` finds packs by the `pack-` prefix and nothing else.
    /// A generated id that missed it would write a perfectly good pack
    /// into the store that the renderer could never see.
    func testGeneratedPackIDCarriesThePrefixAssetPackSearchesFor() {
        XCTAssertTrue(MirrorAssetIngestion.newPackID().hasPrefix("pack-"))
    }

    /// **Newest-first is a STRING sort.** `AssetPack.discover` orders pack
    /// directories with `sorted(by: >)` and calls the first one the
    /// newest, which is true only while the id is fixed-width and
    /// zero-padded. Drop the padding — `H` instead of `HH` — and
    /// `pack-2026-08-14-9…` sorts above `pack-2026-08-14-10…`, so the
    /// older pack wins and nothing anywhere says so.
    func testLaterPackIDsSortAboveEarlierOnesAsStrings() {
        /* Two times an hour apart chosen to straddle a single-digit /
           double-digit hour boundary in every time zone: 24 consecutive
           hours means one of these pairs is 9→10 wherever this runs. */
        for hour in 0..<24 {
            let early = Date(timeIntervalSince1970: 1_770_000_000
                             + Double(hour) * 3600)
            let late = early.addingTimeInterval(3600)
            let earlyID = MirrorAssetIngestion.newPackID(at: early)
            let lateID = MirrorAssetIngestion.newPackID(at: late)
            XCTAssertEqual([earlyID, lateID].sorted(by: >),
                           [lateID, earlyID],
                           "the later pack must sort first: "
                           + "\(earlyID) then \(lateID)")
            XCTAssertEqual(earlyID.count, lateID.count,
                           "ids must be fixed width or the sort is a lie: "
                           + "\(earlyID) vs \(lateID)")
        }
    }

    // MARK: - finding the extractor

    func testExtractorEnvironmentOverrideWins() throws {
        let tool = try makeExecutable(named: "fake-extractor")
        let url = MirrorAssetIngestion.extractorURL(
            environment: [MirrorAssetIngestion.extractorEnvironmentKey:
                            tool.path])
        XCTAssertEqual(url?.path, tool.path)
    }

    /// A path that is set but cannot be run is not something to search
    /// past — whoever set it meant it, and a silent fall back to a
    /// checkout's copy would run a different extractor than the one named.
    func testExtractorOverrideThatIsNotExecutableResolvesToNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-extractor-\(UUID().uuidString)")
        XCTAssertNil(MirrorAssetIngestion.extractorURL(
            environment: [MirrorAssetIngestion.extractorEnvironmentKey:
                            missing.path]))
    }

    // MARK: - the share has to contain the art

    private func file(_ path: String, required: Bool) -> MirrorAssetIngestion
        .RequiredFile {
        .init(path: path, role: "test", required: required, why: "because")
    }

    /// The folders the share must hold are the FIRST SEGMENT of each
    /// required path — the whole path is not a folder in the share root,
    /// and checking for one would refuse every share that works.
    func testRequiredRootsAreTopLevelFoldersNotWholePaths() {
        let roots = MirrorAssetIngestion.requiredRoots([
            file("System Folder/System", required: true),
            file("System Folder/Fonts/Chicago", required: true),
        ])
        XCTAssertEqual(roots, ["System Folder"])
    }

    /// An optional file's folder is not a precondition. Its absence is
    /// already a note, so demanding the folder would refuse a share that
    /// can build a perfectly good pack.
    func testOptionalFilesDoNotConstrainTheShare() {
        let roots = MirrorAssetIngestion.requiredRoots([
            file("System Folder/System", required: true),
            file("Documents/Wallpaper", required: false),
        ])
        XCTAssertEqual(roots, ["System Folder"])
    }

    /// The refusal a PowerBook 1400c earned on 2026-08-14. It must name
    /// the remedy — the old one named a path, which told the person where
    /// it broke and nothing about what to do.
    func testShareRefusalNamesTheRemedyAndWhatIsShared() {
        let refusal = MirrorAssetIngestion.shareRefusal(
            missing: ["System Folder"], share: "Lab")
        XCTAssertEqual(refusal.code, "now-assets-not-in-share")
        XCTAssertTrue(refusal.message.contains("System Folder"),
                      refusal.message)
        XCTAssertTrue(refusal.message.contains("Lab"), refusal.message)
        XCTAssertTrue(refusal.message.contains("whole disk"),
                      refusal.message)
        XCTAssertTrue(refusal.message.contains("Nothing has been copied"),
                      refusal.message)
    }

    /// A guest that did not say what it shares must not produce a
    /// sentence with a hole in it.
    func testShareRefusalReadsWhenTheShareIsUnnamed() {
        let refusal = MirrorAssetIngestion.shareRefusal(
            missing: ["System Folder"], share: nil)
        XCTAssertFalse(refusal.message.contains("“”"), refusal.message)
        XCTAssertFalse(refusal.message.contains("is ."), refusal.message)
        XCTAssertTrue(refusal.message.contains("whole disk"),
                      refusal.message)
    }

    // MARK: - what the pack says it holds

    /// The counts come out of the pack's OWN manifest. This is the check
    /// that the ingestion reports the artifact rather than its intent.
    func testScopeNotesReadCountsFromTheManifest() throws {
        let resources = try makeResources(manifest: """
            {"icons": {"count": 116},
             "cursors": {"count": 40},
             "appicons": {"count": 12}}
            """)
        let note = MirrorAssetIngestion.scopeNotes(at: resources).joined()
        XCTAssertTrue(note.contains("116 generic icons"), note)
        XCTAssertTrue(note.contains("40 cursors"), note)
        XCTAssertTrue(note.contains("12 application icons"), note)
    }

    /// A pack whose manifest cannot be read must say that, not report
    /// zeroes — "0 application icons" and "I could not look" are very
    /// different sentences and only one of them is true.
    func testScopeNotesSayWhenTheManifestCannotBeRead() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: resources) }
        let note = MirrorAssetIngestion.scopeNotes(at: resources).joined()
        XCTAssertTrue(note.contains("could not read"), note)
        XCTAssertFalse(note.contains("0 application icons"), note)
    }

    // MARK: -

    private func makeResources(manifest: String) throws -> URL {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: resources) }
        try manifest.write(
            to: resources.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        return resources
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true,
                                        encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
