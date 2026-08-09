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

        model.beginNewFolder()
        model.cancelNewFolder()

        XCTAssertNil(model.newFolderPrompt)
    }
}
