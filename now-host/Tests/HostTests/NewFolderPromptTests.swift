import XCTest
@testable import Host

@MainActor
final class NewFolderPromptTests: XCTestCase {
    func testSubmittingANameDismissesThePromptBeforeTheWireReply() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "new-folder.\(UUID().uuidString)")!)
        model.connection = .connected(named: "PowerBook 1400")

        model.beginNewFolder()
        XCTAssertEqual(model.newFolderPrompt?.initialName, "untitled folder")

        model.createFolderFromPrompt(named: "Project")

        XCTAssertNil(model.newFolderPrompt,
                     "a completion cannot redisplay a submitted prompt")
    }

    func testCancellingDismissesThePrompt() {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "new-folder.\(UUID().uuidString)")!)
        model.connection = .connected(named: "PowerBook 1400")

        model.beginNewFolder()
        model.cancelNewFolder()

        XCTAssertNil(model.newFolderPrompt)
    }

    func testBusyModelDoesNotOpenANewFolderPrompt() {
        let model = makeConnectedModel()
        model.isChanging = true

        model.beginNewFolder()

        XCTAssertNil(model.newFolderPrompt)
    }

    func testBusyModelDoesNotOpenATrashConfirmation() {
        let model = makeConnectedModel()
        model.isChanging = true
        let row = FileRow(
            entry: FileEntry(name: "Notes", kind: "file", fileType: "TEXT",
                             creator: "ttxt", dataBytes: 10, rsrcBytes: 0,
                             modified: nil, identity: "notes"),
            path: "Lab:Notes")

        model.requestTrash([row])

        XCTAssertNil(model.pendingChange)
    }

    private func makeConnectedModel() -> FilesModuleModel {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let model = FilesModuleModel(
            listener: listener,
            defaults: UserDefaults(
                suiteName: "new-folder.\(UUID().uuidString)")!)
        model.connection = .connected(named: "PowerBook 1400")
        return model
    }
}
