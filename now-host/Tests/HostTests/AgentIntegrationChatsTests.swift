import Foundation
import XCTest
@testable import Host
@testable import NOWAgentIntegration

/* `now_chats` — the row that lets an agent see and write into the
   conversation a person is having at the classic machine.

   The tests that matter here are the bounds and the honesty: a listing
   and a transcript page, a transcript pages from the NEWEST end, an
   appended message is a note rather than the assistant's words, and an
   identifier a caller invented is refused by name instead of crashing a
   force-unwrap or silently missing. */
@MainActor
final class AgentIntegrationChatsTests: XCTestCase {
    private func store() throws -> ChatStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-agent-chats-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ChatStore(root: root)
    }

    private func adapter(_ chatStore: ChatStore)
        -> AgentIntegrationHostAdapter {
        AgentIntegrationHostAdapter(
            listener: GuestListener(identity: .init(
                version: "chats-test", name: "Chats Test Host")),
            chatStore: chatStore)
    }

    func testListingCarriesOriginAndNoTranscriptText() throws {
        let chatStore = try store()
        let typedHere = try chatStore.createChat(
            title: "typed upstairs", origin: .host)
        _ = try chatStore.saveTranscript(
            StoredChatTranscript(
                rows: [StoredChatRow(kind: .model, text: "a secret answer",
                                     toolName: nil, toolOK: nil)],
                turns: []),
            for: typedHere.id)
        _ = try chatStore.createChat(title: "typed at the 1400c",
                                     origin: .guest)

        let result = adapter(chatStore).chats(.init(operation: .list))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(Set(result.chats?.map(\.origin) ?? []),
                       ["host", "guest"])
        // A listing is metadata. If it ever carries the words, listing
        // becomes expensive and reading becomes pointless.
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("a secret answer"))
    }

    func testATranscriptPagesFromTheNewestEnd() throws {
        let chatStore = try store()
        let chat = try chatStore.createChat(title: "long one", origin: .guest)
        var transcript = StoredChatTranscript()
        for index in 0..<100 {
            transcript.rows.append(StoredChatRow(
                kind: .model, text: "line \(index)",
                toolName: nil, toolOK: nil))
        }
        _ = try chatStore.saveTranscript(transcript, for: chat.id)
        let adapter = adapter(chatStore)

        let newest = adapter.chats(
            .init(operation: .read, chatID: chat.id.rawValue))
        XCTAssertEqual(newest.rows?.last?.text, "line 99")
        XCTAssertEqual(newest.more, true)

        let older = adapter.chats(.init(
            operation: .read, chatID: chat.id.rawValue,
            cursor: newest.rows?.count ?? 0))
        XCTAssertEqual(older.rows?.last?.text,
                       "line \(99 - (newest.rows?.count ?? 0))")
    }

    /// An agent's message is neither the person's nor the model's, and
    /// it must not be re-sent to the model as if the assistant had said
    /// it.
    func testAnAppendedMessageIsANoteAndNotAModelTurn() throws {
        let chatStore = try store()
        let chat = try chatStore.createChat(title: "with an agent",
                                            origin: .guest)
        _ = try chatStore.saveTranscript(
            StoredChatTranscript(rows: [], turns: [.user("what broke?")]),
            for: chat.id)

        let result = adapter(chatStore).chats(.init(
            operation: .append, chatID: chat.id.rawValue,
            text: "The build failed on line 12."))
        XCTAssertTrue(result.ok)

        let saved = try chatStore.loadTranscript(chat.id)
        XCTAssertEqual(saved.rows.last?.kind, .note)
        XCTAssertEqual(saved.rows.last?.text, "The build failed on line 12.")
        XCTAssertEqual(saved.turns.count, 1,
                       "an agent's aside joined the conversation the model "
                           + "is re-sent")
    }

    func testCreatingAndFilingAChat() throws {
        let chatStore = try store()
        let project = try chatStore.createProject(
            name: "Beeper", intendedHome: .guest)
        let adapter = adapter(chatStore)

        let made = adapter.chats(.init(operation: .create, title: "new work"))
        let id = try XCTUnwrap(made.chat?.id)
        XCTAssertEqual(made.chat?.title, "new work")

        let filed = adapter.chats(.init(
            operation: .file, chatID: id, projectID: project.id.rawValue))
        XCTAssertEqual(filed.chat?.projectID, project.id.rawValue)

        let projects = adapter.chats(.init(operation: .projects))
        XCTAssertEqual(projects.projects?.map(\.home), ["guest"])

        let loose = adapter.chats(.init(operation: .file, chatID: id))
        XCTAssertNil(loose.chat?.projectID)
    }

    /// An identifier a caller sent is a CLAIM. It is refused by name
    /// rather than force-unwrapped into a crash.
    func testAnInventedIdentifierIsRefusedRatherThanCrashing() throws {
        let chatStore = try store()
        let adapter = adapter(chatStore)

        let badChat = adapter.chats(.init(
            operation: .read, chatID: "not-a-chat"))
        XCTAssertFalse(badChat.ok)
        XCTAssertEqual(badChat.failure?.code, "now-chats-unknown-chat")

        let badProject = adapter.chats(.init(
            operation: .create, projectID: "nope"))
        XCTAssertEqual(badProject.failure?.code, "now-chats-unknown-project")
    }

    /// The shapes are checked before anything is looked up — the
    /// projects rule, and what stops an operation from quietly ignoring
    /// an argument it does not take.
    func testRequestShapesRefuseArgumentsTheirOperationDoesNotTake() {
        XCTAssertFalse(AgentIntegrationChatRequest(
            operation: .list, chatID: "0123456789abcdef0123456789abcdef")
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationChatRequest(operation: .read)
            .isWellFormed)
        XCTAssertFalse(AgentIntegrationChatRequest(
            operation: .append, chatID: "0123456789abcdef0123456789abcdef")
            .isWellFormed, "an append with nothing to append")
        XCTAssertFalse(AgentIntegrationChatRequest(
            operation: .create, title: String(repeating: "x", count: 201))
            .isWellFormed)
        XCTAssertTrue(AgentIntegrationChatRequest(
            operation: .read, chatID: "0123456789abcdef0123456789abcdef",
            cursor: 40).isWellFormed)
    }

    /// The projection refuses what the request type refuses, so a caller
    /// reads one vocabulary rather than two.
    func testTheProjectionRefusesAMalformedCall() async {
        let outcome = await ChatsProjection.invoke(
            .init(raw: ["operation": "read"]),
            through: NoChatsClient())
        guard case .invalidArguments(let message) = outcome else {
            return XCTFail("a read with no chat was accepted")
        }
        XCTAssertTrue(message.contains("now_chats"), message)
    }
}

private struct NoChatsClient: AgentIntegrationClient {
    func addressing(_ selector: String?) -> AgentIntegrationClient { self }
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult { .unavailable(.host) }
    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult { .unavailable(.host) }
    func requestQuit(reference: String) async
        -> AgentIntegrationQuitResult { .unavailable(.host) }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult { .unavailable(.host) }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult { .hostUnavailable(.host) }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult { .hostUnavailable(.host) }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult { .hostUnavailable(.host) }
}
