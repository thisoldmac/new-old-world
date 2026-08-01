import Combine
import Contacts
import Foundation
import Photos

/// The host's side of the iCloud page: which services this Mac offers a
/// classic one, and the switches and grants that change the answer. The
/// truth lives in the provider registry — this model only reads it,
/// flips the enabled keys, and asks macOS for the grants the providers
/// then observe.
@MainActor
final class CloudModuleModel: ObservableObject {
    private let listener: GuestListener
    private let defaults: UserDefaults

    @Published private(set) var services: [CloudServiceEntry] = []

    init(listener: GuestListener, defaults: UserDefaults = .standard) {
        self.listener = listener
        self.defaults = defaults
    }

    func refresh() {
        services = listener.cloud.entries()
    }

    // MARK: - Switches

    private static let enabledKeys = [
        "photos": PhotosCloudProvider.enabledKey,
        "contacts": ContactsCloudProvider.enabledKey,
    ]

    func hasSwitch(_ service: String) -> Bool {
        Self.enabledKeys[service] != nil
    }

    func isEnabled(_ service: String) -> Bool {
        Self.enabledKeys[service].map(defaults.bool(forKey:)) ?? false
    }

    func setEnabled(_ service: String, _ on: Bool) {
        guard let key = Self.enabledKeys[service] else { return }
        defaults.set(on, forKey: key)
        refresh()
    }

    // MARK: - Grants

    /// Whether the row should offer a grant button: on, but macOS has
    /// not yet been asked. A denial is not re-askable from here — the
    /// row's detail says where to go instead.
    func canRequestAccess(_ service: String) -> Bool {
        guard isEnabled(service) else { return false }
        switch service {
        case "photos":
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
                == .notDetermined
        case "contacts":
            return CNContactStore.authorizationStatus(for: .contacts)
                == .notDetermined
        default:
            return false
        }
    }

    func requestAccess(_ service: String) {
        switch service {
        case "photos":
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor in self.refresh() }
            }
        case "contacts":
            CNContactStore().requestAccess(for: .contacts) { _, _ in
                Task { @MainActor in self.refresh() }
            }
        default:
            break
        }
    }

    // MARK: - Drive

    /// Drive's switch is the share itself; this is the same act as
    /// choosing iCloud Drive in the Files footer, surfaced where the
    /// services live.
    func shareDrive() {
        listener.share.root = DriveCloudProvider.iCloudDrive
        refresh()
    }

    func canShareDrive() -> Bool {
        services.first { $0.service == "drive" }?.state == "off"
    }
}
