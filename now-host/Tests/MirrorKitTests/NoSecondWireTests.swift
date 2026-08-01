import Foundation
import XCTest
@testable import MirrorKit

/// **MirrorKit does not talk to machines, and this is the gate that says so.**
///
/// It replaces `DispatchedVerbNameTests`, which was written the day someone
/// noticed `ActionDispatcher` sending `menuinvoke` with `menuID` — a verb no
/// NOW guest answers, with an argument no NOW verb takes, green in every
/// suite in the repository. That test fixed the spelling and named the real
/// problem in its own header without being able to fix it: *"MirrorKit does
/// not speak NOW's contract at all"*. `WireClient` sent
/// `{"proto":1,"id":n,"verb":…}` and read a `result` object — the TimBotTu
/// toolkit worker's protocol — while a NOW guest speaks `command.request` and
/// answers `output`. Every verb in that file's table was correctly spelled for
/// a machine that is not on the other end of a NOW connection.
///
/// So the successor is not a better table. A table of verbs is only worth
/// checking if this module sends verbs, and the fix was that it must not: NOW
/// owns the one wire, a scene arrives through `GuestListener.requestScene` and
/// `MirrorSceneAdapter`, and this module is the renderer and the model it was
/// ported to be. What is checked here is therefore the property, not the
/// spelling — **no transport, at all, in either module** — plus the one thing
/// that survived the deletion: the command names `ActionModel.availability`
/// puts in a person's hands, checked against the contract's own registry.
final class NoSecondWireTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // -> MirrorKitTests
            .deletingLastPathComponent()   // -> Tests
            .deletingLastPathComponent()   // -> now-host
            .deletingLastPathComponent()   // -> now
    }

    private static var sourceRoots: [URL] {
        ["Sources/MirrorKit", "Sources/MirrorKitUI"].map {
            repoRoot.appendingPathComponent("now-host").appendingPathComponent($0)
        }
    }

    private static var contractPath: URL {
        repoRoot.appendingPathComponent("contract/asyncapi.yaml")
    }

    private func sources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for root in Self.sourceRoots {
            let names = (FileManager.default.enumerator(atPath: root.path)?
                .compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".swift") }
            for name in names {
                out.append((root.lastPathComponent + "/" + name,
                            try String(contentsOf:
                                root.appendingPathComponent(name),
                                encoding: .utf8)))
            }
        }
        XCTAssertGreaterThan(out.count, 10, "found almost no sources — the "
                            + "scan below would pass by finding nothing")
        return out
    }

    // MARK: - The property

    /// No socket, no session, no connection, in any form.
    ///
    /// The list is BSD sockets (what `WireClient` and `QmpClient` used),
    /// Foundation's and Network's clients (what a well-meaning replacement
    /// would reach for), and Process (a shell-out is a transport too). Each
    /// pattern is matched as a call or a type reference, so prose in a header
    /// explaining why the transport is gone does not trip it — the headers in
    /// this module say `WireClient` and `QmpClient` by name on purpose, and
    /// deleting that history to satisfy a regex would be the wrong trade.
    func testNeitherModuleContainsATransport() throws {
        let banned = [
            "socket(", "connect(", "getaddrinfo(", "recv(", "sockaddr",
            "URLSession", "NWConnection", "NWEndpoint", "CFSocket",
            "Process(", "FileHandle(forReadingAtPath",
        ]
        for (name, text) in try sources() {
            for pattern in banned {
                XCTAssertFalse(text.contains(pattern), """
                    \(name) contains "\(pattern)". MirrorKit and MirrorKitUI \
                    render and model a scene; NOW owns the wire a scene \
                    arrives on, and a second one here is the defect the \
                    fold-in's stop condition exists to prevent. If a scene \
                    needs to be fetched, that is GuestListener's to do.
                    """)
            }
        }
    }

    /// The types that carried the old transport are gone rather than quiet.
    ///
    /// A dormant `WireClient` with no caller would pass the scan above only
    /// until someone found it and wired it up — which is exactly how it got
    /// here, since it crossed with no caller in NOW and was still the thing
    /// this module would have used.
    func testTheTransportTypesAreDeletedAndNotMerelyUnused() throws {
        let gone = ["WireClient.swift", "QmpClient.swift", "MirrorTarget.swift",
                    "ActionDispatcher.swift", "ScenePoller.swift",
                    "LiveMirror.swift"]
        for name in gone {
            for root in Self.sourceRoots {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(name).path),
                    """
                    \(name) is back in \(root.lastPathComponent). It was \
                    deleted rather than adapted: it spoke the toolkit \
                    worker's protocol or drove the emulator's mouse, and \
                    both are ways to reach a machine that are not NOW's.
                    """)
            }
        }
    }

    /// Nothing declares a wire envelope by hand either.
    ///
    /// `{"proto":1,"id":…,"verb":…}` is the toolkit worker's shape and the
    /// one a transliteration would recreate first. A module with no socket
    /// that still builds those dictionaries is a module one commit from
    /// having a socket again.
    ///
    /// `"verb":` is matched with its colon — as a key being *written*.
    /// `DisplayOp` reads `dict["verb"]`, which is QuickDraw's `GrafVerb`
    /// (frame/paint/erase/invert/fill) out of a display op and has nothing to
    /// do with a request; a bare `"verb"` would flag it and teach the next
    /// person that this gate cries wolf.
    func testNothingBuildsAWireEnvelope() throws {
        for (name, text) in try sources() {
            for key in ["\"proto\"", "\"verb\":", "wire.request("] {
                XCTAssertFalse(text.contains(key), """
                    \(name) builds a request envelope (\(key)). NOW's \
                    families are declared in the contract and encoded by the \
                    host; a hand-built envelope here would be a second \
                    protocol whatever it was sent over.
                    """)
            }
        }
    }

    // MARK: - What survived: the command names

    /// Every case of `MirrorAction`, so the table below is a decision per act
    /// rather than a sample.
    ///
    /// Not derived from the type — a case with associated values cannot be
    /// enumerated — so a case added to `MirrorAction` must be added here too.
    /// The compiler already forces a decision in `ActionModel.availability`;
    /// this forces the decision to be *checked*.
    private static let everyAction: [MirrorAction] = [
        .axdo(ref: "ax2:1"),
        .axdo(ref: "ax2:1", count: 1, mods: 0, text: "typed"),
        .key(code: 0, char: 97, mods: 256),
        .type(text: "hi"),
        .activate(psn: "1.2"),
        .click(x: 5, y: 5),
        .drag(x0: 0, y0: 0, x1: 4, y1: 4),
        .qmpClick(x: 5, y: 5),
        .qmpDoubleClick(x: 5, y: 5),
        .menuInvoke(menuID: 130, itemIndex: 2, titleLeft: 38),
        .thumbDrag(x0: 0, y0: 0, x1: 0, y1: 40),
    ]

    /// Every command name this module names is one the contract declares,
    /// spelled exactly as it declares it.
    ///
    /// **This is the assertion `menuinvoke` would have failed**, and it now
    /// covers the names in `ActionAvailability` rather than the arguments of
    /// a call site, because there are no call sites left. It reads the
    /// contract rather than a copy of it, so a command renamed there fails
    /// here instead of failing on a Macintosh.
    func testEveryCommandNameThisModuleOffersIsDeclaredByTheContract() throws {
        let declared = try Self.declaredCommands()
        XCTAssertFalse(declared.isEmpty, "could not read x-commands")

        var named: Set<String> = []
        for action in Self.everyAction {
            switch ActionModel.availability(action) {
            case .available(let command):
                named.insert(command)
            case .needsObservation(let command, let reason):
                named.insert(command)
                XCTAssertFalse(reason.isEmpty, "\(command) refuses silently")
            case .unavailable(let reason):
                XCTAssertFalse(reason.isEmpty, """
                    \(action) is refused with no reason. An act that cannot \
                    be sent has to say why, or a person clicks and nothing \
                    happens and the page reads as broken.
                    """)
            }
        }
        XCTAssertFalse(named.isEmpty, "no act names a command at all")

        for command in named {
            XCTAssertTrue(declared.contains(command), """
                MirrorKit offers "\(command)" as the command that carries an \
                act, and contract/asyncapi.yaml's x-commands does not \
                declare it. That is a request no NOW guest will answer — \
                which is exactly what shipped as `menuinvoke`.
                """)
        }
    }

    /// The acts that reach a machine, if any ever do, are the ones a scene
    /// can address — and today that is two.
    ///
    /// Asserted as a set rather than one by one so that *widening* it is a
    /// deliberate act. An act promoted to `.available` because a guest grew a
    /// plane is good news; an act promoted because someone defaulted a
    /// missing reference to `""` is the failure this file is about.
    func testOnlyTheActsAScenecanAddressAreAvailable() {
        var available: Set<String> = []
        for action in Self.everyAction {
            if case .available(let command)
                = ActionModel.availability(action) {
                available.insert(command)
            }
        }
        XCTAssertEqual(available, ["menuact", "activate"], """
            The set of acts sendable straight off a rendered scene changed. \
            Both of these are addressable because a scene carries their whole \
            target — a menu's id, item and title x; a process serial. \
            Anything addressed by an element reference cannot join them until \
            a scene carries one.
            """)
    }

    /// Read `x-commands` out of the contract: the top-level keys under it.
    private static func declaredCommands() throws -> Set<String> {
        let contract = try String(contentsOf: contractPath, encoding: .utf8)
        guard let start = contract.range(of: "\n  x-commands:\n") else {
            return []
        }
        var declared: Set<String> = []
        for line in contract[start.upperBound...].components(
            separatedBy: "\n") {
            if line.hasPrefix("  "), !line.hasPrefix("   "),
               line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                break
            }
            guard line.hasPrefix("    "), !line.hasPrefix("     ") else {
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix(":"), !t.contains(" "),
                  !t.hasPrefix("x-") else { continue }
            declared.insert(String(t.dropLast()))
        }
        return declared
    }
}
