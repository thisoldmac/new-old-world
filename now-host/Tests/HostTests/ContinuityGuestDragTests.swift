import AppKit
import MirrorKit
import MirrorKitUI
import XCTest
@testable import Host

/// The guest→host half of cross-edge file drag: what a press binds to, the
/// order the cross happens in, and what a grab does when the Mac says no.
///
/// Every assertion here exists because v1 failed attended metal testing with
/// no per-direction symptom at all — each of these paths was a silent nil.
@MainActor
final class ContinuityGuestDragTests: XCTestCase {

    // MARK: - The stub cache

    func testSelectionIsCachedUnderItsOwnGenerationAndAudited() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 7, generation: 3,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)

        let bound = try? cache.bindable(activeEpoch: 7).get()
        XCTAssertEqual(bound?.generation, 3)
        XCTAssertEqual(bound?.item.name, "Read Me")
        XCTAssertTrue(audits.contains { $0.1.contains("selection cached")
            && $0.1.contains("generation=3") },
            "a cache update nobody can see is how v1 produced no symptom")
    }

    /// An absent item is an INSTRUCTION, not a poll that found nothing.
    func testEmptySelectionClearsTheCacheAndSaysSo() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 7, generation: 3,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)
        cache.apply(Self.selection(epoch: 7, generation: 4, item: nil),
                    activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertEqual(cache.bindable(activeEpoch: 7), .failure(.noSelection))
        XCTAssertTrue(audits.contains { $0.1.contains("selection cleared") })
    }

    /// A grab expires with its epoch by contract. A stub cached under
    /// another one would be exactly that grant outliving its consent.
    func testSelectionFromAnotherEpochIsNeverCached() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 6, generation: 1,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertTrue(audits.contains {
            $0.0 == .warn && $0.1.contains("epoch 6")
                && $0.1.contains("epoch 7")
        }, "the refusal must name both epochs, not merely decline")
    }

    func testFolderIsRefusedByTheNameTheContractUses() {
        let cache = ContinuitySelectionCache { _, _ in }
        cache.apply(Self.selection(epoch: 7, generation: 2,
                                   item: Self.folder(name: "System Folder")),
                    activeEpoch: 7)

        XCTAssertEqual(cache.bindable(activeEpoch: 7),
                       .failure(.folderNotYet("System Folder")))
        XCTAssertTrue(ContinuitySelectionCache.Unusable
            .folderNotYet("System Folder").message
            .contains("folder-not-yet"))
    }

    func testWrongContinuityVersionIsIgnoredOutLoud() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        var selection = Self.selection(epoch: 7, generation: 1,
                                       item: Self.file(name: "Read Me"))
        selection.version = ContinuityContract.version + 1
        cache.apply(selection, activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertTrue(audits.contains { $0.1.contains("Continuity version") })
    }

    /// A classic file has no extension to read a type from; four bytes is
    /// all the guest sends, so that is what the promise is built on.
    func testStubNamesATypeAndAFilenameFromClassicMetadata() {
        var item = Self.file(name: "Read Me")
        item.fileType = "TEXT"
        let text = ContinuityDragStub(epoch: 1, generation: 1, item: item)
        XCTAssertEqual(text.utType, .plainText)
        XCTAssertEqual(text.localName, "Read Me")
        XCTAssertNil(text.wireContainer)

        var appItem = Self.file(name: "SimpleText")
        appItem.fileType = "APPL"
        let app = ContinuityDragStub(epoch: 1, generation: 1, item: appItem)
        XCTAssertEqual(app.localName, "SimpleText.bin",
                       "an application without its resource fork is nothing")
        XCTAssertEqual(app.wireContainer, "macbinary")
    }

    // MARK: - The press binding

    func testPressBindsToTheSelectionStubRatherThanAScene() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("press bound to the guest selection")
                && $0.1.contains("generation=3")
        })
        XCTAssertEqual(rig.sceneLookups, 0,
                       "the stub is the truth for this lane; a scene lookup "
                        + "here would reintroduce the Mirror dependency")
    }

    func testPressOnAFolderIsAnOrdinaryClickAndSaysWhy() {
        let rig = Rig()
        rig.select(Self.folder(name: "System Folder"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("folder-not-yet")
        }, "an unusable stub must be named, not silently dropped")
    }

    func testPressWithNoSelectionIsAnOrdinaryClickAndSaysWhy() {
        let rig = Rig()
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("has published no Finder selection")
        })
    }

    // MARK: - The cross

    /// **The release comes first.** v1 never released the guest button, so
    /// the dragged icon stayed stuck to the Finder's cursor on the other
    /// machine. Order is the whole mechanism, so the order is what is
    /// asserted — not merely that both things happened.
    func testGuestPressIsReleasedBeforeTheHostDragSessionStarts() throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertEqual(rig.environment.fileDrags.count, 1,
                       "the held file must reach AppKit")
        let release = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .guestPrimaryUp),
            "the guest press was never released")
        let session = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .hostDragBegan))
        XCTAssertLessThan(release, session,
                          "the drag started while the guest still held the "
                            + "press; the icon cannot snap back")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("guest press released before the cross")
        })
    }

    /// The tap has no NSEvent by construction, and the physical button is
    /// still held — so the crossing WAITS rather than synthesizing one.
    func testTheDragWaitsForARealEventInsteadOfInventingOne() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "no real event yet means no drag session at all")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("waiting for the first real one")
        })
        XCTAssertEqual(rig.environment.catchChanges.first, true,
                       "two pixels cannot catch a moving pointer")

        rig.deliverRealDragEvent(eventNumber: 9182)
        XCTAssertEqual(rig.environment.fileDrags.first?.event.eventNumber,
                       9182)
        XCTAssertEqual(rig.environment.catchChanges, [true, false],
                       "the wide surface belongs to one handoff only")
    }

    func testReleasingBeforeARealEventAbandonsTheDragOutLoud() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.environment.emit(.init(kind: .primaryUp,
                                   location: CGPoint(x: 1300, y: 450),
                                   delta: .zero, buttonsDown: false))

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("abandoned") && $0.1.contains("released before")
        })
        XCTAssertEqual(rig.environment.catchChanges, [true, false])
    }

    // MARK: - Fulfillment

    func testGrabWritesTheFileAndReportsWhatArrived() throws {
        var audits: [(HostLog.LogLevel, String)] = []
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("Read Me")
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let asked = Asked()
        let transfer = ContinuityGrabTransfer(
            grab: { epoch, generation, _, _, completion in
                asked.epoch = epoch
                asked.generation = generation
                completion(.success(delivery))
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let failure = fulfill(transfer, to: destination, stub: stub)

        XCTAssertNil(failure)
        XCTAssertEqual(asked.epoch, 7)
        XCTAssertEqual(asked.generation, 3,
                       "a grab is bound to one generation, never to a name")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8),
                       "hello")
        XCTAssertTrue(audits.contains { $0.1.contains("grab completed") })
        XCTAssertFalse(transfer.isBusy)
    }

    /// `stale-selection` is the guest refusing a grant it will not honour.
    /// It must reach macOS as a FAILED promise and the log as a named line —
    /// unnamed, it reads exactly like a dead wire.
    func testStaleSelectionRefusalFailsThePromiseAndIsNamed() throws {
        var audits: [(HostLog.LogLevel, String)] = []
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "stale-selection",
                                          message: "the selection changed")))
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let failure = fulfill(transfer,
                              to: staging.appendingPathComponent("Read Me"),
                              stub: stub)

        XCTAssertEqual(failure as? ContinuityGrabTransfer.GrabError,
                       .wire(code: "stale-selection",
                             message: "the selection changed"))
        XCTAssertTrue(audits.contains {
            $0.0 == .error && $0.1.contains("stale-selection")
                && $0.1.contains("generation=3")
        }, "a refusal without its code is indistinguishable from silence")
        XCTAssertFalse(transfer.isBusy,
                       "a refusal must release the lane, or one bad drag "
                        + "wedges every later one")
    }

    func testOneGrabAtATime() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        var audits: [(HostLog.LogLevel, String)] = []
        let asked = expectation(description: "the first grab reached the wire")
        let held = Held()
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                held.completion = completion
                asked.fulfill()
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        /* The first never answers, so the lane stays held. */
        let first = transfer.promise(for: stub)
        transfer.filePromiseProvider(
            first, writePromiseTo: staging.appendingPathComponent("a")
        ) { _ in }
        wait(for: [asked], timeout: 5)

        let second = fulfill(transfer,
                             to: staging.appendingPathComponent("b"),
                             stub: stub)
        XCTAssertEqual(second as? ContinuityGrabTransfer.GrabError, .busy)
        XCTAssertTrue(audits.contains { $0.1.contains("already in flight") })
        XCTAssertNotNil(held.completion)
    }

    // MARK: - Fixtures

    private final class Asked {
        var epoch: UInt32?
        var generation: UInt32?
    }

    private final class Held {
        var completion: ((Result<GuestListener.FileDelivery,
                                 GuestListener.FileFailure>) -> Void)?
    }

    private func fulfill(_ transfer: ContinuityGrabTransfer, to url: URL,
                         stub: ContinuityDragStub) -> Error? {
        let done = expectation(description: "promise")
        let box = Held()
        var thrown: Error?
        _ = box
        transfer.filePromiseProvider(
            transfer.promise(for: stub), writePromiseTo: url
        ) { error in
            thrown = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return thrown
    }

    private static func selection(epoch: UInt32, generation: UInt32,
                                  item: ContinuitySelection.Item?)
        -> ContinuitySelection {
        .init(version: ContinuityContract.version, epoch: epoch,
              generation: generation, item: item)
    }

    fileprivate static func file(name: String) -> ContinuitySelection.Item {
        .init(name: name, volumeRef: -1, dirID: 2, fileType: "TEXT",
              creator: "ttxt", dataSize: 5, resourceSize: 0,
              modifiedAt: 3_400_000_000, isFolder: false, icon: nil)
    }

    fileprivate static func folder(name: String) -> ContinuitySelection.Item {
        .init(name: name, volumeRef: -1, dirID: 2, fileType: nil,
              creator: nil, dataSize: nil, resourceSize: nil,
              modifiedAt: nil, isFolder: true, icon: nil)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-grab-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real staged delivery, produced by the real sink: `StagedFile` owns
    /// its temporary and cannot be conjured, which is the point of it.
    private static func delivery(name: String, bytes: Data,
                                 in directory: URL) throws
        -> GuestListener.FileDelivery {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: bytes.count)
        try sink.append(bytes)
        return .init(name: name, container: "data", fileType: "TEXT",
                     creator: "ttxt", modified: nil,
                     staged: try sink.finish(expectedCRC32: nil),
                     transferMs: 1, crc32: nil, resumeToken: nil)
    }
}

/// One ordered record of everything the two sides of a crossing do, because
/// the defect this slice fixes is an ORDER, and two separate arrays cannot
/// express one.
private enum CrossStep: Equatable {
    case guestPrimaryDown
    case guestPrimaryUp
    case guestPointerLeft
    case hostDragBegan
}

private final class Ledger {
    var steps: [CrossStep] = []
}

private final class AuditRecorder {
    var lines: [(HostLog.LogLevel, String)] = []
}

@MainActor
private final class Rig {
    let layout: ContinuityDisplayLayout
    let controller: ContinuityEdgeController
    let environment: Environment
    let driver: Driver
    let ledger = Ledger()
    let recorder = AuditRecorder()
    private let cache: ContinuitySelectionCache
    private let listener: GuestListener
    private let fileTransfer: MirrorFileTransferModel
    private let grab: ContinuityGrabTransfer
    private let sceneCalls = Ledger()
    private var epoch: UInt32 = 7

    /// How many times anything asked for Mirror's scene. The guest→host lane
    /// must never need one.
    var sceneLookups: Int { sceneCalls.steps.count }

    init() {
        let recorder = self.recorder
        let audit: (HostLog.LogLevel, String) -> Void = {
            recorder.lines.append(($0, $1))
        }
        let sceneCalls = self.sceneCalls
        layout = ContinuityDisplayLayout(
            hostDisplays: [HostDisplayDescriptor(
                id: 41, name: "Studio Display",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pixelSize: CGSize(width: 5120, height: 2880),
                isPrimary: true)],
            guestSize: CGSize(width: 800, height: 600),
            defaults: nil, observeScreens: false)
        driver = Driver(ledger: ledger)
        environment = Environment(ledger: ledger)
        cache = ContinuitySelectionCache(audit: audit)
        listener = GuestListener(identity: .init(version: "test",
                                                 name: "Host"))
        fileTransfer = MirrorFileTransferModel(listener: listener)
        grab = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "disconnected",
                                          message: "no Mac in this test")))
            }, audit: audit)
        controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: audit)
        let cache = self.cache
        let epoch = self.epoch
        ContinuityFileDrag.configure(
            edge: controller,
            fileTransfer: fileTransfer,
            scene: {
                sceneCalls.steps.append(.hostDragBegan)
                return nil
            },
            selection: { cache.bindable(activeEpoch: epoch) },
            grab: grab,
            audit: audit)
        controller.start()
    }

    deinit {
        MainActor.assumeIsolated { listener.stop() }
    }

    func select(_ item: ContinuitySelection.Item) {
        cache.apply(.init(version: ContinuityContract.version, epoch: epoch,
                          generation: 3, item: item),
                    activeEpoch: epoch)
    }

    func enterGuest() {
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
    }

    func press() {
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
    }

    /// The crossing itself, through the consuming tap — which has no NSEvent.
    func crossBackHolding() {
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true))
    }

    /// The first physical `mouseDragged` after the tap died.
    func deliverRealDragEvent(eventNumber: Int = 4242) {
        // swiftlint:disable:next force_unwrapping
        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 12, windowNumber: 0, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: 1)!
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1300, y: 450),
                               delta: CGPoint(x: -8, y: 0),
                               buttonsDown: true),
                         event: event)
    }

    final class Driver: ContinuityEdgeDriving {
        var keyboardForwardingEnabled = true
        var escapeShortcut = ContinuityEscapeShortcut.controlOptionEscape
        private let ledger: Ledger

        init(ledger: Ledger) { self.ledger = ledger }

        func pointerMoved(to point: MirrorKit.Point) { _ = point }
        func pointerLeft() { ledger.steps.append(.guestPointerLeft) }
        func primaryDown(at point: MirrorKit.Point, inMenuBar: Bool,
                         sourceUptime: TimeInterval?) -> Bool {
            _ = (point, inMenuBar, sourceUptime)
            ledger.steps.append(.guestPrimaryDown)
            return true
        }
        func primaryDragged(to point: MirrorKit.Point) -> Bool {
            _ = point
            return true
        }
        func primaryUp(at point: MirrorKit.Point) -> Bool {
            _ = point
            ledger.steps.append(.guestPrimaryUp)
            return true
        }
        func keyboardEvent(_ sample: HostKeySample) -> Bool {
            _ = sample
            return true
        }
    }

    final class Environment: ContinuityPointerEnvironment {
        final class Token: NSObject {}
        let ledger: Ledger
        var handler: ContinuityPointerEnvironment.SampleHandler?
        var captureHandler: ContinuityPointerEnvironment.SampleHandler?
        var fileCallbacks: ContinuityFileEdge.Callbacks?
        var fileDrags: [(item: HostFileDragItem, point: CGPoint,
                         event: NSEvent)] = []
        var catchChanges: [Bool] = []

        init(ledger: Ledger) { self.ledger = ledger }

        func start(_ handler: @escaping ContinuityPointerEnvironment
                    .SampleHandler) -> AnyObject {
            self.handler = handler
            return Token()
        }
        func stop(_ token: AnyObject) { _ = token }
        func hideCursor(on displayID: UInt32) { _ = displayID }
        func showCursor(on displayID: UInt32) { _ = displayID }
        func moveCursor(on displayID: UInt32, to point: CGPoint) {
            _ = (displayID, point)
        }
        func setCursorMovementAssociated(_ associated: Bool) -> Bool {
            _ = associated
            return true
        }
        func startInputCapture(
            handler: @escaping ContinuityPointerEnvironment.SampleHandler,
            tapDisabled: @escaping @MainActor (String) -> Void
        ) -> AnyObject? {
            _ = tapDisabled
            captureHandler = handler
            return Token()
        }
        func stopInputCapture(_ token: AnyObject) {
            _ = token
            captureHandler = nil
        }
        func showFileEdge(_ edge: ContinuitySharedEdge,
                          callbacks: ContinuityFileEdge.Callbacks)
            -> AnyObject {
            _ = edge
            fileCallbacks = callbacks
            return Token()
        }
        func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                            callbacks: ContinuityFileEdge.Callbacks) {
            _ = (token, edge)
            fileCallbacks = callbacks
        }
        func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool) {
            _ = token
            catchChanges.append(catching)
        }
        func hideFileEdge(_ token: AnyObject) {
            _ = token
            fileCallbacks = nil
        }
        func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                           sourceEvent: NSEvent) -> Bool {
            ledger.steps.append(.hostDragBegan)
            fileDrags.append((item, screenPoint, sourceEvent))
            return true
        }
        func emit(_ sample: HostPointerSample, event: NSEvent? = nil) {
            handler?(sample, event)
        }
        func emitCaptured(_ sample: HostPointerSample,
                          event: NSEvent? = nil) {
            captureHandler?(sample, event)
        }
    }
}
