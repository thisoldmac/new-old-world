import Foundation
import XCTest
@testable import MirrorKit

/// Every verb name MirrorKit puts on a wire, named and classified.
///
/// **Written because one of them was wrong on `main` for as long as the code
/// had been here.** `ActionDispatcher` sent `menuinvoke` with `menuID`; NOW's
/// contract declares `menuact` with `menu`. That is a request no NOW guest
/// answers, in ported code, with every test in the repository green — because
/// nothing anywhere compared the strings this module sends against the strings
/// anything serves. The probes under `scripts/probes/` had already been
/// reconciled to the contract's spelling on 2026-07-31 ("a spelling is not a
/// capability", `scripts/probes/README.md`); this module had not, and the two
/// halves of one fold-in disagreed for a day.
///
/// The check is a NAMED LIST rather than a scan of the contract, and the
/// reason is the second thing this file has to say out loud: **MirrorKit does
/// not speak NOW's contract at all.** `WireClient` sends
/// `{"proto":1,"id":n,"verb":…}` and reads a `result` object — the TimBotTu
/// toolkit worker's protocol — while a NOW guest speaks `command.request` and
/// answers `output`. `MirrorTarget`'s own documentation says so: "it assumes
/// AXPeek + a toolkit worker are already live at host:port". So most of these
/// names are not contract verbs and correctly are not, and a gate that
/// demanded they all be would be wrong in the loud direction.
///
/// What this list buys is that the classification is written down beside the
/// name. A verb added or renamed here costs one line and a decision about
/// which wire it is for — which is exactly the decision nobody made for
/// `menuinvoke`.
final class DispatchedVerbNameTests: XCTestCase {

    private static var moduleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // -> MirrorKitTests
            .deletingLastPathComponent()   // -> Tests
            .deletingLastPathComponent()   // -> now-host
            .appendingPathComponent("Sources/MirrorKit")
    }

    private static var contractPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contract/asyncapi.yaml")
    }

    /// Verb -> which wire it is for.
    ///
    /// `contract` means NOW declares it in `x-commands` and this module must
    /// spell it exactly as declared. `toolkit` means it is a TimBotTu worker
    /// verb with no NOW declaration, which is legal here and is the thing to
    /// notice when someone asks why a NOW guest does not answer this module.
    private static let sent: [String: String] = [
        "menuact": "contract",
        "mouseloc": "contract",
        "activate": "contract",
        "observe": "contract",
        "axtree": "contract",
        "qdtrace": "contract",
        "script": "contract",
        "axdo": "toolkit",
        "key": "toolkit",
        "type": "toolkit",
        "click": "toolkit",
        "video": "toolkit",
        "volumes": "toolkit",
        "list": "toolkit",
    ]

    private func sources() throws -> [(String, String)] {
        let names = (FileManager.default.enumerator(
            atPath: Self.moduleRoot.path)?
            .compactMap { $0 as? String } ?? [])
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "no MirrorKit sources found")
        return try names.map {
            ($0, try String(contentsOf: Self.moduleRoot
                .appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// Every `wire.request("…")` in the module is a name this file classifies.
    func testEveryVerbThisModuleSendsIsOneThisFileNames() throws {
        var found: Set<String> = []
        let re = try NSRegularExpression(
            pattern: #"wire\.request\(\s*"([a-zA-Z_.]+)""#)
        for (_, text) in try sources() {
            let ns = text as NSString
            for m in re.matches(
                in: text, range: NSRange(location: 0, length: ns.length)) {
                found.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        XCTAssertFalse(found.isEmpty, "found no dispatched verbs at all")
        XCTAssertEqual(found, Set(Self.sent.keys), """
            The set of verbs MirrorKit sends changed. Each one is either a \
            NOW contract verb — spelled exactly as x-commands declares it — \
            or a TimBotTu toolkit worker verb, and the difference decides \
            whether a NOW guest can answer it at all. Add it above with \
            which wire it is for.
            """)
    }

    /// The ones classified as contract verbs really are declared, under
    /// exactly that spelling.
    ///
    /// This is the assertion `menuinvoke` would have failed. It reads the
    /// contract rather than a copy of it, so a verb renamed there fails here
    /// instead of failing on a Macintosh.
    func testTheContractVerbsAreSpelledAsTheContractDeclaresThem() throws {
        let contract = try String(contentsOf: Self.contractPath,
                                  encoding: .utf8)
        guard let start = contract.range(of: "\n  x-commands:\n") else {
            return XCTFail("no x-commands registry in the contract")
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
            guard t.hasSuffix(":"), !t.contains(" "), !t.hasPrefix("x-") else {
                continue
            }
            declared.insert(String(t.dropLast()))
        }
        XCTAssertFalse(declared.isEmpty, "could not read the registry")

        for (verb, wire) in Self.sent where wire == "contract" {
            XCTAssertTrue(declared.contains(verb), """
                MirrorKit sends "\(verb)" and calls it a NOW contract verb, \
                and the contract's x-commands does not declare it. That is \
                a request no NOW guest will answer — which is exactly what \
                shipped as `menuinvoke`, and what this test exists for. \
                Either fix the spelling or reclassify it as a toolkit verb.
                """)
        }
        for (verb, wire) in Self.sent where wire == "toolkit" {
            XCTAssertFalse(declared.contains(verb), """
                "\(verb)" is classified here as a toolkit-only verb and the \
                NOW contract now declares it. That is good news and it \
                changes what this module is doing — move it to `contract` \
                so its spelling is checked against the declaration.
                """)
        }
    }

    /// The argument names of the one verb that has already been wrong.
    ///
    /// A verb name that matches with argument names that do not is the same
    /// failure one layer down, and it is quieter: `unknown-command` is loud,
    /// a missing required argument is a refusal that reads like a guest
    /// problem. `menu`, not `menuID`.
    func testMenuactSendsTheContractsArgumentNames() throws {
        let dispatcher = try String(
            contentsOf: Self.moduleRoot
                .appendingPathComponent("ActionDispatcher.swift"),
            encoding: .utf8)
        guard let call = dispatcher.range(of: #"wire.request("menuact""#) else {
            return XCTFail("ActionDispatcher no longer sends menuact")
        }
        let args = String(dispatcher[call.upperBound...].prefix(200))
        for name in ["\"menu\"", "\"item\"", "\"titleLeft\""] {
            XCTAssertTrue(args.contains(name), """
                menuact is sent without \(name), which the contract declares \
                as required. titleLeft in particular is not derivable — it \
                is the act's identity check, and without it the guest cannot \
                tell this press from the one the person at the machine made.
                """)
        }
        XCTAssertFalse(args.contains("\"menuID\""), """
            menuact is still sent with the KEY "menuID", which is \
            upstream's argument name and not the contract's. The verb name \
            and its arguments crossed together and must be reconciled \
            together. (The local Swift binding may still be called menuID; \
            what travels is the dictionary key, and that is what is \
            checked.)
            """)
    }
}
