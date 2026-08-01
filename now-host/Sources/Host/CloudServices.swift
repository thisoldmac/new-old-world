import Contacts
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/* The host's half of the cloud.* family: what this Mac's iCloud is
   willing to say to a classic one. One direction by definition — the
   subject is this machine's cloud — so everything here answers and
   nothing asks. Strings leave here already converted (composed,
   MacRoman-expressible): the modern machine is the only side that can
   spell both alphabets, which is the same reason text conversion is
   the host's job in the file family. */

/// A provider's way of saying "refused, and here is why" in the
/// contract's own vocabulary.
enum CloudFault: Error {
    case refuse(code: String, reason: String)

    static func from(_ error: Error) -> (code: String, reason: String) {
        if case .refuse(let code, let reason) = error as? CloudFault {
            return (code, reason)
        }
        return ("io-error", "\(error)")
    }
}

/// Display text the guest can hold: composed, MacRoman-expressible.
/// Length is the schema's business; this is only about the alphabet.
enum CloudText {
    static func displayable(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        if nfc.data(using: .macOSRoman) != nil { return nfc }
        return String(String.UnicodeScalarView(nfc.unicodeScalars.map {
            String($0).data(using: .macOSRoman) != nil ? $0 : "?"
        }))
    }
}

/// One service the host may offer. Everything a provider reports or
/// serves is its own truth — the registry never invents a state, and a
/// service that is off or unauthorized still reports itself so the
/// guest's dropdown can say why.
@MainActor
protocol CloudProvider: AnyObject {
    var service: String { get }
    func entry() -> CloudServiceEntry
    func list(cursor: Int, limit: Int) throws
        -> (entries: [CloudEntry], more: Bool, next: Int)
    func card(item: String) throws -> [[String]]
    func get(item: String) throws -> OutboundFile.Plan
}

@MainActor
final class CloudRegistry {
    private var providers: [CloudProvider] = []

    func register(_ provider: CloudProvider) {
        providers.append(provider)
    }

    func entries() -> [CloudServiceEntry] {
        providers.map { $0.entry() }
    }

    func provider(for service: String) -> CloudProvider? {
        providers.first { $0.service == service }
    }
}

// MARK: - Drive

/// iCloud Drive, deliberately NOT a second browser: its transport is
/// the file family against the share, which already lists placeholders
/// logically and fetches on demand. This provider only reports whether
/// the share IS iCloud Drive, so the guest's dropdown can say so.
@MainActor
final class DriveCloudProvider: CloudProvider {
    let service = "drive"
    private let share: HostShare
    /// Where iCloud Drive lives; injectable so a test is not a claim
    /// about whether this Mac is signed in.
    private let drive: URL

    init(share: HostShare, drive: URL = DriveCloudProvider.iCloudDrive) {
        self.share = share
        self.drive = drive
    }

    nonisolated static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs")
    }

    func entry() -> CloudServiceEntry {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: drive.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            return CloudServiceEntry(
                service: service, label: "iCloud Drive",
                state: "unavailable",
                detail: "This Mac is not signed into iCloud")
        }
        let sharingIt = share.root.standardizedFileURL
            .resolvingSymlinksInPath().path
            == drive.standardizedFileURL
                .resolvingSymlinksInPath().path
        return CloudServiceEntry(
            service: service, label: "iCloud Drive",
            state: sharingIt ? "serving" : "off",
            detail: sharingIt
                ? "Shared - browse it in Files"
                : "Point Sharing at iCloud Drive on the host")
    }

    func list(cursor: Int, limit: Int) throws
        -> (entries: [CloudEntry], more: Bool, next: Int) {
        throw CloudFault.refuse(
            code: "not-listable",
            reason: "Drive is the file share - browse it in Files")
    }

    func card(item: String) throws -> [[String]] {
        throw CloudFault.refuse(
            code: "not-listable",
            reason: "Drive is the file share - browse it in Files")
    }

    func get(item: String) throws -> OutboundFile.Plan {
        throw CloudFault.refuse(
            code: "not-listable",
            reason: "Drive is the file share - fetch from Files")
    }
}

// MARK: - Photos

/// The photo library, newest first. cloud.get delivers one photo as a
/// JPEG through the ordinary file.offer flow; a photo iCloud has not
/// materialized locally starts its download and refuses busy, the same
/// bargain the share strikes for Drive placeholders.
///
/// The fetch is cached per instance: a 40,000-photo library re-run on
/// every page (16 rows at a time, per the wire's own bound) is the
/// difference between one PHAsset query and thousands across a single
/// "128 of many" browse. The cache is invalidated by
/// PHPhotoLibraryChangeObserver rather than a poll, so a library that
/// never changes never pays for a second query either.
@MainActor
final class PhotosCloudProvider: NSObject, CloudProvider,
    PHPhotoLibraryChangeObserver {
    let service = "photos"
    static let enabledKey = "cloud.photos.enabled"
    private let defaults: UserDefaults
    private var cachedAssets: PHFetchResult<PHAsset>?
    private var observing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    deinit {
        if observing {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    private var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func entry() -> CloudServiceEntry {
        guard enabled else {
            return CloudServiceEntry(
                service: service, label: "Photos", state: "off",
                detail: "Turn on in the host's iCloud page")
        }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            let count = assets().count
            return CloudServiceEntry(
                service: service, label: "Photos", state: "serving",
                detail: "\(count) photo\(count == 1 ? "" : "s")")
        case .notDetermined:
            return CloudServiceEntry(
                service: service, label: "Photos", state: "no-access",
                detail: "Grant access in the host's iCloud page")
        default:
            return CloudServiceEntry(
                service: service, label: "Photos", state: "no-access",
                detail: "Photos access is denied on the host")
        }
    }

    /// Requests must not outrun consent: a listing against an
    /// unauthorized library is refused, not empty.
    private func requireAccess() throws {
        guard enabled else {
            throw CloudFault.refuse(code: "off",
                                    reason: "Photos is not being shared")
        }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return
        default:
            throw CloudFault.refuse(
                code: "no-access",
                reason: "The host has not granted Photos access")
        }
    }

    /// The cached fetch, (re)built on first use or after a change
    /// notification. Access must already be checked by the caller.
    private func assets() -> PHFetchResult<PHAsset> {
        if let cachedAssets { return cachedAssets }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(
            key: "creationDate", ascending: false)]
        let fresh = PHAsset.fetchAssets(with: .image, options: options)
        cachedAssets = fresh
        if !observing {
            observing = true
            PHPhotoLibrary.shared().register(self)
        }
        return fresh
    }

    /// PHPhotoLibraryChangeObserver: dropping the cache is the whole
    /// cost of a change, not a re-fetch on the notification thread — the
    /// next list() or entry() rebuilds it lazily.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.cachedAssets = nil
        }
    }

    func list(cursor: Int, limit: Int) throws
        -> (entries: [CloudEntry], more: Bool, next: Int) {
        try requireAccess()
        let assets = assets()
        let start = max(0, cursor - 1)
        guard start < assets.count else {
            return ([], false, assets.count + 1)
        }
        let end = min(start + limit, assets.count)
        var entries: [CloudEntry] = []
        for index in start..<end {
            let asset = assets.object(at: index)
            entries.append(CloudEntry(
                item: asset.localIdentifier,
                title: CloudText.displayable(Self.title(of: asset)),
                subtitle: asset.creationDate.map(Self.shortDate),
                /* PHAssetResource exposes no public byte-size property
                   (no "fileSize" in its documented interface) short of
                   downloading the resource itself, which a listing must
                   never do — so this stays unstated rather than guessed
                   or faked from a private KVC key. */
                bytes: nil,
                modified: asset.creationDate
                    .flatMap(ClassicDate.guestWireSeconds(from:))))
        }
        return (entries, end < assets.count, end + 1)
    }

    func card(item: String) throws -> [[String]] {
        let asset = try self.asset(item)
        var rows: [[String]] = []
        rows.append(["Name", CloudText.displayable(Self.title(of: asset))])
        if let taken = asset.creationDate {
            rows.append(["Taken", Self.longDate(taken)])
        }
        rows.append(["Pixels",
                     "\(asset.pixelWidth) x \(asset.pixelHeight)"])
        if asset.isFavorite { rows.append(["Favorite", "yes"]) }
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            rows.append(["Kind", "screenshot"])
        }
        return rows
    }

    func get(item: String) throws -> OutboundFile.Plan {
        let asset = try self.asset(item)
        /* Local bytes only, synchronously; a photo living in iCloud
           starts its download and refuses busy. Blocking the wire on
           the weather is the one thing a serve must never do. */
        let local = PHImageRequestOptions()
        local.isSynchronous = true
        local.isNetworkAccessAllowed = false
        local.deliveryMode = .highQualityFormat
        var fetched: Data?
        PHImageManager.default().requestImageDataAndOrientation(
            for: asset, options: local) { data, _, _, _ in
            fetched = data
        }
        guard let original = fetched else {
            let warm = PHImageRequestOptions()
            warm.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: warm) { _, _, _, _ in }
            throw CloudFault.refuse(
                code: "busy",
                reason: "iCloud is fetching that photo; ask again shortly")
        }
        let jpeg = try Self.asJPEG(original)
        let stem = (Self.title(of: asset) as NSString).deletingPathExtension
        var plan = OutboundFile.plan(name: stem + ".jpg", data: jpeg,
                                     convertText: false)
        plan.modified = asset.creationDate
            .flatMap(ClassicDate.guestWireSeconds(from:))
        return plan
    }

    private func asset(_ item: String) throws -> PHAsset {
        try requireAccess()
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [item], options: nil).firstObject else {
            throw CloudFault.refuse(code: "not-found",
                                    reason: "no such photo any more")
        }
        return asset
    }

    private static func title(of asset: PHAsset) -> String {
        if let name = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo })?.originalFilename,
            !name.isEmpty {
            return name
        }
        return asset.creationDate.map { "Photo " + shortDate($0) }
            ?? "Photo"
    }

    /// Already JPEG passes through; anything else (HEIC, mostly) is
    /// transcoded, because the classic side's decoders stop around the
    /// formats of its own era.
    static func asJPEG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       nil) else {
            throw CloudFault.refuse(code: "io-error",
                                    reason: "unreadable image data")
        }
        if let type = CGImageSourceGetType(source) as String?,
           type == UTType.jpeg.identifier {
            return data
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CloudFault.refuse(code: "io-error",
                                    reason: "could not make a JPEG")
        }
        CGImageDestinationAddImageFromSource(
            destination, source, 0,
            [kCGImageDestinationLossyCompressionQuality: 0.85]
                as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CloudFault.refuse(code: "io-error",
                                    reason: "could not make a JPEG")
        }
        return out as Data
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return CloudText.displayable(formatter.string(from: date))
    }

    private static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return CloudText.displayable(formatter.string(from: date))
    }
}

// MARK: - Contacts

/// The address book, alphabetical. The card is the deliverable;
/// cloud.get is refused until the classic side can read a vCard.
@MainActor
final class ContactsCloudProvider: CloudProvider {
    let service = "contacts"
    static let enabledKey = "cloud.contacts.enabled"
    private let defaults: UserDefaults
    private let store = CNContactStore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func entry() -> CloudServiceEntry {
        guard enabled else {
            return CloudServiceEntry(
                service: service, label: "Contacts", state: "off",
                detail: "Turn on in the host's iCloud page")
        }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return CloudServiceEntry(
                service: service, label: "Contacts", state: "serving",
                detail: "Address book")
        case .notDetermined:
            return CloudServiceEntry(
                service: service, label: "Contacts", state: "no-access",
                detail: "Grant access in the host's iCloud page")
        default:
            return CloudServiceEntry(
                service: service, label: "Contacts", state: "no-access",
                detail: "Contacts access is denied on the host")
        }
    }

    private func requireAccess() throws {
        guard enabled else {
            throw CloudFault.refuse(
                code: "off", reason: "Contacts is not being shared")
        }
        guard CNContactStore.authorizationStatus(for: .contacts)
            == .authorized else {
            throw CloudFault.refuse(
                code: "no-access",
                reason: "The host has not granted Contacts access")
        }
    }

    func list(cursor: Int, limit: Int) throws
        -> (entries: [CloudEntry], more: Bool, next: Int) {
        try requireAccess()
        /* Enumerated fresh per page: the id list is small, and a cache
           would be one more thing to be wrong after an edit on the
           phone that caused the person to look here in the first
           place. */
        let keys = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var all: [(id: String, name: String, org: String)] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(
                    from: contact, style: .fullName) ?? "No name"
                all.append((contact.identifier, name,
                            contact.organizationName))
            }
        } catch {
            throw CloudFault.refuse(code: "io-error",
                                    reason: "\(error.localizedDescription)")
        }
        let start = max(0, cursor - 1)
        guard start < all.count else { return ([], false, all.count + 1) }
        let end = min(start + limit, all.count)
        let entries = all[start..<end].map { row in
            CloudEntry(
                item: row.id,
                title: CloudText.displayable(row.name),
                subtitle: row.org.isEmpty
                    ? nil : CloudText.displayable(row.org),
                bytes: nil, modified: nil)
        }
        return (Array(entries), end < all.count, end + 1)
    }

    func card(item: String) throws -> [[String]] {
        try requireAccess()
        let keys = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: item,
                                               keysToFetch: keys)
        } catch {
            throw CloudFault.refuse(code: "not-found",
                                    reason: "no such contact any more")
        }
        var rows: [[String]] = []
        if let name = CNContactFormatter.string(from: contact,
                                                style: .fullName) {
            rows.append(["Name", CloudText.displayable(name)])
        }
        if !contact.organizationName.isEmpty {
            rows.append(["Company",
                         CloudText.displayable(contact.organizationName)])
        }
        for phone in contact.phoneNumbers {
            rows.append([Self.label(phone.label, fallback: "phone"),
                         CloudText.displayable(
                             phone.value.stringValue)])
        }
        for email in contact.emailAddresses {
            rows.append([Self.label(email.label, fallback: "email"),
                         CloudText.displayable(email.value as String)])
        }
        for address in contact.postalAddresses {
            let value = CNPostalAddressFormatter.string(
                from: address.value, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
            rows.append([Self.label(address.label, fallback: "address"),
                         CloudText.displayable(value)])
        }
        if let birthday = contact.birthday?.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            rows.append(["Birthday", formatter.string(from: birthday)])
        }
        return rows
    }

    func get(item: String) throws -> OutboundFile.Plan {
        throw CloudFault.refuse(
            code: "not-listable",
            reason: "a contact is a card, not a file, for now")
    }

    private static func label(_ raw: String?, fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        return CloudText.displayable(
            CNLabeledValue<NSString>.localizedString(forLabel: raw))
    }
}

// MARK: - Serving

extension GuestListener {
    enum CloudAsk {
        case services(CloudServices)
        case list(CloudList)
        case detail(CloudDetail)
        case get(CloudGet)
    }

    /// Like the file serves: answered for any connected guest, down the
    /// connection that asked.
    func serveCloud(_ ask: CloudAsk, on asker: Session) {
        switch ask {
        case .services(let request):
            let entries = cloud.entries()
            note("#\(request.id) cloud services: "
                 + entries.map { "\($0.service)=\($0.state)" }
                     .joined(separator: " "),
                 area: "cloud")
            asker.send(.cloudReport(CloudReport(id: request.id,
                                                services: entries)))
        case .list(let request):
            guard let provider = cloud.provider(for: request.service) else {
                refuseCloud(id: request.id, code: "unknown-service",
                            reason: "no service called "
                                + request.service, on: asker)
                return
            }
            do {
                let page = try provider.list(cursor: request.cursor ?? 1,
                                             limit: 16)
                let bounded = boundedCloudPage(page.entries,
                                               id: request.id,
                                               service: request.service)
                let served = max(0, request.cursor ?? 1)
                    + bounded.count - 1
                note("#\(request.id) \(request.service): "
                     + "\(bounded.count) row"
                     + "\(bounded.count == 1 ? "" : "s")", area: "cloud")
                asker.send(.cloudListing(CloudListing(
                    id: request.id, service: request.service,
                    entries: bounded,
                    more: page.more || bounded.count < page.entries.count,
                    cursor: bounded.count < page.entries.count
                        ? served + 1 : page.next)))
            } catch {
                let fault = CloudFault.from(error)
                refuseCloud(id: request.id, code: fault.code,
                            reason: fault.reason, on: asker)
            }
        case .detail(let request):
            guard let provider = cloud.provider(for: request.service) else {
                refuseCloud(id: request.id, code: "unknown-service",
                            reason: "no service called "
                                + request.service, on: asker)
                return
            }
            do {
                let rows = try provider.card(item: request.item)
                asker.send(.cloudCard(CloudCard(
                    id: request.id, service: request.service,
                    item: request.item, rows: rows)))
            } catch {
                let fault = CloudFault.from(error)
                refuseCloud(id: request.id, code: fault.code,
                            reason: fault.reason, on: asker)
            }
        case .get(let request):
            serveCloudGet(request, on: asker)
        }
    }

    private func serveCloudGet(_ request: CloudGet, on asker: Session) {
        guard let provider = cloud.provider(for: request.service) else {
            refuseCloud(id: request.id, code: "unknown-service",
                        reason: "no service called " + request.service,
                        on: asker)
            return
        }
        if let obstruction = transferLaneObstruction(for: asker) {
            refuseCloud(id: request.id, code: "busy",
                        reason: obstruction, on: asker)
            return
        }
        do {
            let plan = try provider.get(item: request.item)
            note("#\(request.id) \(request.service) get -> "
                 + "\(plan.name), \(plan.bytes.count) bytes",
                 area: "cloud")
            /* From here the file family owns the outcome; the guest
               sees an ordinary offer landing in its share. */
            putFile(name: plan.name, into: "", container: plan.container,
                    bytes: plan.bytes, fileType: plan.fileType,
                    creator: plan.creator, modified: plan.modified) {
                [weak self] result in
                if case .failure(let failure) = result {
                    self?.note("cloud get #\(request.id) failed: "
                               + failure.message, area: "cloud")
                }
            }
        } catch {
            let fault = CloudFault.from(error)
            refuseCloud(id: request.id, code: fault.code,
                        reason: fault.reason, on: asker)
        }
    }

    private func refuseCloud(id: Int, code: String, reason: String,
                             on session: Session) {
        note("#\(id) cloud refused: \(code) (\(reason))", area: "cloud")
        session.send(.cloudRefuse(CloudRefuse(id: id, code: code,
                                              reason: reason)))
    }

    /// The file.listing discipline: a page is bounded by MEASURED
    /// encoded bytes, never an estimate of them.
    private func boundedCloudPage(_ entries: [CloudEntry], id: Int,
                                  service: String) -> [CloudEntry] {
        var page: [CloudEntry] = []
        for entry in entries {
            let probe = CloudListing(id: id, service: service,
                                     entries: page + [entry],
                                     more: true, cursor: 0)
            let size = (try? ControlMessageCodec.encode(
                .cloudListing(probe)))?.count ?? Int.max
            if !page.isEmpty && size > 4096 { break }
            page.append(entry)
        }
        return page
    }
}
