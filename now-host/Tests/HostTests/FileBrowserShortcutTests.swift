import AppKit
import XCTest
@testable import Host

final class FileBrowserShortcutTests: XCTestCase {
    func testCommandDeleteMovesTheSelectionToTrash() {
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: .command, keyCode: 51, characters: "\u{7f}"),
            .trash)
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: [.command, .capsLock], keyCode: 51,
                characters: "\u{7f}"),
            .trash,
            "Caps Lock must not disable the standard delete shortcut")
    }

    func testForwardDeleteUsesTheSameTrashAction() {
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: .command, keyCode: 117, characters: nil),
            .trash)
    }

    func testDeleteWithoutCommandRemainsTableEditingInput() {
        XCTAssertNil(FileBrowserKeyAction.resolve(
            modifiers: [], keyCode: 51, characters: "\u{7f}"))
    }

    func testShiftCommandNCreatesANewFolder() {
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: [.command, .shift], keyCode: 45,
                characters: "n"),
            .newFolder)
        XCTAssertNil(FileBrowserKeyAction.resolve(
            modifiers: .command, keyCode: 45, characters: "n"))
    }

    func testExistingDownloadAndOpenShortcutsRemainAvailable() {
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: .command, keyCode: 2, characters: "d"),
            .download)
        XCTAssertEqual(
            FileBrowserKeyAction.resolve(
                modifiers: [], keyCode: 36, characters: "\r"),
            .open)
    }
}
