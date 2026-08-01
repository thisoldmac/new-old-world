import AppKit
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
    /// Injectable so a test is not a claim about this Mac's sign-in.
    private let driveURL: URL

    @Published private(set) var services: [CloudServiceEntry] = []

    init(listener: GuestListener, defaults: UserDefaults = .standard,
         driveURL: URL = DriveCloudProvider.iCloudDrive) {
        self.listener = listener
        self.defaults = defaults
        self.driveURL = driveURL
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

    /// A denial is not re-askable through the API — macOS only shows
    /// the prompt once. The honest affordance is the door to where the
    /// answer lives.
    func canOpenPrivacySettings(_ service: String) -> Bool {
        guard isEnabled(service) else { return false }
        switch service {
        case "photos":
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .denied || status == .restricted
        case "contacts":
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .denied || status == .restricted
        default:
            return false
        }
    }

    func openPrivacySettings(_ service: String) {
        let pane = service == "photos" ? "Privacy_Photos" : "Privacy_Contacts"
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?"
                + pane) {
            NSWorkspace.shared.open(url)
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

    /* Drive's switch IS the share, so the row wears the same toggle as
       every other service (a lone button here read as an inconsistency,
       and was one). On remembers where the share pointed and moves it
       to iCloud Drive; off puts it back — so a person can flip Drive
       without losing the folder they had chosen. */

    private static let previousRootKey = "cloud.drive.previousRoot"

    var driveShared: Bool {
        services.first { $0.service == "drive" }?.state == "serving"
    }

    var driveAvailable: Bool {
        services.first { $0.service == "drive" }?.state != "unavailable"
    }

    func setDriveShared(_ on: Bool) {
        if on {
            let current = listener.share.root
            if current.standardizedFileURL.path
                != driveURL.standardizedFileURL.path {
                defaults.set(current.path, forKey: Self.previousRootKey)
            }
            listener.share.root = driveURL
        } else {
            /* The remembered folder may be gone by now; the share's own
               default (Downloads) is the honest fallback, not a share
               that points at nothing. */
            if let previous = defaults.string(forKey: Self.previousRootKey),
               FileManager.default.fileExists(atPath: previous) {
                listener.share.root = URL(fileURLWithPath: previous)
            } else {
                listener.share.root = FileManager.default.urls(
                    for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
            }
        }
        refresh()
    }
}
