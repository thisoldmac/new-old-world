import Foundation
import XCTest
@testable import Host

/* The page's side of saved chats: what happens when the page appears,
   when the selection moves, and when a chat is deleted. Built against
   a real ChatModuleModel with a temporary store and an unstarted
   listener — no provider is ever reached, because every case here is
   about which transcript is on screen, not about answering. */
@MainActor
final class ChatSessionTests: XCTestCase {
    private func makeModel(store: ChatStore) -> ChatModuleModel {
        let listener = GuestListener(
            identity: .init(version: "chat-test", name: "Chat Test Host"))
        let defaults = UserDefaults(
            suiteName: "now.chat-tests.\(UUID().uuidString)")!
        return ChatModuleModel(
            agentIntegration: AgentIntegrationHostAdapter(listener: listener),
            guestFiles: GuestFilesCommandService(
                listener: listener,
                policy: GuestFileAccessPolicy(defaults: defaults),
                currentSessionID: { nil }),
            agentActivity: nil,
            defaults: defaults,
            chatStore: store)
    }

    private func store() throws -> ChatStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-chat-session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try ChatStore(root: url)
    }

    /// The one way to put a row in the pane without a provider: asking
    /// with no model selected answers with a note, in the transcript.
    private func addRow(_ model: ChatModuleModel, _ text: String) {
        model.send(text)
    }

    func testFirstAppearanceCreatesChatOneAndSelectsIt() throws {
        let store = try store()
        let model = makeModel(store: store)
        model.bootstrapChats()

        XCTAssertEqual(model.chats.count, 1)
        XCTAssertEqual(model.selectedChatID, model.chats.first?.id)
        // Idempotent: appearing again is not a second chat.
        model.bootstrapChats()
        XCTAssertEqual(model.chats.count, 1)
    }

    func testAConversationAlreadyOnScreenBecomesChatOne() throws {
        let store = try store()
        let model = makeModel(store: store)
        addRow(model, "what is on screen?")
        XCTAssertFalse(model.transcript.isEmpty)

        model.bootstrapChats()

        let adopted = try XCTUnwrap(model.chats.first)
        XCTAssertEqual(model.selectedChatID, adopted.id)
        let saved = try store.loadTranscript(adopted.id)
        XCTAssertEqual(saved.rows.map(\.text), model.transcript.map(\.text))
    }

    func testSwitchingChatsSwapsTheTranscript() throws {
        let store = try store()
        let model = makeModel(store: store)
        model.bootstrapChats()
        let first = try XCTUnwrap(model.selectedChatID)
        addRow(model, "first chat")
        model.persistCurrentChat()

        model.newChat()
        let second = try XCTUnwrap(model.selectedChatID)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(model.transcript.isEmpty)

        model.selectChat(first)
        XCTAssertEqual(model.selectedChatID, first)
        XCTAssertEqual(model.transcript.first?.text, "Pick a model first")

        model.selectChat(second)
        XCTAssertTrue(model.transcript.isEmpty)
    }

    func testDeletingTheOpenChatMovesToAnother() throws {
        let store = try store()
        let model = makeModel(store: store)
        model.bootstrapChats()
        let first = try XCTUnwrap(model.selectedChatID)
        addRow(model, "keep me")
        model.newChat()
        let second = try XCTUnwrap(model.selectedChatID)

        model.deleteChat(second)
        XCTAssertEqual(model.selectedChatID, first)
        XCTAssertEqual(model.chats.map(\.id), [first])
        XCTAssertFalse(model.transcript.isEmpty)

        // Deleting the last one leaves a fresh empty chat, never none.
        model.deleteChat(first)
        XCTAssertEqual(model.chats.count, 1)
        XCTAssertNotEqual(model.selectedChatID, first)
        XCTAssertTrue(model.transcript.isEmpty)
    }

    func testChatsFileUnderProjectsAndTakeTheirFirstPromptAsATitle() throws {
        let store = try store()
        let model = makeModel(store: store)
        model.bootstrapChats()
        let chat = try XCTUnwrap(model.selectedChatID)
        addRow(model, "does the Mac see the drive?")
        model.persistCurrentChat()
        XCTAssertEqual(try store.summary(chat).title, "Pick a model first")

        let project = try XCTUnwrap(model.newChatProject(name: "Memory Meter"))
        model.fileChat(chat, under: project.id)
        XCTAssertEqual(model.chats.first?.projectID, project.id)

        model.deleteChatProject(project.id)
        XCTAssertTrue(model.chatProjects.isEmpty)
        XCTAssertNil(model.chats.first?.projectID)
    }

    /// No store (Application Support unwritable) is a degraded chat,
    /// not a broken one: the pane still works, unsaved.
    func testWithoutAStoreThePaneStillWorks() {
        let listener = GuestListener(
            identity: .init(version: "chat-test", name: "Chat Test Host"))
        let defaults = UserDefaults(
            suiteName: "now.chat-tests.\(UUID().uuidString)")!
        let model = ChatModuleModel(
            agentIntegration: AgentIntegrationHostAdapter(listener: listener),
            guestFiles: GuestFilesCommandService(
                listener: listener,
                policy: GuestFileAccessPolicy(defaults: defaults),
                currentSessionID: { nil }),
            agentActivity: nil, defaults: defaults, chatStore: nil)
        model.bootstrapChats()
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertNil(model.selectedChatID)
        model.send("hello")
        XCTAssertFalse(model.transcript.isEmpty)
        model.newChat()
        XCTAssertTrue(model.transcript.isEmpty)
    }
}
