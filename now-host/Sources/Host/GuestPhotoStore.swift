import AppKit
import Foundation
import ImageIO

struct GuestPhotoStore {
    enum StoreError: LocalizedError {
        case missingApplicationSupport
        case unreadableImage
        case couldNotEncode

        var errorDescription: String? {
            switch self {
            case .missingApplicationSupport:
                return "The Application Support folder is unavailable."
            case .unreadableImage:
                return "That file could not be read as an image."
            case .couldNotEncode:
                return "The image could not be saved as a PNG."
            }
        }
    }

    private let fileManager: FileManager
    private let root: URL

    init(fileManager: FileManager = .default, root: URL? = nil) throws {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            guard let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first else {
                throw StoreError.missingApplicationSupport
            }
            self.root = support
                .appendingPathComponent(ProductIdentity.displayName,
                                        isDirectory: true)
                .appendingPathComponent("Machine Photos", isDirectory: true)
        }
    }

    func photoURL(for guest: GuestID) -> URL {
        root.appendingPathComponent(guest.slug).appendingPathExtension("png")
    }

    func loadPhoto(for guest: GuestID) -> NSImage? {
        NSImage(contentsOf: photoURL(for: guest))
    }

    @discardableResult
    func importPhoto(from source: URL, for guest: GuestID) throws -> NSImage {
        guard let imageSource = CGImageSourceCreateWithURL(
            source as CFURL, nil) else {
            throw StoreError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary) else {
            throw StoreError.unreadableImage
        }
        guard let data = CaptureDecoder.pngData(image) else {
            throw StoreError.couldNotEncode
        }

        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true)
        try data.write(to: photoURL(for: guest), options: .atomic)
        guard let stored = NSImage(data: data) else {
            throw StoreError.couldNotEncode
        }
        return stored
    }

    func removePhoto(for guest: GuestID) throws {
        let url = photoURL(for: guest)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

@MainActor
final class GuestPhotoModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var error: String?
    private let store: GuestPhotoStore?
    private var guest: GuestID?

    init(store: GuestPhotoStore? = try? GuestPhotoStore()) {
        self.store = store
    }

    func focus(on guest: GuestID?) {
        self.guest = guest
        image = guest.flatMap { store?.loadPhoto(for: $0) }
        error = store == nil
            ? GuestPhotoStore.StoreError.missingApplicationSupport
                .localizedDescription
            : nil
    }

    func importPhoto(from url: URL) {
        guard let guest, let store else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            image = try store.importPhoto(from: url, for: guest)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removePhoto() {
        guard let guest, let store else { return }
        do {
            try store.removePhoto(for: guest)
            image = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
