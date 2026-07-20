import XCTest
@testable import Host

/// Path arithmetic and the wording of the confirmation. Both are the
/// parts a person actually sees go wrong: a rename that silently drops
/// the folder it was in, or a dialog that does not say what it is about
/// to do.
final class FileChangeNameTests: XCTestCase {
    func testLeafAndParentSplitOnColons() {
        XCTAssertEqual(FileChangeNames.leaf("Lab:Code:Read Me"), "Read Me")
        XCTAssertEqual(FileChangeNames.parent("Lab:Code:Read Me"), "Lab:Code")
        XCTAssertEqual(FileChangeNames.leaf("Read Me"), "Read Me")
        XCTAssertEqual(FileChangeNames.parent("Read Me"), "")
    }

    func testJoinTreatsTheRootAsEmpty() {
        XCTAssertEqual(FileChangeNames.join("", "Notes"), "Notes")
        XCTAssertEqual(FileChangeNames.join("Lab", "Notes"), "Lab:Notes")
    }

    func testColonsAreNotNames() {
        XCTAssertNil(FileChangeNames.validate("Lab:Notes"))
        XCTAssertNil(FileChangeNames.validate(""))
        XCTAssertNil(FileChangeNames.validate(String(repeating: "a",
                                                     count: 32)))
        XCTAssertEqual(FileChangeNames.validate(String(repeating: "a",
                                                       count: 31))?.count,
                       31)
    }
}

@MainActor
final class PendingChangeWordingTests: XCTestCase {
    func testRenameNamesBothSides() {
        let pending = FilesModuleModel.PendingChange(
            kind: .rename(path: "Lab:Notes", to: "Old Notes"))
        XCTAssertEqual(pending.confirmLabel, "Rename")
        XCTAssertTrue(pending.detail.contains("\"Notes\""))
        XCTAssertTrue(pending.detail.contains("\"Old Notes\""))
    }

    func testTrashSaysItCanBePutBack() {
        let pending = FilesModuleModel.PendingChange(
            kind: .trash(paths: ["Lab:Notes"]))
        XCTAssertEqual(pending.confirmLabel, "Move to Trash")
        XCTAssertTrue(pending.detail.contains("put back"))
    }

    func testManyItemsAreCountedRatherThanListedForever() {
        let pending = FilesModuleModel.PendingChange(
            kind: .trash(paths: ["a", "b", "c", "d", "e"]))
        XCTAssertEqual(pending.title, "Move 5 items to the Trash?")
        XCTAssertTrue(pending.detail.contains("2 more"))
    }

    func testMovingToTheRootSaysSoInWords() {
        let pending = FilesModuleModel.PendingChange(
            kind: .move(paths: ["Lab:Notes"], toFolder: ""))
        XCTAssertTrue(pending.detail.contains("top of the shared folder"))
    }
}

/// The undo record has to describe the reversal, not the action: an
/// entry that cannot say what putting it back means is not an undo.
@MainActor
final class FileChangeHistoryTests: XCTestCase {
    func testAMoveWithinAFolderReadsAsARename() {
        let change = FilesModuleModel.FileChange(
            undo: .moved(from: "Lab:Notes", to: "Lab:Old Notes"))
        XCTAssertEqual(change.summary, "Renamed \"Notes\" to \"Old Notes\"")
        XCTAssertEqual(change.undoLabel, "Undo Move")
    }

    func testAMoveBetweenFoldersKeepsItsName() {
        let change = FilesModuleModel.FileChange(
            undo: .moved(from: "Lab:Notes", to: "Code:Notes"))
        XCTAssertEqual(change.summary, "Moved \"Notes\"")
    }

    func testTrashRemembersItsToken() {
        let change = FilesModuleModel.FileChange(
            undo: .trashed(path: "Lab:Notes", token: 42))
        XCTAssertEqual(change.undoLabel, "Undo Delete")
        guard case .trashed(_, let token) = change.undo else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(token, 42)
    }
}
