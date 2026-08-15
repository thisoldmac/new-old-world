import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Host

/// What a drag-out ADVERTISES, decided before a single byte is fetched.
///
/// The reported symptom was that drops onto the Desktop worked and drops
/// onto most applications did not. The Desktop takes any promise whatever
/// its declared type; an application checks the declared UTI, and often the
/// extension too, before it will accept one. So "Finder yes, everyone else
/// no" is a statement about this file and nothing else.
@MainActor
final class GuestFilePromiseMetadataTests: XCTestCase {
    private func row(_ name: String, type: String?, creator: String? = "ttxt",
                     rsrc: Int = 0, folder: Bool = false) -> FileRow {
        FileRow(entry: FileEntry(
            name: name, kind: folder ? "folder" : "file",
            fileType: folder ? nil : type, creator: folder ? nil : creator,
            dataBytes: folder ? nil : 8, rsrcBytes: folder ? nil : rsrc,
            modified: nil, identity: name), path: name)
    }

    // MARK: - The declared type

    func testTheCuratedTypesStillWin() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("SimpleText", type: "APPL", creator: "ttxt")).type,
            .application)
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Read Me", type: "TEXT")).type, .plainText)
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Screen", type: "PICT")).type, .image)
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Archive", type: "ZIP ")).type, .zip)
    }

    /// The seven curated answers are an override layer, not the whole
    /// answer. Everything outside them used to become `public.data`, which
    /// says nothing at all about a Word document or a StuffIt archive.
    func testAnUncuratedClassicTypeStillGetsAnAnswerOfItsOwn() throws {
        let promise = GuestFilePromiseDescriptor.describe(
            row("Chapter One", type: "WDBN", creator: "MSWD"))

        XCTAssertNotEqual(promise.type, .data,
                          "an unknown classic type is not 'some bytes'")
        XCTAssertEqual(promise.type,
                       GuestFilePromiseDescriptor.derivedType(for: "WDBN"))
        /* And it must still be acceptable everywhere `public.data` was, or
           this trades one refusal for another. */
        XCTAssertTrue(promise.type.conforms(to: .data))
    }

    /// A file with nothing to identify it stays honest rather than being
    /// given a type it has not earned.
    func testAFileWithNoIdentityAtAllFallsBackToData() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Untitled", type: "????", creator: "????")).type, .data)
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Untitled", type: nil, creator: nil)).type, .data)
    }

    /// The bug hiding inside `UTType(filenameExtension:)`: it answers a
    /// version number with a DYNAMIC type rather than with nil, and that
    /// answer used to win outright. A dynamic type from a "3" conforms to
    /// nothing, so nothing accepts it — which is precisely the reported
    /// "the Desktop takes it and no application will".
    func testAVersionNumberIsNotAFileExtension() {
        let promise = GuestFilePromiseDescriptor.describe(
            row("System 7.5.3", type: "TEXT"))

        XCTAssertNil(GuestFilePromiseDescriptor.extensionType(
            for: "System 7.5.3"),
            "a trailing '.3' identifies nothing")
        XCTAssertEqual(promise.type, .plainText)
        XCTAssertFalse(promise.type.isDynamic)
    }

    func testARealExtensionStillWinsWhenItIdentifiesAModernDocument() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Notes.txt", type: "TEXT")).type, .plainText)
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Photo.png", type: "????", creator: "????")).type, .png)
    }

    func testFoldersArePromisedAsFolders() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.describe(
                row("Project", type: nil, folder: true)).type, .folder)
    }

    // MARK: - The promised name

    /// `fileNameForType` exists so the delegate can hand back a name whose
    /// extension agrees with the type it already declared. It returned the
    /// bare guest name, so a classic file arrived with a name contradicting
    /// its own advertised UTI.
    func testAnExtensionlessNameGainsTheOneItsDeclaredTypeAsksFor() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.promisedName(
                "Read Me", declared: UTType.plainText.identifier),
            "Read Me.txt")
    }

    func testANameThatAlreadyAgreesIsLeftAlone() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.promisedName(
                "Notes.txt", declared: UTType.plainText.identifier),
            "Notes.txt")
        XCTAssertEqual(
            GuestFilePromiseDescriptor.promisedName(
                "NOTES.TXT", declared: UTType.plainText.identifier),
            "NOTES.TXT", "the filesystem does not care about case here")
    }

    /// A type with no preferred extension must not be given a guessed one.
    /// A wrong extension is worse than none: it is a claim, and the
    /// receiving application will believe it.
    func testATypeWithNoExtensionOfItsOwnLeavesTheNameUntouched() {
        for identifier in [UTType.data.identifier,
                           UTType.folder.identifier,
                           UTType.application.identifier] {
            XCTAssertEqual(
                GuestFilePromiseDescriptor.promisedName(
                    "SimpleText", declared: identifier),
                "SimpleText", "\(identifier) has no extension to offer")
        }
    }

    /// HFS names may contain the one character a POSIX path may not. The
    /// promised folder children already went through this projection; the
    /// promised top-level name did not.
    func testAGuestNameIsProjectedOntoWhatTheFilesystemAccepts() {
        XCTAssertEqual(
            GuestFilePromiseDescriptor.promisedName(
                "9/10 Notes", declared: UTType.data.identifier),
            "9:10 Notes")
    }

    /// The name and the type are decided in two different places — one on
    /// the pasteboard writer, one in the promise delegate — so they are
    /// asserted together here. The whole (b)/(c) defect was the two of them
    /// disagreeing.
    func testTheNameAndTheDeclaredTypeAgreeForEveryShapeOfClassicFile() {
        for item in [row("Read Me", type: "TEXT"),
                     row("Chapter One", type: "WDBN", creator: "MSWD"),
                     row("SimpleText", type: "APPL", rsrc: 2048),
                     row("Photo.png", type: "????", creator: "????"),
                     row("Untitled", type: nil, creator: nil)] {
            let declared = GuestFilePromiseDescriptor.describe(item).type
            let name = GuestFilePromiseDescriptor.promisedName(
                item.name, declared: declared.identifier)
            guard let expected = declared.preferredFilenameExtension else {
                XCTAssertEqual(name, LocalFileName.sanitized(item.name),
                               "\(item.name) has no extension to gain")
                continue
            }
            XCTAssertEqual(
                (name as NSString).pathExtension.lowercased(),
                expected.lowercased(),
                "\(item.name) is promised as \(declared.identifier)")
        }
    }
}

/// Drag IN. The table registers for file URLs and for every type
/// `NSFilePromiseReceiver` can read; `validateDrop` used to claim `.copy`
/// for anything at all while `acceptDrop` redeemed only plain URLs, so a
/// promise-only source showed the green plus for the whole drag and then
/// did nothing at all on release.
@MainActor
final class GuestFileBrowserAdapterDropTests: XCTestCase {
    private final class StubPromiseDelegate: NSObject,
                                             NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            "Promised"
        }

        func filePromiseProvider(
            _ provider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void) {
            completionHandler(nil)
        }
    }

    private var delegate = StubPromiseDelegate()

    private func pasteboard() throws -> NSPasteboard {
        let board = NSPasteboard(name: .init(
            "now.test.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-drop-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        return url
    }

    func testAFileURLDragIsReadAsURLs() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let board = try pasteboard()
        board.writeObjects([url as NSURL])

        guard case .urls(let urls) = GuestFileBrowserAdapter
            .externalDrop(on: board) else {
            return XCTFail("a plain file URL must still be redeemable")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       [url.lastPathComponent])
    }

    func testAPromiseOnlyDragIsReadAsPromisesRatherThanAsNothing() throws {
        let board = try pasteboard()
        board.writeObjects([NSFilePromiseProvider(
            fileType: UTType.plainText.identifier, delegate: delegate)])

        guard case .promises(let receivers) = GuestFileBrowserAdapter
            .externalDrop(on: board) else {
            return XCTFail("a promise-only source used to land nowhere")
        }
        XCTAssertEqual(receivers.count, 1)
    }

    func testADragCarryingNeitherIsUnreadable() throws {
        let board = try pasteboard()
        board.setString("just some text", forType: .string)

        guard case .unreadable = GuestFileBrowserAdapter
            .externalDrop(on: board) else {
            return XCTFail("text is not a file this browser can send")
        }
    }

    /// The agreement itself. `validateDrop` runs on every mouse move and so
    /// asks the cheap question; `acceptDrop` asks the expensive one once.
    /// Two questions with two answers is the defect, so they are pinned to
    /// the same verdict for every shape of pasteboard above.
    func testTheCheapValidateQuestionAgreesWithWhatAcceptCanRedeem() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let urlBoard = try pasteboard()
        urlBoard.writeObjects([url as NSURL])
        let promiseBoard = try pasteboard()
        promiseBoard.writeObjects([NSFilePromiseProvider(
            fileType: UTType.plainText.identifier, delegate: delegate)])
        let textBoard = try pasteboard()
        textBoard.setString("just some text", forType: .string)
        let emptyBoard = try pasteboard()

        for board in [urlBoard, promiseBoard, textBoard, emptyBoard] {
            let redeemable: Bool
            if case .unreadable = GuestFileBrowserAdapter
                .externalDrop(on: board) {
                redeemable = false
            } else {
                redeemable = true
            }
            XCTAssertEqual(
                GuestFileBrowserAdapter.canReadExternalDrop(board),
                redeemable,
                "validateDrop must claim exactly what acceptDrop redeems")
        }
    }
}
