import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import XCTest
@testable import Host

/// The cloud.* family over a real loopback wire: a guest asks about
/// this Mac's iCloud and the host answers from its provider registry.
/// Providers here are fakes — what only a signed-in, access-granted
/// Mac can prove is ledgered in docs/open-issues.md, not claimed here.
@MainActor
final class CloudServingTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.cloud = CloudRegistry()
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision,
                                    side: "guest", version: "0.1.0",
                                    name: "PowerBook 1400", os: "9.1",
                                    chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    private func lastReceived<T>(
        on guest: FakeGuest,
        _ extract: @escaping (ControlMessage) -> T?
    ) async throws -> T {
        try await waitUntil("a \(T.self)") {
            guest.received.contains { extract($0) != nil }
        }
        return guest.received.compactMap(extract).last!
    }

    /// A provider whose answers the test scripts.
    private final class FakeProvider: CloudProvider {
        let service: String
        var state = "serving"
        var rows: [CloudEntry] = []
        var card: [[String]] = []
        var fault: CloudFault?
        var plan: OutboundFile.Plan?
        /// What the last get was asked to deliver at: .some(nil) when a
        /// get arrived carrying no size, nil while none arrived at all —
        /// the double optional is what lets a test tell "asked with the
        /// host-default reading" from "never asked".
        var sizeAsked: String??
        /// nil leaves the protocol's own default (refuse not-listable).
        var previewPixels: ClassicDither.Indexed?

        init(_ service: String) { self.service = service }

        func entry() -> CloudServiceEntry {
            CloudServiceEntry(service: service,
                              label: service.capitalized,
                              state: state, detail: "fake")
        }

        func list(cursor: Int, limit: Int) throws
            -> (entries: [CloudEntry], more: Bool, next: Int) {
            if let fault { throw fault }
            let start = max(0, cursor - 1)
            guard start < rows.count else {
                return ([], false, rows.count + 1)
            }
            let end = min(start + limit, rows.count)
            return (Array(rows[start..<end]), end < rows.count, end + 1)
        }

        func card(item: String) throws -> [[String]] {
            if let fault { throw fault }
            return card
        }

        func get(item: String, size: String?) throws
            -> OutboundFile.Plan {
            sizeAsked = .some(size)
            if let fault { throw fault }
            guard let plan else {
                throw CloudFault.refuse(code: "not-found",
                                        reason: "nothing scripted")
            }
            return plan
        }

        func preview(item: String, maxWidth: Int, maxHeight: Int,
                     depth: Int) throws -> ClassicDither.Indexed {
            if let fault { throw fault }
            guard let previewPixels else {
                throw CloudFault.refuse(
                    code: "not-listable",
                    reason: "\(service) has nothing to show as pixels")
            }
            return previewPixels
        }
    }

    // MARK: - Discovery

    func testTheReportNamesEveryServiceWhateverItsState() async throws {
        let photos = FakeProvider("photos")
        let contacts = FakeProvider("contacts")
        contacts.state = "no-access"
        listener.cloud.register(photos)
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()
        try guest.send(.cloudServices(CloudServices(id: 1)))
        let report = try await lastReceived(on: guest) {
            if case .cloudReport(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(report.id, 1)
        XCTAssertEqual(report.services.map(\.service),
                       ["photos", "contacts"])
        XCTAssertEqual(report.services.map(\.state),
                       ["serving", "no-access"],
                       "off and unauthorized still report, with why")
    }

    // MARK: - Listing

    func testAListingPagesTheProvidersRows() async throws {
        let photos = FakeProvider("photos")
        photos.rows = (1...20).map {
            CloudEntry(item: "asset-\($0)", title: "Photo \($0)",
                       subtitle: nil, bytes: nil, modified: nil)
        }
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudList(CloudList(id: 2, service: "photos",
                                            cursor: nil)))
        let listing = try await lastReceived(on: guest) {
            if case .cloudListing(let l) = $0 { return l }
            else { return nil }
        }
        XCTAssertEqual(listing.id, 2)
        XCTAssertEqual(listing.entries.count, 16)
        XCTAssertTrue(listing.more)
        XCTAssertEqual(listing.cursor, 17)
        XCTAssertEqual(listing.entries.first?.title, "Photo 1")
    }

    /// Entry dimensions ride the wire when a provider states them, and
    /// stay absent — not zero — when it does not: the omission-is-not-
    /// zero rule the contract states for width/height.
    func testEntryDimensionsRideTheListingWhenTheProviderStatesThem()
        async throws {
        let photos = FakeProvider("photos")
        photos.rows = [
            CloudEntry(item: "asset-1", title: "Photo 1", subtitle: nil,
                       bytes: nil, modified: nil, width: 4032, height: 3024),
        ]
        let contacts = FakeProvider("contacts")
        contacts.rows = [
            CloudEntry(item: "c-1", title: "Ada Lovelace", subtitle: nil,
                       bytes: nil, modified: nil),
        ]
        listener.cloud.register(photos)
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()

        try guest.send(.cloudList(CloudList(id: 80, service: "photos",
                                            cursor: nil)))
        let photoListing = try await lastReceived(on: guest) {
            if case .cloudListing(let l) = $0, l.id == 80 { return l }
            else { return nil }
        }
        XCTAssertEqual(photoListing.entries.first?.width, 4032)
        XCTAssertEqual(photoListing.entries.first?.height, 3024)

        try guest.send(.cloudList(CloudList(id: 81, service: "contacts",
                                            cursor: nil)))
        let contactListing = try await lastReceived(on: guest) {
            if case .cloudListing(let l) = $0, l.id == 81 { return l }
            else { return nil }
        }
        XCTAssertNil(contactListing.entries.first?.width,
                     "a service with no pixel size states none — "
                         + "omission, never an invented zero")
        XCTAssertNil(contactListing.entries.first?.height)
    }

    func testAnUnknownServiceIsRefusedAndTheWireSurvives() async throws {
        let guest = try await connectedGuest()
        try guest.send(.cloudList(CloudList(id: 3, service: "frobnicator",
                                            cursor: nil)))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.id, 3)
        XCTAssertEqual(refuse.code, "unknown-service",
                       "the additive-registry answer, never an error")
        // The connection answers the next ask, so the refusal cost
        // nothing but the request.
        try guest.send(.cloudServices(CloudServices(id: 4)))
        let report = try await lastReceived(on: guest) {
            if case .cloudReport(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(report.id, 4)
    }

    func testAProviderFaultArrivesAsItsOwnRefusal() async throws {
        let photos = FakeProvider("photos")
        photos.fault = CloudFault.refuse(
            code: "busy", reason: "iCloud is fetching that photo")
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudList(CloudList(id: 5, service: "photos",
                                            cursor: nil)))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.code, "busy")
        XCTAssertEqual(refuse.reason, "iCloud is fetching that photo")
    }

    // MARK: - The card

    func testACardCarriesTheProvidersRows() async throws {
        let contacts = FakeProvider("contacts")
        contacts.card = [["Name", "Ada Lovelace"], ["work", "ada@example.com"]]
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()
        try guest.send(.cloudDetail(CloudDetail(id: 6, service: "contacts",
                                                item: "c-1")))
        let card = try await lastReceived(on: guest) {
            if case .cloudCard(let c) = $0 { return c } else { return nil }
        }
        XCTAssertEqual(card.item, "c-1")
        XCTAssertEqual(card.rows,
                       [["Name", "Ada Lovelace"],
                        ["work", "ada@example.com"]])
    }

    // MARK: - Get rides the file family

    func testAGetBecomesAnOrdinaryFileOffer() async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 7, service: "photos",
                                          item: "asset-1")))
        let offer = try await lastReceived(on: guest) {
            if case .fileOffer(let o) = $0 { return o } else { return nil }
        }
        XCTAssertEqual(offer.name, "IMG_1234.jpg")
        XCTAssertEqual(offer.container, "data")
        XCTAssertEqual(offer.bytes, 10)
        XCTAssertEqual(offer.fileType, "JPEG",
                       "typed so it opens by double-click on arrival")
        XCTAssertEqual(offer.path, "",
                       "lands at the guest's share root")
    }

    /// The ask's own size reaches the provider verbatim — the per-ask
    /// override the contract added over the host's configured default.
    func testAGetPassesTheAsksSizeToTheProvider() async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 71, service: "photos",
                                          item: "asset-1",
                                          size: "long1024")))
        _ = try await lastReceived(on: guest) {
            if case .fileOffer(let o) = $0 { return o } else { return nil }
        }
        XCTAssertEqual(photos.sizeAsked, .some("long1024"))
    }

    /// A get with no size still reaches the provider as nil — the
    /// host-default path, byte-identical to what every older guest asks.
    func testAGetWithoutASizeLeavesTheHostsDefault() async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 72, service: "photos",
                                          item: "asset-1")))
        _ = try await lastReceived(on: guest) {
            if case .fileOffer(let o) = $0 { return o } else { return nil }
        }
        XCTAssertEqual(photos.sizeAsked, .some(nil),
                       "no size on the wire must arrive as nil, not "
                           + "be invented")
    }

    /// A token outside the contract's enum refuses with a reason and
    /// never reaches the provider — the contract's own wording.
    func testAGetWithAnUnknownSizeIsRefused() async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 73, service: "photos",
                                          item: "asset-1",
                                          size: "enormous")))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.id, 73)
        XCTAssertEqual(refuse.code, "io-error")
        XCTAssertEqual(refuse.reason,
                       "size must be original, long640, long1024 "
                           + "or long1600",
                       "the reason names every token that would work "
                           + "— which is what makes retiring the fitN "
                           + "boxes safe without a revision bump")
        XCTAssertNil(photos.sizeAsked,
                     "a refused size must not reach the provider")
        XCTAssertFalse(guest.received.contains {
            if case .fileOffer = $0 { return true } else { return false }
        }, "no offer may exist for a refused get")
    }

    /// The two tokens the polish arc added reach the provider exactly
    /// like the three original ones — no second code path for them.
    /// One connection, both tokens asked in turn: proves neither is a
    /// one-shot fluke of connection setup.
    func testAGetPassesEveryLongEdgeTokenToTheProvider() async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()

        // Each get takes the one-transfer-wide lane the moment its
        // offer starts, so the first must be accepted and drained
        // before the second can begin — the same discipline the
        // multi-megabyte transfer test follows.
        func offers() -> [FileOffer] {
            guest.received.compactMap {
                if case .fileOffer(let o) = $0 { return o } else { return nil }
            }
        }

        func fetchOne(id: Int, size: String, expect token: String)
            async throws {
            let before = offers().count
            try guest.send(.cloudGet(CloudGet(id: id, service: "photos",
                                              item: "asset-1",
                                              size: size)))
            try await waitUntil("a NEW file.offer for \(token)") {
                offers().count > before
            }
            let offer = offers().last!
            XCTAssertEqual(photos.sizeAsked, .some(token))
            try guest.send(.fileAccept(FileAccept(id: offer.id)))
            try await waitUntil("file.end for \(token)") {
                guest.received.contains {
                    if case .fileEnd(let end) = $0 {
                        return end.id == offer.id && end.ok
                    }
                    return false
                }
            }
            // The lane stays held until the GUEST confirms with
            // file.done (the contract's own rule); FakeGuest never
            // sends one on its own, so the test sends it explicitly to
            // free the lane for the second fetch, the same as a real
            // guest would once the File Manager stamps the file.
            try guest.send(.fileDone(FileDone(id: offer.id, ok: true)))
        }

        try await fetchOne(id: 74, size: "long1600", expect: "long1600")
        try await fetchOne(id: 75, size: "long640", expect: "long640")
    }

    /// The retirement itself, as behaviour: a peer still sending a
    /// fitN box meets a NAMED refusal, not a silently different
    /// render. This is the whole reason the semantic break needed no
    /// contract-revision bump, so it is worth its own test.
    func testARetiredFitTokenIsRefusedByNameAndNeverAliased()
        async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1234.jpg", container: "data",
            bytes: Data("jpeg bytes".utf8),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 76, service: "photos",
                                          item: "asset-1",
                                          size: "fit640")))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.id, 76)
        XCTAssertEqual(refuse.code, "io-error")
        XCTAssertEqual(refuse.reason,
                       "size must be original, long640, long1024 "
                           + "or long1600",
                       "the refusal names the set that replaced it")
        XCTAssertNil(photos.sizeAsked,
                     "an aliased fit640 would have delivered a "
                         + "portrait photo at a size nobody asked for")
    }

    /// The precedence itself, with no library in the room: the ask's
    /// token outranks the configured default, absence keeps it.
    func testTheAsksSizeOutranksTheConfiguredDefault() {
        XCTAssertEqual(
            PhotosCloudProvider.chosenSize(token: "original",
                                           configured: .long640),
            .original)
        XCTAssertEqual(
            PhotosCloudProvider.chosenSize(token: nil,
                                           configured: .long1024),
            .long1024)
        XCTAssertEqual(
            PhotosCloudProvider.chosenSize(token: "long1600",
                                           configured: .long640),
            .long1600)
        XCTAssertEqual(
            PhotosCloudProvider.chosenSize(token: "fit2048",
                                           configured: .long640),
            .long640,
            "a retired token never reaches here (the serve refuses it "
                + "first), and if it did it is not a size to guess at")
    }

    /// The number each token names, matched against the task's own
    /// stops — a wrong edge here would silently mis-scale every photo
    /// asked at that size.
    func testEverySizeTokenNamesItsLongEdge() {
        XCTAssertEqual(
            PhotosCloudProvider.DownloadSize.allCases.map(\.rawValue),
            ["original", "long1600", "long1024", "long640"])
        XCTAssertNil(PhotosCloudProvider.DownloadSize.original.longestEdge,
                     "original is the absence of a size, not a large one")
        XCTAssertEqual(
            PhotosCloudProvider.DownloadSize.long1600.longestEdge, 1600)
        XCTAssertEqual(
            PhotosCloudProvider.DownloadSize.long1024.longestEdge, 1024)
        XCTAssertEqual(
            PhotosCloudProvider.DownloadSize.long640.longestEdge, 640)
    }

    /// The scale, as arithmetic and independent of any image: the
    /// LONGER dimension lands on the number, whichever way up the photo
    /// is. Written from the task's own worked example rather than from
    /// what the code does — a portrait 3024x4032 at 640 is 480x640, and
    /// the fit-box math this replaced answered 360x480.
    func testTheLongEdgeScaleHonoursPortraitAndLandscapeAlike() {
        let portrait = PhotosCloudProvider.scaled(
            width: 3024, height: 4032, longestEdge: 640)
        XCTAssertEqual(portrait.width, 480)
        XCTAssertEqual(portrait.height, 640)
        let landscape = PhotosCloudProvider.scaled(
            width: 4032, height: 3024, longestEdge: 640)
        XCTAssertEqual(landscape.width, 640)
        XCTAssertEqual(landscape.height, 480)
        let square = PhotosCloudProvider.scaled(
            width: 3000, height: 3000, longestEdge: 1024)
        XCTAssertEqual(square.width, 1024)
        XCTAssertEqual(square.height, 1024)
    }

    /// Never upscale, at the arithmetic level: a small original asked
    /// at a large stop keeps its own numbers.
    func testTheLongEdgeScaleNeverEnlarges() {
        let small = PhotosCloudProvider.scaled(
            width: 400, height: 300, longestEdge: 1600)
        XCTAssertEqual(small.width, 400)
        XCTAssertEqual(small.height, 300)
        let exact = PhotosCloudProvider.scaled(
            width: 640, height: 480, longestEdge: 640)
        XCTAssertEqual(exact.width, 640)
        XCTAssertEqual(exact.height, 480)
    }

    func testAGetFaultRefusesInsteadOfOffering() async throws {
        let photos = FakeProvider("photos")
        photos.fault = CloudFault.refuse(code: "no-access",
                                         reason: "not granted")
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudGet(CloudGet(id: 8, service: "photos",
                                          item: "asset-1")))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.id, 8)
        XCTAssertEqual(refuse.code, "no-access")
        XCTAssertFalse(guest.received.contains {
            if case .fileOffer = $0 { return true } else { return false }
        }, "no offer may exist for a refused get")
    }

    // MARK: - The preview transfer

    /// The whole answer, over the real wire: preview.begin describing
    /// the rows, the raw bytes on the bulk channel, preview.end closing
    /// the transfer — and every byte intact, because the guest's only
    /// job is to CopyBits exactly these.
    func testAPreviewArrivesAsBeginBulkEndWithTheBytesIntact()
        async throws {
        let photos = FakeProvider("photos")
        let pixels = Data((0..<(24 * 10)).map { UInt8($0 % 251) })
        photos.previewPixels = ClassicDither.Indexed(
            width: 24, height: 10, depth: 8, rowBytes: 24, pixels: pixels)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudPreview(CloudPreview(
            id: 40, service: "photos", item: "asset-1",
            maxWidth: 300, maxHeight: 200, depth: 8)))
        let begin = try await lastReceived(on: guest) {
            if case .previewBegin(let b) = $0 { return b }
            else { return nil }
        }
        XCTAssertEqual(begin.id, 40)
        XCTAssertEqual(begin.width, 24)
        XCTAssertEqual(begin.height, 10)
        XCTAssertEqual(begin.depth, 8)
        XCTAssertEqual(begin.rowBytes, 24)
        XCTAssertEqual(begin.bytes, pixels.count)
        try await waitUntil("bulk + end") {
            guest.bulkReceived == pixels
                && guest.received.contains {
                    if case .previewEnd(let end) = $0 {
                        return end.id == 40 && end.ok
                    }
                    return false
                }
        }
    }

    /// The lane rule: while a download holds the one-transfer-wide
    /// lane, the ask refuses busy — never queues. (This is the
    /// mutation-watched serving property: removing the obstruction
    /// check from serveCloudPreview fails this with a preview.begin
    /// arriving instead of the refusal.)
    func testAPreviewIsRefusedBusyWhileADownloadHoldsTheLane()
        async throws {
        let photos = FakeProvider("photos")
        photos.plan = OutboundFile.Plan(
            name: "IMG_1.jpg", container: "data",
            bytes: Data(count: 512 * 1024),
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        photos.previewPixels = ClassicDither.Indexed(
            width: 8, height: 8, depth: 8, rowBytes: 8,
            pixels: Data(count: 64))
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        // The get takes the lane the moment the offer machinery starts;
        // the guest has not even accepted yet.
        try guest.send(.cloudGet(CloudGet(id: 50, service: "photos",
                                          item: "asset-1")))
        _ = try await lastReceived(on: guest) {
            if case .fileOffer(let o) = $0 { return o } else { return nil }
        }
        try guest.send(.cloudPreview(CloudPreview(
            id: 51, service: "photos", item: "asset-1",
            maxWidth: 300, maxHeight: 200, depth: 8)))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0, r.id == 51 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.code, "busy")
        XCTAssertFalse(guest.received.contains {
            if case .previewBegin = $0 { return true } else { return false }
        }, "a refused preview must not also begin")
    }

    /// A provider that never grew eyes: implements only the four
    /// original requirements, so cloud.preview reaches the protocol
    /// extension's default.
    private final class NoEyesProvider: CloudProvider {
        let service = "contacts"
        func entry() -> CloudServiceEntry {
            CloudServiceEntry(service: service, label: "Contacts",
                              state: "serving", detail: "fake")
        }
        func list(cursor: Int, limit: Int) throws
            -> (entries: [CloudEntry], more: Bool, next: Int) {
            ([], false, 1)
        }
        func card(item: String) throws -> [[String]] { [] }
        func get(item: String, size: String?) throws
            -> OutboundFile.Plan {
            throw CloudFault.refuse(code: "not-found", reason: "fake")
        }
    }

    /// A service that never grew eyes answers with the protocol's own
    /// refusal, not silence — the protocol-extension default.
    func testAProviderWithoutPreviewRefusesNotListable() async throws {
        let contacts = NoEyesProvider()
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()
        try guest.send(.cloudPreview(CloudPreview(
            id: 60, service: "contacts", item: "c-1",
            maxWidth: 300, maxHeight: 200, depth: 8)))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0, r.id == 60 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.code, "not-listable")
    }

    // MARK: - Contacts preview (loopback; the real CNContactStore path
    // needs this Mac's TCC grant and is untested here — see
    // docs/icloud.md and docs/open-issues.md)

    /// cloud.preview answers for contacts too, not just photos: a tiny
    /// synthetic thumbnail run through the SAME pipeline
    /// ContactsCloudProvider.preview calls
    /// (PhotosCloudProvider.rgbPixels + ClassicDither.dither) rides the
    /// wire as an ordinary begin/bulk/end transfer. This proves the
    /// wire plumbing and the reused pipeline's output; it does not
    /// touch CNContactStore.
    func testAContactsThumbnailAnswersACloudPreviewLikeAPhotoDoes()
        async throws {
        let tiny = try syntheticThumbnail(width: 40, height: 40)
        let (rgb, width, height) = try PhotosCloudProvider.rgbPixels(
            tiny, fitting: 100, 100)
        let indexed = ClassicDither.dither(rgb: rgb, width: width,
                                           height: height, depth: 8)
        let contacts = FakeProvider("contacts")
        contacts.previewPixels = indexed
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()
        try guest.send(.cloudPreview(CloudPreview(
            id: 61, service: "contacts", item: "c-1",
            maxWidth: 100, maxHeight: 100, depth: 8)))
        let begin = try await lastReceived(on: guest) {
            if case .previewBegin(let b) = $0 { return b }
            else { return nil }
        }
        XCTAssertEqual(begin.id, 61)
        XCTAssertEqual(begin.width, indexed.width)
        XCTAssertEqual(begin.height, indexed.height)
        try await waitUntil("bulk + end") {
            guest.bulkReceived == indexed.pixels
                && guest.received.contains {
                    if case .previewEnd(let end) = $0 {
                        return end.id == 61 && end.ok
                    }
                    return false
                }
        }
    }

    /// A contact with no thumbnail refuses not-found "no photo" — a
    /// well-formed, expected outcome (the contract's own wording), not
    /// an error the guest should treat as a failure.
    func testAContactWithNoThumbnailRefusesNotFoundNoPhoto() async throws {
        let contacts = FakeProvider("contacts")
        contacts.fault = CloudFault.refuse(code: "not-found",
                                           reason: "no photo")
        listener.cloud.register(contacts)
        let guest = try await connectedGuest()
        try guest.send(.cloudPreview(CloudPreview(
            id: 62, service: "contacts", item: "c-2",
            maxWidth: 100, maxHeight: 100, depth: 8)))
        let refuse = try await lastReceived(on: guest) {
            if case .cloudRefuse(let r) = $0, r.id == 62 { return r }
            else { return nil }
        }
        XCTAssertEqual(refuse.code, "not-found")
        XCTAssertEqual(refuse.reason, "no photo",
                       "the exact reason string the guest's placeholder "
                           + "path matches on")
    }

    private func syntheticThumbnail(width: Int, height: Int) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9,
                                     alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    // MARK: - Hardened for an enormous library

    /// Paging math at a scale no fixture short of a real library
    /// exercises: 10,000 rows, walked entirely by cursor, must land
    /// exactly once each — the same shape a 40,000-photo library forces
    /// on PhotosCloudProvider's caching, proven here against a fake so
    /// the claim does not depend on this Mac's own Photos library.
    func testListingWalksTenThousandRowsExactlyOnceEach() async throws {
        let photos = FakeProvider("photos")
        photos.rows = (1...10_000).map {
            CloudEntry(item: "asset-\($0)", title: "Photo \($0)",
                       subtitle: nil, bytes: nil, modified: nil)
        }
        listener.cloud.register(photos)
        let guest = try await connectedGuest()

        var seen: [String] = []
        var cursor: Int? = nil
        var askID = 100
        // The server pins the page size to 16 regardless of what a
        // provider would hand back, so a 10,000-row walk takes exactly
        // 625 round trips; a bound well past that catches a paging bug
        // without hanging the suite on one that never terminates.
        for _ in 0..<700 {
            try guest.send(.cloudList(CloudList(id: askID,
                                                service: "photos",
                                                cursor: cursor)))
            let listing = try await lastReceived(on: guest) {
                if case .cloudListing(let l) = $0, l.id == askID { return l }
                else { return nil }
            }
            seen.append(contentsOf: listing.entries.map(\.item))
            askID += 1
            if !listing.more { break }
            cursor = listing.cursor
        }
        XCTAssertEqual(seen.count, 10_000)
        XCTAssertEqual(Set(seen).count, 10_000, "no row served twice")
        XCTAssertEqual(seen.first, "asset-1")
        XCTAssertEqual(seen.last, "asset-10000")
    }

    /// A page is bounded by MEASURED encoded bytes (boundedCloudPage),
    /// never by row count alone — proven by rows whose titles are long
    /// enough that 16 of them would blow the wire's 4KB control-frame
    /// budget.
    func testAPageNeverExceedsTheFourKilobyteBound() async throws {
        let photos = FakeProvider("photos")
        let longTitle = String(repeating: "x", count: 200)
        photos.rows = (1...64).map {
            CloudEntry(item: "asset-\($0)", title: "\(longTitle)-\($0)",
                       subtitle: String(repeating: "y", count: 200),
                       bytes: nil, modified: nil)
        }
        listener.cloud.register(photos)
        let guest = try await connectedGuest()
        try guest.send(.cloudList(CloudList(id: 20, service: "photos",
                                            cursor: nil)))
        let listing = try await lastReceived(on: guest) {
            if case .cloudListing(let l) = $0 { return l } else { return nil }
        }
        let encoded = try ControlMessageCodec.encode(
            .cloudListing(listing))
        XCTAssertLessThanOrEqual(encoded.count, 4096,
            "a page must fit the same bound a Files listing keeps")
        XCTAssertLessThan(listing.entries.count, 16,
            "wide rows must trim the page below the row cap, not just up to it")
        XCTAssertTrue(listing.more,
            "truncating for size must not read as the end of the list")
        // The trimmed remainder is still reachable: the cursor accounts
        // for exactly the rows actually sent, not the 16 asked for.
        XCTAssertEqual(listing.cursor, listing.entries.count + 1)
    }

    /// cloud.get at photo scale: a multi-MB plan rides the ordinary
    /// offer/accept/begin/bulk/end lane, the same one a small file uses
    /// — proving the path that matters is exercised at the size photos
    /// actually are, not just at the few bytes the other get tests use.
    func testAMultiMegabytePhotoRidesTheOrdinaryTransferLane() async throws {
        let photos = FakeProvider("photos")
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(count: 3 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { buffer in
            for i in buffer.indices {
                buffer[i] = UInt8.random(in: 0...255, using: &generator)
            }
        }
        photos.plan = OutboundFile.Plan(
            name: "IMG_5678.jpg", container: "data", bytes: bytes,
            fileType: "JPEG", creator: "ogle", modified: nil, note: nil)
        listener.cloud.register(photos)
        let guest = try await connectedGuest()

        try guest.send(.cloudGet(CloudGet(id: 30, service: "photos",
                                          item: "asset-99")))
        var offerId: Int?
        try await waitUntil("file.offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerId = offer.id
                    return offer.bytes == bytes.count
                }
            }
            return false
        }
        let id = try XCTUnwrap(offerId)
        guard case .fileOffer(let offer)? = guest.received.first(where: {
            if case .fileOffer = $0 { return true } else { return false }
        }) else { return XCTFail("no offer") }
        XCTAssertEqual(offer.name, "IMG_5678.jpg")
        XCTAssertEqual(offer.fileType, "JPEG",
                       "typed at photo scale too, so it still opens by "
                       + "double-click on arrival")
        XCTAssertEqual(offer.creator, "ogle")

        try guest.send(.fileAccept(FileAccept(id: id)))
        try await waitUntil("file.begin", timeout: 15) {
            guest.received.contains {
                if case .fileBegin(let begin) = $0 {
                    return begin.id == id && begin.bytes == bytes.count
                }
                return false
            }
        }
        try await waitUntil("bulk + end", timeout: 15) {
            guest.bulkReceived == bytes
                && guest.received.contains {
                    if case .fileEnd(let end) = $0 { return end.ok }
                    return false
                }
        }
    }
}

/// The drive provider's report, which is a claim about configuration,
/// not about iCloud: injectable so the test is not a claim about
/// whether this Mac is signed in.
@MainActor
final class DriveCloudProviderTests: XCTestCase {
    private func share(root: URL) -> HostShare {
        let defaults = UserDefaults(
            suiteName: "now.tests.\(UUID().uuidString)")!
        let share = HostShare(defaults: defaults)
        share.root = root
        return share
    }

    private func temporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    func testSharingTheDriveFolderReportsServing() throws {
        let drive = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: drive) }
        let provider = DriveCloudProvider(share: share(root: drive),
                                          drive: drive)
        XCTAssertEqual(provider.entry().state, "serving")
    }

    func testSharingSomewhereElseReportsOff() throws {
        let drive = try temporaryFolder()
        let elsewhere = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: drive)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let provider = DriveCloudProvider(share: share(root: elsewhere),
                                          drive: drive)
        XCTAssertEqual(provider.entry().state, "off")
    }

    func testNoDriveFolderReportsUnavailable() throws {
        let elsewhere = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now-no-drive-\(UUID().uuidString)")
        let provider = DriveCloudProvider(share: share(root: elsewhere),
                                          drive: missing)
        XCTAssertEqual(provider.entry().state, "unavailable")
    }

    func testDriveIsNotASecondBrowser() throws {
        let drive = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: drive) }
        let provider = DriveCloudProvider(share: share(root: drive),
                                          drive: drive)
        XCTAssertThrowsError(try provider.list(cursor: 1, limit: 16)) {
            XCTAssertEqual(CloudFault.from($0).code, "not-listable",
                           "the file family is drive's transport")
        }
    }
}
