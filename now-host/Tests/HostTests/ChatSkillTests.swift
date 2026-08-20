import Foundation
import XCTest
@testable import Host

/* The skill lane: what a slash means, what the prompt carries, and that
   the tree this repository actually ships is readable. */
final class ChatSkillTests: XCTestCase {
    private let known = ["classic-mac-carbon-ui", "classic-mac-toolbox-ui"]

    // MARK: - What a slash means

    func testOrdinaryTextIsNotACommand() {
        XCTAssertNil(ChatSlashCommand.parse("what is running?", known: known))
        XCTAssertNil(ChatSlashCommand.parse("", known: known))
        // A lone slash is a typo, not a command with an empty name.
        XCTAssertNil(ChatSlashCommand.parse("/", known: known))
        // A slash in the MIDDLE is content: paths and dates have them.
        XCTAssertNil(ChatSlashCommand.parse(
            "open System Folder/Extensions", known: known))
    }

    func testTheListingAndALoadAreToldApart() {
        XCTAssertEqual(ChatSlashCommand.parse("/skills", known: known), .list)
        XCTAssertEqual(
            ChatSlashCommand.parse("/classic-mac-carbon-ui", known: known),
            .load(name: "classic-mac-carbon-ui", rest: ""))
    }

    /// A command with a question after it does both in one round trip.
    func testACommandCarriesTheQuestionAfterIt() {
        XCTAssertEqual(
            ChatSlashCommand.parse(
                "/classic-mac-carbon-ui how do I draw a tab?", known: known),
            .load(name: "classic-mac-carbon-ui", rest: "how do I draw a tab?"))
    }

    /// An unknown slash must NOT reach the model: somebody who mistyped
    /// wants to hear so, not to watch a model improvise an answer to it.
    func testAnUnknownSlashIsRefusedRatherThanSentOn() {
        XCTAssertEqual(ChatSlashCommand.parse("/carbn", known: known),
                       .unknown(name: "carbn"))
        XCTAssertEqual(ChatSlashCommand.parse("/CLASSIC-MAC-CARBON-UI",
                                              known: known),
                       .load(name: "classic-mac-carbon-ui", rest: ""))
    }

    // MARK: - Reading a skill

    func testFrontMatterBecomesTheListingAndTheRestTheInstruction() throws {
        let skill = try XCTUnwrap(ChatSkillLibrary.parse("""
            ---
            name: classic-mac-carbon-ui
            description: Design and review Carbon UI.
            ---

            # Classic Mac Carbon UI

            Build interfaces that look native.
            """, fallbackName: "folder-name"))

        XCTAssertEqual(skill.name, "classic-mac-carbon-ui")
        XCTAssertEqual(skill.description, "Design and review Carbon UI.")
        XCTAssertTrue(skill.body.hasPrefix("# Classic Mac Carbon UI"))
        XCTAssertFalse(skill.body.contains("description:"),
                       "front matter leaked into the instruction")
        XCTAssertEqual(skill.command, "/classic-mac-carbon-ui")
    }

    /// The instruction is the valuable half. A file with no front matter
    /// still loads, named for its folder — refusing it over a missing
    /// sentence would lose the thing somebody wanted.
    func testASkillWithNoFrontMatterStillLoads() throws {
        let skill = try XCTUnwrap(ChatSkillLibrary.parse(
            "Pump the wire inside every nested Toolbox loop.",
            fallbackName: "classic-mac-toolbox-ui"))

        XCTAssertEqual(skill.name, "classic-mac-toolbox-ui")
        XCTAssertEqual(skill.description, "")
        XCTAssertFalse(skill.body.isEmpty)
    }

    func testAnEmptySkillIsNotASkill() {
        XCTAssertNil(ChatSkillLibrary.parse("---\nname: x\n---\n\n   \n",
                                            fallbackName: "x"))
    }

    // MARK: - The tree this repository ships

    /* Read from disk rather than from a fixture: the point of vendoring
       was that the knowledge ships, and a test over a hand-written
       string would pass with `skills/` deleted. */
    func testTheVendoredClassicMacTreeIsReadable() throws {
        let root = try XCTUnwrap(ChatSkillLibrary.repositoryRoot())
        let library = ChatSkillLibrary(skills: ChatSkillLibrary.read(
            root.appendingPathComponent("skills")))

        XCTAssertEqual(library.names.count, 8, "\(library.names)")
        XCTAssertTrue(library.names.contains("classic-mac-carbon-ui"))
        XCTAssertTrue(library.names.contains("classic-mac-toolbox-platform"))
        for skill in library.skills {
            XCTAssertFalse(skill.description.isEmpty,
                           "\(skill.name) has no sentence for the listing")
            XCTAssertGreaterThan(skill.body.count, 400,
                                 "\(skill.name) has no instruction worth loading")
        }
    }

    /// The catalogue is what makes a skill discoverable at all — the
    /// model can name one it would like, and a person can read the list.
    func testTheCatalogueNamesEverySkillWithItsCommand() throws {
        let root = try XCTUnwrap(ChatSkillLibrary.repositoryRoot())
        let library = ChatSkillLibrary(skills: ChatSkillLibrary.read(
            root.appendingPathComponent("skills")))

        let catalogue = library.catalogue
        for skill in library.skills {
            XCTAssertTrue(catalogue.contains(skill.command), skill.name)
        }
        // And it tells the model whose job loading is: it cannot.
        XCTAssertTrue(catalogue.contains("cannot load one yourself"))
    }

    // MARK: - The vendored copy stays vendored

    /* The provenance gate exempts `skills/`, and an exemption is a hole
       unless something says how wide it is. These assert the shape the
       exemption assumes: one provenance file at the root, and vendored
       bodies that nothing in this repository has stamped. If somebody
       later stamps them, the sync tool starts reporting every file as
       changed forever — which is how a vendored copy quietly forks. */
    func testTheVendoredTreeCarriesOneProvenanceFileAndNoStampedBodies()
        throws {
        let root = try XCTUnwrap(ChatSkillLibrary.repositoryRoot())
        let skills = root.appendingPathComponent("skills")
        let manager = FileManager.default

        XCTAssertTrue(manager.fileExists(
            atPath: skills.appendingPathComponent("PROVENANCE.md").path),
            "the vendored tree cannot say where it came from")

        var stamped: [String] = []
        let walker = manager.enumerator(at: skills,
                                        includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "PROVENANCE.md",
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if text.contains("now-doc-provenance") {
                stamped.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(stamped, [],
                       "vendored files were stamped; they must stay "
                           + "byte-identical to their source")
    }

    // MARK: - What the prompt carries

    func testALoadedSkillIsFencedAndCannotOverrideTheMachineRules() {
        let skill = ChatSkill(name: "classic-mac-carbon-ui",
                              description: "Carbon UI.",
                              body: "A UPP is never a cast on CFM.")

        let frame = ChatSystemPrompt.skillFrame(skill)

        XCTAssertTrue(frame.contains("A UPP is never a cast on CFM."))
        XCTAssertTrue(frame.contains("SKILL: classic-mac-carbon-ui"))
        XCTAssertTrue(frame.contains("the rules above win"),
                      "a skill was blended in rather than fenced")
    }

    func testTheComposedPromptCarriesTheCatalogueAndOnlyLoadedBodies() {
        let library = ChatSkillLibrary(skills: [
            ChatSkill(name: "carbon", description: "Carbon UI.",
                      body: "CARBON BODY"),
            ChatSkill(name: "toolbox", description: "Toolbox UI.",
                      body: "TOOLBOX BODY"),
        ])

        let prompt = ChatSystemPrompt.compose(
            health: .unavailable(.guest), origin: .hostPane,
            skills: library, loaded: [library["carbon"]!])

        XCTAssertTrue(prompt.contains("/carbon"))
        XCTAssertTrue(prompt.contains("/toolbox"), "the listing is not filtered")
        XCTAssertTrue(prompt.contains("CARBON BODY"))
        XCTAssertFalse(prompt.contains("TOOLBOX BODY"),
                       "an unloaded skill's instructions were sent anyway")
    }

    /// A turn with no tools is told nothing about skills either: it
    /// cannot act on craft guidance it has no hands for, and the bytes
    /// are the whole cost of a text-only relay's turn.
    func testATurnWithNoToolsStillSeesTheCatalogue() {
        let library = ChatSkillLibrary(skills: [
            ChatSkill(name: "carbon", description: "Carbon UI.", body: "BODY"),
        ])

        let prompt = ChatSystemPrompt.compose(
            health: .unavailable(.guest), origin: .hostPane,
            reach: .none(reason: "text only"), skills: library)

        // It CAN still answer from knowledge, so knowing what it could
        // be given is worth the four lines.
        XCTAssertTrue(prompt.contains("/carbon"))
    }
}
