import Foundation
import Contacts
import Photos
import XCTest
@testable import Host

/// The Drive toggle's semantics: on points Sharing at iCloud Drive,
/// off puts back the folder that was shared before — flipping Drive
/// must never cost a person the share they had chosen.
@MainActor
final class CloudModuleModelTests: XCTestCase {
    private final class AuthorizationSpy: CloudAuthorizationHandling {
        var photos: PHAuthorizationStatus = .notDetermined
        var contacts: CNAuthorizationStatus = .notDetermined
        var photoRequests = 0
        var contactRequests = 0

        func photosStatus() -> PHAuthorizationStatus { photos }
        func contactsStatus() -> CNAuthorizationStatus { contacts }
        func requestPhotos(
            _ completion: @escaping @MainActor @Sendable () -> Void
        ) {
            photoRequests += 1
            completion()
        }
        func requestContacts(
            _ completion: @escaping @MainActor @Sendable () -> Void
        ) {
            contactRequests += 1
            completion()
        }
    }

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

    private func model(
        authorization: any CloudAuthorizationHandling = AuthorizationSpy()
    ) -> CloudModuleModel {
        CloudModuleModel(listener: listener, defaults: defaults,
                         driveURL: drive, authorization: authorization)
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

    func testGrantAccessHandsTheRequestToTheNativeAuthorizationOwner() {
        let authorization = AuthorizationSpy()
        defaults.set(true, forKey: PhotosCloudProvider.enabledKey)
        defaults.set(true, forKey: ContactsCloudProvider.enabledKey)
        let model = model(authorization: authorization)

        XCTAssertTrue(model.canRequestAccess("photos"))
        XCTAssertTrue(model.canRequestAccess("contacts"))
        model.requestAccess("photos")
        model.requestAccess("contacts")

        XCTAssertEqual(authorization.photoRequests, 1)
        XCTAssertEqual(authorization.contactRequests, 1)
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
