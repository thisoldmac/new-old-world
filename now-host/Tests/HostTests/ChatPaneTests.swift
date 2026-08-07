import SwiftUI
import XCTest

@testable import Host

/* The Chat page's pure parts: the markdown block parser, the
   composer's send/stop rules, the model menu's grouping and search,
   and the rewind that a retry and an edit both stand on. Every guard
   here was watched to fail by breaking the thing it names — the
   mutations are noted where they are not obvious. */

final class ChatMarkdownParserTests: XCTestCase {
    func testHeadingsListsAndParagraphsSeparate() {
        let blocks = ChatMarkdown.parse("""
            ## Findings

            The disk is nearly full.

            - 4 MB free
            - 92 files
            """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Findings"),
            .paragraph("The disk is nearly full."),
            .bullets(["4 MB free", "92 files"]),
        ])
    }

    func testFencedCodeKeepsItsLanguageAndBody() {
        let blocks = ChatMarkdown.parse("""
            Try:

            ```applescript
            tell application "Finder"
                activate
            end tell
            ```
            """)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last, .code(
            language: "applescript",
            text: "tell application \"Finder\"\n    activate\nend tell",
            closed: true))
    }

    /// The streaming case: half a fence is a code block already. Read
    /// as a paragraph, it flashed three literal backticks and its own
    /// source at the person until the closing fence arrived.
    func testUnterminatedFenceIsAlreadyCode() {
        let blocks = ChatMarkdown.parse("```swift\nlet x = 1")
        XCTAssertEqual(
            blocks, [.code(language: "swift", text: "let x = 1",
                           closed: false)])
    }

    func testFenceWithoutALanguageHasNone() {
        XCTAssertEqual(
            ChatMarkdown.parse("```\nplain\n```"),
            [.code(language: nil, text: "plain", closed: true)])
    }

    /// "---" is a rule and "- x" an item; the bullet test running
    /// first swallowed every horizontal rule as a bullet with no text.
    func testRuleIsNotABullet() {
        XCTAssertEqual(ChatMarkdown.parse("---"), [.rule])
        XCTAssertEqual(ChatMarkdown.parse("- x"), [.bullets(["x"])])
    }

    func testNumberedListKeepsItsStartingNumber() {
        XCTAssertEqual(
            ChatMarkdown.parse("3. third\n4. fourth"),
            [.numbered(start: 3, items: ["third", "fourth"])])
    }

    /// A wrapped list item arrives indented under its own bullet.
    func testIndentedContinuationJoinsItsItem() {
        XCTAssertEqual(
            ChatMarkdown.parse("- a long item\n  that wrapped\n- second"),
            [.bullets(["a long item that wrapped", "second"])])
    }

    func testBlockquoteStripsItsMarkers() {
        XCTAssertEqual(
            ChatMarkdown.parse("> quoted\n> lines"),
            [.quote(["quoted", "lines"])])
    }

    func testHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(
            ChatMarkdown.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testPlainProseStaysOneParagraph() {
        XCTAssertEqual(
            ChatMarkdown.parse("one\ntwo"), [.paragraph("one\ntwo")])
    }

    func testEmptySourceHasNoBlocks() {
        XCTAssertEqual(ChatMarkdown.parse(""), [])
        XCTAssertEqual(ChatMarkdown.parse("\n\n  \n"), [])
    }
}

final class ChatMarkdownInlineTests: XCTestCase {
    func testEmphasisAndInlineCodeLoseTheirMarkers() {
        let out = ChatMarkdownInline.attributed(
            "**bold** and `code` here")
        XCTAssertEqual(String(out.characters), "bold and code here")
    }

    func testInlineCodeGetsAMonospacedFace() {
        let out = ChatMarkdownInline.attributed("say `hello` now")
        let coded = out.runs.filter { $0.font != nil }
        XCTAssertEqual(coded.count, 1)
        XCTAssertEqual(
            String(out[coded[0].range].characters), "hello")
    }

    func testUnbalancedEmphasisSurvivesAsItself() {
        // Mid-stream text is parsed on every delta; a throw here would
        // have blanked the answer until the closing asterisks landed.
        let out = ChatMarkdownInline.attributed("half **way")
        XCTAssertTrue(String(out.characters).contains("way"))
    }
}

final class ChatComposerStateTests: XCTestCase {
    private func state(
        draft: String = "hi", isStreaming: Bool = false,
        hasModels: Bool = true, hasSelection: Bool = true
    ) -> ChatComposerState {
        ChatComposerState.state(
            draft: draft, isStreaming: isStreaming,
            hasModels: hasModels, hasSelection: hasSelection)
    }

    func testReadyDraftSends() {
        XCTAssertEqual(state(), .send)
    }

    /// Stop outranks every block: a turn started before the provider
    /// was removed must still be stoppable.
    func testStreamingAlwaysOffersStop() {
        XCTAssertEqual(
            state(draft: "", isStreaming: true, hasModels: false,
                  hasSelection: false), .stop)
    }

    func testBlocksNameWhatIsMissing() {
        XCTAssertEqual(state(hasModels: false), .blocked(.noProvider))
        XCTAssertEqual(state(hasSelection: false), .blocked(.noModel))
        XCTAssertEqual(state(draft: "   \n"), .blocked(.emptyDraft))
    }

    /// Only the empty draft leaves the field usable — the other two
    /// blocks are a pane that cannot be used yet.
    func testOnlyAnEmptyDraftStillAcceptsTyping() {
        XCTAssertTrue(state(draft: "").acceptsTyping)
        XCTAssertFalse(state(hasModels: false).acceptsTyping)
        XCTAssertFalse(state(hasSelection: false).acceptsTyping)
        XCTAssertTrue(state().acceptsTyping)
        XCTAssertTrue(state(isStreaming: true).acceptsTyping)
    }
}

final class ChatModelMenuTests: XCTestCase {
    private let providers = [
        ChatProviderEntry(id: "anthropic", label: "Anthropic",
                          state: "serving", detail: ""),
        ChatProviderEntry(id: "ollama", label: "Ollama",
                          state: "serving", detail: ""),
    ]
    private let models = [
        ChatModel(providerID: "anthropic", modelID: "claude-opus-5",
                  displayName: "Claude Opus 5"),
        ChatModel(providerID: "anthropic", modelID: "claude-sonnet-5",
                  displayName: "Claude Sonnet 5"),
        ChatModel(providerID: "ollama", modelID: "llama3:8b",
                  displayName: "llama3:8b"),
    ]

    func testGroupsFollowRegistryOrder() {
        let groups = ChatModelMenu.groups(
            models: models, providers: providers, query: "")
        XCTAssertEqual(groups.map(\.providerID), ["anthropic", "ollama"])
        XCTAssertEqual(groups[0].models.count, 2)
    }

    func testProviderWithNoModelsIsNotAHeading() {
        let withEmpty = providers + [
            ChatProviderEntry(id: "openai", label: "OpenAI",
                              state: "no-access", detail: "No key"),
        ]
        let groups = ChatModelMenu.groups(
            models: models, providers: withEmpty, query: "")
        XCTAssertFalse(groups.contains { $0.providerID == "openai" })
    }

    func testSearchMatchesModelNames() {
        let groups = ChatModelMenu.groups(
            models: models, providers: providers, query: "sonnet")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].models.map(\.modelID), ["claude-sonnet-5"])
    }

    /// Typing a provider's name asks for its models, not for the
    /// models that happen to spell it in their own name.
    func testSearchingAProviderKeepsItsWholeGroup() {
        let groups = ChatModelMenu.groups(
            models: models, providers: providers, query: "anthro")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].models.count, 2)
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(
            ChatModelMenu.groups(models: models, providers: providers,
                                 query: "LLAMA").first?.providerID,
            "ollama")
    }

    func testNoMatchIsNoGroups() {
        XCTAssertTrue(ChatModelMenu.groups(
            models: models, providers: providers, query: "zzz").isEmpty)
    }

    func testButtonNamesTheModelAndNeverNothing() {
        XCTAssertEqual(
            ChatModelMenu.buttonTitle(selection: "anthropic/claude-opus-5",
                                      models: models),
            "Claude Opus 5")
        // A saved selection whose provider went away still reads as
        // something, rather than an empty button.
        XCTAssertEqual(
            ChatModelMenu.buttonTitle(selection: "openai/gpt-5",
                                      models: models),
            "openai/gpt-5")
        XCTAssertEqual(
            ChatModelMenu.buttonTitle(selection: "", models: models),
            "No model")
    }
}

final class ChatRewindTests: XCTestCase {
    private func transcript() -> [ChatDisplayRow] {
        [
            ChatDisplayRow(kind: .person, text: "first question"),
            ChatDisplayRow(kind: .model, text: "first answer"),
            ChatDisplayRow(kind: .person, text: "second question"),
            ChatDisplayRow(kind: .tool(name: "now_machine_facts", ok: true),
                           text: "now_machine_facts"),
            ChatDisplayRow(kind: .model, text: "second answer"),
        ]
    }

    private func turns() -> [ChatTurn] {
        [
            .user("first question"),
            ChatTurn(role: .assistant, content: [.text("first answer")]),
            .user("second question"),
            ChatTurn(role: .assistant, content: [.text("second answer")]),
        ]
    }

    func testRetryDropsThePromptAndEverythingAfterIt() {
        let out = ChatRewind.toLastPrompt(
            rows: transcript(), turns: turns())
        XCTAssertEqual(out?.prompt, "second question")
        XCTAssertEqual(out?.rows.map(\.text),
                       ["first question", "first answer"])
    }

    /// The two halves must land on the same place. Rewinding the rows
    /// only would re-ask the question with the answer being replaced
    /// still in the model's context.
    func testRetryRewindsTheConversationTurnsToo() {
        let out = ChatRewind.toLastPrompt(
            rows: transcript(), turns: turns())
        XCTAssertEqual(out?.turns.count, 2)
        XCTAssertEqual(out?.turns.last?.role, .assistant)
    }

    func testEditingAnEarlierPromptCutsEverythingAfterIt() {
        let rows = transcript()
        let out = ChatRewind.toPrompt(
            id: rows[0].id, rows: rows, turns: turns())
        XCTAssertEqual(out?.prompt, "first question")
        XCTAssertEqual(out?.rows, [])
        XCTAssertEqual(out?.turns, [])
    }

    func testARowThatIsNotAPromptRewindsNothing() {
        let rows = transcript()
        XCTAssertNil(ChatRewind.toPrompt(
            id: rows[1].id, rows: rows, turns: turns()))
        XCTAssertNil(ChatRewind.toPrompt(
            id: UUID(), rows: rows, turns: turns()))
    }

    func testAnEmptyTranscriptHasNothingToRetry() {
        XCTAssertNil(ChatRewind.toLastPrompt(rows: [], turns: []))
    }

    /// Tool rows and notes sit between prompts and are not turns; the
    /// anchor counts PROMPTS, so an extra one cannot shift the cut.
    func testNotesAndToolRowsDoNotShiftTheAnchor() {
        var rows = transcript()
        rows.insert(ChatDisplayRow(kind: .note, text: "rate limited"),
                    at: 2)
        let out = ChatRewind.toLastPrompt(rows: rows, turns: turns())
        XCTAssertEqual(out?.prompt, "second question")
        XCTAssertEqual(out?.turns.count, 2)
    }
}

final class ChatToolTitleTests: XCTestCase {
    func testToolNamesReadAsSentences() {
        XCTAssertEqual(ChatToolTitle.of("now_capture_screen"),
                       "Capture screen")
        XCTAssertEqual(ChatToolTitle.of("health"), "Health")
    }
}
