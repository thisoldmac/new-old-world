import Foundation
import XCTest
@testable import Host

/* The store's two promises, tested against the artifact rather than
   the intent: what was saved comes back, and listing the catalog does
   not touch a transcript file. The second is asserted by making the
   transcripts UNREADABLE — a listing that read them could not pass. */
final class ChatStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-chat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func transcript(prompt: String,
                            answer: String) -> StoredChatTranscript {
        StoredChatTranscript(
            rows: [
                StoredChatRow(kind: .person, text: prompt),
                StoredChatRow(kind: .tool, text: "screen.capture",
                              toolName: "screen.capture", toolOK: true),
                StoredChatRow(kind: .model, text: answer),
            ],
            turns: [
                .user(prompt),
                ChatTurn(role: .assistant, content: [
                    .toolCall(ChatToolCall(
                        id: "call-1", name: "screen.capture",
                        argumentsJSON: "{}")),
                ]),
                ChatTurn(role: .tool, content: [
                    .toolResult(id: "call-1", text: "captured",
                                imagePNG: Data([0x89, 0x50, 0x4E, 0x47]),
                                isError: false),
                ]),
                ChatTurn(role: .assistant, content: [.text(answer)]),
            ])
    }

    func testChatAndTranscriptSurviveAFreshStore() throws {
        let root = try root()
        let store = try ChatStore(root: root)
        let chat = try store.createChat(title: "Memory Meter")
        let saved = transcript(prompt: "What is on screen?",
                               answer: "A Finder window.")
        try store.saveTranscript(saved, for: chat.id)

        let reopened = try ChatStore(root: root)
        let listed = try XCTUnwrap(reopened.list().first)
        XCTAssertEqual(listed.id, chat.id)
        XCTAssertEqual(listed.title, "Memory Meter")
        XCTAssertEqual(listed.turnCount, 4)
        XCTAssertEqual(try reopened.loadTranscript(chat.id), saved)
    }

    func testListingNeverReadsTranscripts() throws {
        let root = try root()
        let store = try ChatStore(root: root)
        let first = try store.createChat(title: "One")
        let second = try store.createChat(title: "Two")
        try store.saveTranscript(transcript(prompt: "hi", answer: "hello"),
                                 for: first.id)
        try store.saveTranscript(transcript(prompt: "again", answer: "sure"),
                                 for: second.id)

        /* Both transcripts are now garbage on disk. The catalog must be
           entirely unaffected: it is metadata, in different files, and
           reading a transcript is what SELECTION does. */
        for id in [first.id, second.id] {
            try Data("not json at all".utf8).write(
                to: root.appendingPathComponent(
                    "transcripts/\(id.rawValue).json"))
        }

        let listed = try store.list()
        XCTAssertEqual(Set(listed.map(\.title)), ["One", "Two"])
        XCTAssertEqual(listed.map(\.turnCount), [4, 4])
        XCTAssertThrowsError(try store.loadTranscript(first.id),
                             "selection is the read, and it must surface")
    }

    func testTranscriptOfAnUnsavedChatReadsEmpty() throws {
        let store = try ChatStore(root: try root())
        let chat = try store.createChat()
        XCTAssertEqual(try store.loadTranscript(chat.id),
                       StoredChatTranscript())
        XCTAssertEqual(chat.title, ChatStore.untitled)
    }

    func testBootstrapAdoptsTheLiveConversationAsChatOne() throws {
        let root = try root()
        let store = try ChatStore(root: root)
        let live = transcript(prompt: "Does the Mac see the drive?",
                              answer: "It does.")

        let adopted = try store.bootstrap(adopting: live)
        XCTAssertEqual(adopted.title, "Does the Mac see the drive?")
        XCTAssertEqual(try store.loadTranscript(adopted.id), live)

        /* A second launch adopts nothing: the catalog is no longer
           empty, so the live pane is a chat that already exists. */
        let again = try ChatStore(root: root).bootstrap(
            adopting: transcript(prompt: "different", answer: "different"))
        XCTAssertEqual(again.id, adopted.id)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.loadTranscript(adopted.id), live)
    }

    func testBootstrapWithNothingLiveMakesAnEmptyChat() throws {
        let store = try ChatStore(root: try root())
        let chat = try store.bootstrap()
        XCTAssertEqual(chat.title, ChatStore.untitled)
        XCTAssertEqual(chat.turnCount, 0)
        XCTAssertTrue(try store.loadTranscript(chat.id).isEmpty)
    }

    func testRenameAndDelete() throws {
        let root = try root()
        let store = try ChatStore(root: root)
        let chat = try store.createChat(title: "Untitled")
        try store.saveTranscript(transcript(prompt: "a", answer: "b"),
                                 for: chat.id)
        XCTAssertEqual(try store.rename(chat.id, to: "  Drive probe  ").title,
                       "Drive probe")
        XCTAssertThrowsError(try store.rename(chat.id, to: "   "))

        try store.delete(chat.id)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(
                "transcripts/\(chat.id.rawValue).json").path))
        XCTAssertThrowsError(try store.delete(chat.id))
        XCTAssertThrowsError(try store.loadTranscript(chat.id))
    }

    func testAProjectIsAFolderThatMayReferenceABuildableProject() throws {
        let store = try ChatStore(root: try root())
        let project = try store.createProject(name: "Memory Meter")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.folderURL(for: project.id).path))
        XCTAssertNil(project.linkedProjectID)

        let buildable = ProjectID.mint()
        XCTAssertEqual(
            try store.associate(project.id, with: buildable).linkedProjectID,
            buildable)
        XCTAssertEqual(try ChatStore(root: store.root)
            .project(project.id).linkedProjectID, buildable)
        XCTAssertNil(try store.associate(project.id, with: nil)
            .linkedProjectID)
        XCTAssertEqual(try store.renameProject(project.id, to: "Meter").name,
                       "Meter")
    }

    func testDeletingAProjectKeepsItsChats() throws {
        let store = try ChatStore(root: try root())
        let project = try store.createProject(name: "Memory Meter")
        let filed = try store.createChat(title: "Filed", in: project.id)
        let loose = try store.createChat(title: "Loose")
        XCTAssertEqual(try store.summary(filed.id).projectID, project.id)

        try store.deleteProject(project.id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.folderURL(for: project.id).path))
        XCTAssertTrue(try store.listProjects().isEmpty)
        XCTAssertEqual(Set(try store.list().map(\.title)), ["Filed", "Loose"])
        XCTAssertNil(try store.summary(filed.id).projectID)
        XCTAssertNil(try store.summary(loose.id).projectID)
        XCTAssertThrowsError(try store.createChat(title: "Orphan",
                                                  in: project.id))
    }

    func testListingIsNewestFirst() throws {
        let store = try ChatStore(root: try root())
        let old = try store.createChat(
            title: "Old", now: Date(timeIntervalSince1970: 1_000))
        let recent = try store.createChat(
            title: "Recent", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.list().map(\.id), [recent.id, old.id])
        try store.saveTranscript(transcript(prompt: "a", answer: "b"),
                                 for: old.id,
                                 now: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(try store.list().map(\.id), [old.id, recent.id])
    }

    func testTitleFromPromptTrimsToASidebarWidth() throws {
        XCTAssertEqual(ChatStore.title(fromPrompt: "  hello \n world "),
                       "hello")
        let long = String(repeating: "a", count: 80)
        let title = ChatStore.title(fromPrompt: long)
        XCTAssertEqual(title.count, 48)
        XCTAssertTrue(title.hasSuffix("\u{2026}"))
        XCTAssertEqual(ChatStore.title(fromPrompt: "   "), ChatStore.untitled)
    }
}
