import Foundation
import XCTest
@testable import Host

/// The Drive toggle's semantics: on points Sharing at iCloud Drive,
/// off puts back the folder that was shared before — flipping Drive
/// must never cost a person the share they had chosen.
@MainActor
final class CloudModuleModelTests: XCTestCase {
    private var listener: GuestListener!
    private var defaults: UserDefaults!
    private var drive: URL!
    private var elsewhere: URL!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        defaults = UserDefaults(
            suiteName: "now.tests.\(UUID().uuidString)")
        drive = try folder("drive")
        elsewhere = try folder("elsewhere")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: drive)
        try? FileManager.default.removeItem(at: elsewhere)
    }

    private func folder(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func model() -> CloudModuleModel {
        CloudModuleModel(listener: listener, defaults: defaults,
                         driveURL: drive)
    }

    func testTheToggleRemembersAndRestoresTheShare() {
        listener.share.root = elsewhere
        let model = model()
        model.setDriveShared(true)
        XCTAssertEqual(listener.share.root.path, drive.path)
        model.setDriveShared(false)
        XCTAssertEqual(listener.share.root.path, elsewhere.path,
                       "flipping Drive must not cost the chosen folder")
    }

    func testTogglingOnWhileAlreadyOnDoesNotForgetTheRealPrevious() {
        listener.share.root = elsewhere
        let model = model()
        model.setDriveShared(true)
        model.setDriveShared(true)
        model.setDriveShared(false)
        XCTAssertEqual(listener.share.root.path, elsewhere.path,
                       "a second On must not remember iCloud Drive "
                           + "as the folder to go back to")
    }

    func testTheDownloadsSettingDefaultsToLong640AndPersists() {
        let model = model()
        XCTAssertEqual(model.downloadSize("photos"), .long640,
                       "the default fits the screens the fetch is for")
        model.setDownloadSize("photos", .original)
        XCTAssertEqual(model.downloadSize("photos"), .original)
        XCTAssertEqual(
            defaults.string(forKey: PhotosCloudProvider.downloadSizeKey),
            "original",
            "written where the provider's get pipeline reads it")
        XCTAssertTrue(model.hasDownloadSize("photos"))
        XCTAssertFalse(model.hasDownloadSize("contacts"),
                       "only the service whose originals dwarf the guest")
    }

    /// Every stop persists through the model the same way — the picker
    /// (bound to DownloadSize.allCases) follows automatically, so this
    /// proves the storage half only.
    func testEveryDownloadStopPersistsThroughTheModel() {
        let model = model()
        model.setDownloadSize("photos", .long1024)
        XCTAssertEqual(model.downloadSize("photos"), .long1024)
        model.setDownloadSize("photos", .long1600)
        XCTAssertEqual(model.downloadSize("photos"), .long1600)
        XCTAssertEqual(
            defaults.string(forKey: PhotosCloudProvider.downloadSizeKey),
            "long1600")
    }

    /// A setting written by the version before this one names a token
    /// that no longer exists. It must read as the default, not crash and
    /// not silently mean something else — the same graceful reading the
    /// wire gives a retired token, one storage layer down.
    func testARetiredFitTokenInDefaultsReadsAsTheDefault() {
        defaults.set("fit2048", forKey: PhotosCloudProvider.downloadSizeKey)
        XCTAssertEqual(model().downloadSize("photos"), .long640)
    }

    func testEveryDownloadSizeHasADistinctLabel() {
        let labels = PhotosCloudProvider.DownloadSize.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "a picker with two identical rows is a bug " +
                           "a person can't tell apart on screen")
        XCTAssertEqual(labels, ["Default size", "1600 px",
                                "1024 px", "640 px"])
    }

    func testAVanishedPreviousFolderFallsBackToDownloads() throws {
        listener.share.root = elsewhere
        let model = model()
        model.setDriveShared(true)
        try FileManager.default.removeItem(at: elsewhere)
        model.setDriveShared(false)
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first!
        XCTAssertEqual(listener.share.root.path, downloads.path,
                       "a share pointing at nothing is not an answer")
    }
}
