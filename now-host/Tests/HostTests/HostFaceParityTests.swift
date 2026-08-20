import Foundation
import XCTest
@testable import NOWAgentIntegration

/// Every projected capability must be reachable from the host's faces — the
/// app a person launches, the MCP surface an agent calls, and (from W3) an
/// intent Siri can run — or the divergence is a decision written down with
/// its reason.
///
/// This is `CommandParityTests` pointed at the other side of the wire, and it
/// exists for the same reason: `process.list` shipped on NOW-68K's wire with
/// no console face and nothing failed for a day. The host's version of that
/// failure is a capability that arrives on the MCP surface and is unreachable
/// from the app, which is the half a person actually uses.
///
/// **The declarations are not taken on trust.** A row that claims the app UI
/// reaches it names the file and the affordance; this test reads that file. A
/// row that claims the MCP face is checked against the renderer's own source.
/// A test that believed the rows would be testing one half twice — the
/// mistake AGENTS.md names — so the only thing read from the rows here is the
/// claim, and the evidence comes from the app.
final class HostFaceParityTests: XCTestCase {

    // MARK: - Reading the app's own source

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // repo
    }

    private static let appUIRoot = "now-host/Sources/Host"
    private static let mcpServer =
        "now-host/Sources/NOWAgentIntegration/MCP/NOWMCPServer.swift"
    private static let mcpRenderer =
        "now-host/Sources/NOWAgentIntegration/MCP/NOWMCPToolRenderer.swift"

    /// The app's own source **with its comment lines removed** — see
    /// `GateSource`.
    ///
    /// Every check in this file establishes a structural property by asking
    /// whether an identifier is in a file, and a comment that names the
    /// identifier satisfies that. Found here by mutation on 2026-07-31:
    /// replacing `registry.projections.map` with a filtered map that drops
    /// one capability, and leaving the original in the comment above it,
    /// removed a row from the MCP tool list while
    /// `testTheMCPFaceIsDerivedFromTheRenderersOwnLoop` went on reporting
    /// that every registered row is on the MCP face structurally. It built,
    /// and all 916 tests passed.
    ///
    /// That check is the premise the whole `.reachedByRegistry` claim rests
    /// on, so it is the worst one in the file to be able to satisfy with
    /// prose.
    private func source(_ path: String) throws -> String {
        try GateSource.hostSwift(path)
    }

    /// Every Swift file under the app UI target, which is where an
    /// AppIntents face would first appear.
    private func appUISources() throws -> [URL] {
        let root = Self.repoRoot.appendingPathComponent(Self.appUIRoot)
        let all = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let next = all?.nextObject() as? URL {
            if next.pathExtension == "swift" { files.append(next) }
        }
        return files
    }

    private var rows: [any HostProjection.Type] {
        HostProjectionRegistry.hostFaces.projections
    }

    // MARK: - The divergence ledger

    /// Capabilities the app UI does not reach, and nothing else.
    ///
    /// The reason lives on the row, where the next person to read that
    /// capability will find it; this list is the review checkpoint. Flipping
    /// a row in either direction fails here until someone edits it, which is
    /// the same shape as `CommandParityTests.consoleOnly` — a divergence is
    /// legal, and quietly *becoming* one is not.
    private static let appUIDivergences: Set<String> = [
        "now_session_capabilities",
        "now_transfer_approved_artifact",
        "now_guest_files_capabilities",
        "now_guest_files_upload_begin",
        "now_guest_files_upload_append",
        /* The one-call local-file sibling of the pair above: the app's
           person picks a real file in Files, which enters the same host
           transfer lane, so the row's reason names the picker rather
           than a missing pane. */
        "now_guest_files_upload_file",
        /* The act plane and the observation that mints its targets, all
           registered 2026-07-31. The divergence is the one kind this ledger
           is least worried about and it is still owed: the acts take an
           opaque reference to a window, control or text element, and NOW has
           no pane that shows one. There is nothing for a person to click
           because there is nothing for them to click ON.

           CORRECTED the same day, and worth keeping straight because the
           reason narrowed rather than went away: the note here used to say
           NOW had "no such observation" either. It has one now —
           `now_observe_elements` can fetch the tree — so what is missing is
           only the VIEW that renders it. The affordance for all six lands
           with that view; not waived, and each row's own `.appUI` reason
           says so. */
        "now_observe_elements",
        "now_window_act",
        "now_control_act",
        "now_menu_act",
        "now_text_get",
        "now_text_set",
    ]

    /// Long enough that "later" and "TODO" cannot pass as a justification.
    private static let minimumReasonLength = 80

    // MARK: - Every face is stated

    /// A face missing from a row is the failure this whole gate is for: it
    /// reads as parity nobody checked, and it is invisible. So the model is
    /// closed — three faces, stated by every row, whether or not the face
    /// exists yet.
    func testEveryRowStatesEveryFace() {
        XCTAssertEqual(HostCapabilityFace.allCases.count, 3,
                       "The host has three faces: the app UI, MCP, and "
                           + "AppIntents from W3. A face added to or removed "
                           + "from this model changes what parity means, so "
                           + "it is a deliberate edit here.")
        XCTAssertTrue(HostCapabilityFace.allCases.contains(.appIntents),
                      "AppIntents is modelled before it is built, on "
                          + "purpose — see HostCapabilityFace.")
        for row in rows {
            let name = row.capability.rawValue
            for face in HostCapabilityFace.allCases {
                XCTAssertNotNil(
                    row.faces[face],
                    "\(name) states nothing about the \(face.rawValue) "
                        + "face. Every row states every face: either the "
                        + "evidence that it is reached, or the reason it is "
                        + "not. A face left out of a row is a gap that "
                        + "reads as parity.")
            }
            XCTAssertEqual(
                row.faces.count, HostCapabilityFace.allCases.count,
                "\(name) states \(row.faces.count) faces; there are "
                    + "\(HostCapabilityFace.allCases.count).")
        }
    }

    // MARK: - The app UI, read from the app

    /// Every claimed app-UI affordance exists in the file the row names.
    ///
    /// Delete the button and this fails naming the capability, which is the
    /// property that makes the declaration worth anything.
    func testEveryAppUIReachIsProvenByTheAppsOwnSource() throws {
        for row in rows {
            let name = row.capability.rawValue
            guard case .reached(let file, let symbol) = row.faces[.appUI]
            else { continue }
            let path = "\(Self.appUIRoot)/\(file)"
            guard let text = try? source(path) else {
                XCTFail("\(name) says the app UI reaches it in \(file), "
                        + "and there is no such file at \(path).")
                continue
            }
            XCTAssertTrue(
                text.contains(symbol),
                "\(name) says the app UI reaches it through \"\(symbol)\" "
                    + "in \(file), and that affordance is not there. Either "
                    + "the capability lost its app-UI face — in which case "
                    + "the row declares a divergence with its reason and "
                    + "joins appUIDivergences — or the affordance was "
                    + "renamed and the row follows it.")
        }
    }

    /// `reachedByRegistry` means "the renderer loops the registry, so no row
    /// can be missing". The app UI has no such loop — it is hand-built
    /// SwiftUI modules — so a row cannot claim its app-UI face structurally.
    func testTheAppUIFaceCannotBeClaimedStructurally() {
        for row in rows {
            guard case .reachedByRegistry = row.faces[.appUI] else {
                continue
            }
            XCTFail("\(row.capability.rawValue) claims the app UI reaches "
                    + "it by registry. Nothing in the app loops the "
                    + "registry to build panes; an app-UI claim names the "
                    + "affordance a person clicks, or it is a divergence.")
        }
    }

    // MARK: - MCP, read from the renderer

    /// The MCP face is structural — `NOWMCPServer` maps the registry and
    /// looks a call up in it — so every row is on it and none may claim
    /// otherwise. That is checked against the renderer's source rather than
    /// assumed, because the day someone replaces that loop with a list of
    /// names is the day this test's premise stops holding.
    func testTheMCPFaceIsDerivedFromTheRenderersOwnLoop() throws {
        let renderer = try source(Self.mcpRenderer)
        let server = try source(Self.mcpServer)
        XCTAssertTrue(
            renderer.contains("registry.projections.map"),
            "NOWMCPToolRenderer no longer builds its tool list by mapping the "
                + "registry, so \"every registered row is on the MCP face\" "
                + "is no longer structurally true. Whatever replaced it has "
                + "to be checked per row here.")
        XCTAssertTrue(
            server.contains("registry.projection(named: name)"),
            "NOWMCPServer no longer dispatches a call by looking the name "
                + "up in the registry, so a tool could be listed and not "
                + "callable.")
        for row in rows {
            let name = row.capability.rawValue
            switch row.faces[.mcp] {
            case .reachedByRegistry:
                continue
            case .reached(let file, _):
                XCTFail("\(name) names \(file) as its MCP evidence. The MCP "
                        + "face renders every registry row in one loop; a "
                        + "row that points at a file instead is describing "
                        + "a surface that no longer exists.")
            case .notReached(let reason):
                XCTFail("\(name) declares the MCP face unreached — "
                        + "\(reason) — but NOWMCPServer lists and dispatches "
                        + "every registry row, so it IS reachable there. A "
                        + "row cannot opt out of a structural face; remove "
                        + "it from the catalog if it should not be exposed.")
            case nil:
                continue  // named by testEveryRowStatesEveryFace
            }
        }
    }

    // MARK: - AppIntents: a face declared before it exists

    /// AppIntents is W3. Until its first source file lands, every row
    /// declares it not-yet-reached — and the moment one does, this fails and
    /// makes every row say whether it has an intent.
    ///
    /// That is the opposite of leaving the face out until it exists: an
    /// absent face is the drift this gate is for, so the face is present and
    /// uniformly honest about being empty.
    func testAppIntentsIsUniformlyNotYetReachedUntilThatFaceExists() throws {
        let withIntents = try appUISources().filter { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.contains("import AppIntents")
        }
        guard withIntents.isEmpty else {
            XCTFail("The AppIntents face has landed ("
                    + withIntents.map(\.lastPathComponent).joined(
                        separator: ", ")
                    + "). Every row now states which intent reaches it or "
                    + "why none does, HostFaceReach."
                    + "appIntentsFaceNotBuiltYet goes away, and this check "
                    + "becomes an evidence check like the app UI's.")
            return
        }
        for row in rows {
            let name = row.capability.rawValue
            switch row.faces[.appIntents] {
            case .notReached:
                continue
            case .reached(let file, _):
                XCTFail("\(name) claims an AppIntents face in \(file), and "
                        + "no file in the app imports AppIntents. A face "
                        + "that does not exist cannot reach anything.")
            case .reachedByRegistry:
                XCTFail("\(name) claims AppIntents reaches it by registry, "
                        + "and there is no AppIntents source at all.")
            case nil:
                continue
            }
        }
    }

    // MARK: - A divergence is a decision

    /// The declared app-UI divergences and the ledger agree, exactly.
    ///
    /// Both directions matter. A capability that quietly stops being
    /// reachable from the app is the drift; a capability that gains an
    /// affordance and leaves a stale justification behind is how the reasons
    /// in this file rot into fiction.
    func testTheAppUIDivergenceLedgerMatchesWhatTheRowsDeclare() {
        var declared: Set<String> = []
        for row in rows {
            if case .notReached = row.faces[.appUI] {
                declared.insert(row.capability.rawValue)
            }
        }
        let undeclared = declared.subtracting(Self.appUIDivergences)
        XCTAssertTrue(
            undeclared.isEmpty,
            "Not reachable from the app UI and not in the ledger: "
                + undeclared.sorted().joined(separator: ", ")
                + ". A capability an agent can use and a person cannot is "
                + "half a feature. Give it an affordance, or add it to "
                + "appUIDivergences — which is a review, not a formality.")
        let stale = Self.appUIDivergences.subtracting(declared)
        XCTAssertTrue(
            stale.isEmpty,
            "In the ledger but no longer declaring an app-UI divergence: "
                + stale.sorted().joined(separator: ", ")
                + ". Remove the entry so the ledger keeps meaning "
                + "something.")
    }

    /// Every divergence carries a reason a reviewer can disagree with.
    func testEveryDivergenceCarriesASubstantiveReason() {
        for row in rows {
            let name = row.capability.rawValue
            for face in HostCapabilityFace.allCases {
                guard case .notReached(let reason) = row.faces[face] else {
                    continue
                }
                let trimmed = reason.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                XCTAssertFalse(
                    trimmed.isEmpty,
                    "\(name) declares the \(face.rawValue) face unreached "
                        + "with no reason. The reason is the whole "
                        + "difference between a decision and a gap.")
                XCTAssertGreaterThanOrEqual(
                    trimmed.count, Self.minimumReasonLength,
                    "\(name)'s \(face.rawValue) divergence is justified in "
                        + "\(trimmed.count) characters: \"\(trimmed)\". Say "
                        + "what a caller on that face reaches instead, or "
                        + "why the capability is meaningless there.")
                for placeholder in ["TODO", "FIXME", "for now", "not yet "
                                        + "implemented"] {
                    XCTAssertFalse(
                        trimmed.lowercased().contains(
                            placeholder.lowercased()),
                        "\(name)'s \(face.rawValue) divergence says "
                            + "\"\(placeholder)\", which is a to-do wearing "
                            + "a justification's clothes. A gap belongs in "
                            + "docs/open-issues.md.")
                }
            }
        }
    }
}
