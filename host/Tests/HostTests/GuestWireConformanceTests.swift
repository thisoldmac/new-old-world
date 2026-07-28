import Foundation
import XCTest
@testable import Host

/// Every control message the guest can emit, read out of the guest's own
/// source and put through the host's decoder and the contract's required
/// fields.
///
/// The hand-written fixtures next door prove the frames someone thought
/// to write down. This proves the ones nobody did. It exists because
/// three frames shipped missing contract-required fields — the host
/// could not decode them, dropped the connection, and the visible
/// symptom pointed nowhere near the cause.
///
/// It reads C source, which is unusual for a Swift test and is the
/// point: the two halves are built by different toolchains and only
/// meet on the wire, so something has to look at both.
final class GuestWireConformanceTests: XCTestCase {

    // MARK: - Locating the other half

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/host/Tests/HostTests/x
            .deletingLastPathComponent()          // …/host/Tests/HostTests
            .deletingLastPathComponent()          // …/host/Tests
            .deletingLastPathComponent()          // …/host
            .deletingLastPathComponent()          // …/
    }

    /// Both guests, not one. `guest/src` is the PowerPC Carbon client;
    /// `guest68k/src` is the 68K MacTCP client for the PowerBook 180c.
    /// They are separate applications built by separate toolchains that
    /// meet the host only on the wire, so a check that reads just one of
    /// them lets the other drift — which is the same "two halves never met
    /// in a test" failure this file exists to prevent, one half further on.
    ///
    /// `guest68k/src` is optional: branches that predate it must still run
    /// these tests. A missing directory is skipped, an empty one is not —
    /// silently checking nothing is the outcome worth failing on.
    private func guestSources() throws -> [(name: String, text: String)] {
        var out: [(name: String, text: String)] = []

        for half in ["guest/src", "guest68k/src"] {
            let dir = Self.repoRoot.appendingPathComponent(half)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }
            let names = try FileManager.default
                .contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".c") }.sorted()
            XCTAssertFalse(names.isEmpty, "no guest sources at \(dir.path)")
            // Names carry their half so a failure says which client is wrong.
            for n in names {
                out.append(("\(half)/\(n)",
                            try String(contentsOf: dir.appendingPathComponent(n),
                                       encoding: .utf8)))
            }
        }

        XCTAssertFalse(out.isEmpty, "no guest sources under \(Self.repoRoot.path)")
        return out
    }

    // MARK: - Reading templates out of C

    /// C string literals that sit next to each other are one literal.
    /// That is how every message in wire.c is written, so gathering them
    /// is how a whole message is recovered.
    private func adjacentLiterals(in source: String) -> [String] {
        var out: [String] = []
        var current: String?
        var chars = Array(source)
        var i = 0

        while i < chars.count {
            // Skip // and /* */ comments, which contain quotes.
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count,
                      !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            // A C CHARACTER literal, which may itself be a quote: '"'.
            // Without this the lone quote in `c == '"'` opens a string
            // the scanner then closes on the next real literal's opening
            // quote, and every literal after it is read inside-out until
            // another stray quote happens to restore the parity.
            //
            // That was not hypothetical. guest68k/src/wire68.c had three
            // such literals in one helper, and they hid `bye` — a
            // genuinely piecemeal message — from this file's own
            // cannot-check set for as long as the helper existed. The
            // set looked complete and was not, which is precisely the
            // failure testMessagesThisCannotCheckAreKnown exists to
            // prevent, committed inside the mechanism meant to prevent it.
            if chars[i] == "'" {
                i += 1
                while i < chars.count, chars[i] != "'" {
                    i += (chars[i] == "\\") ? 2 : 1
                }
                i += 1
                // A character literal is not whitespace, so it ends a run
                // of adjacent string literals exactly like any other token.
                if current != nil {
                    out.append(current!)
                    current = nil
                }
                continue
            }
            guard chars[i] == "\"" else {
                if !chars[i].isWhitespace, current != nil {
                    out.append(current!)          // the run ended
                    current = nil
                }
                i += 1
                continue
            }
            // A literal: read it, undoing C escapes.
            var literal = ""
            i += 1
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    switch chars[i + 1] {
                    case "\"": literal.append("\"")
                    case "\\": literal.append("\\")
                    case "n": literal.append("\n")
                    case "r": literal.append("\r")
                    case "t": literal.append("\t")
                    default: literal.append(chars[i + 1])
                    }
                    i += 2
                } else {
                    literal.append(chars[i])
                    i += 1
                }
            }
            i += 1
            current = (current ?? "") + literal
        }
        if let last = current { out.append(last) }
        return out
    }

    /// Turns a printf template into one concrete message.
    ///
    /// A conversion inside quotes stands for text. Outside them, %s is
    /// either a value (it follows a ":") or an optional JSON FRAGMENT
    /// spliced onto what came before — capture.begin ends with one, and
    /// the honest instance of an optional fragment is nothing at all.
    private func instantiate(_ template: String) -> String {
        var out = ""
        let chars = Array(template)
        var i = 0
        var inString = false

        while i < chars.count {
            if chars[i] == "\"" { inString.toggle() }
            guard chars[i] == "%" else {
                out.append(chars[i]); i += 1; continue
            }
            var j = i + 1
            while j < chars.count,
                  "0123456789.-+ #hlLqjzt".contains(chars[j]) { j += 1 }
            guard j < chars.count else { break }
            switch chars[j] {
            case "s":
                if inString { out += "X" }
                else { out += out.last == ":" ? "true" : "" }
            case "f", "g": out += "1.5"
            case "%": out += "%"
            default: out += "1"
            }
            i = j + 1
        }
        return out
    }

    /// Whole JSON objects only. A message assembled across several
    /// snprintf calls (the paginated listing) cannot be recovered this
    /// way; those are reported, never quietly skipped.
    private func messageTemplates(in source: String) -> (whole: [String],
                                                         partial: [String]) {
        var whole: [String] = [], partial: [String] = []
        for literal in adjacentLiterals(in: source)
        where literal.hasPrefix("{\"type\":\"") {
            if literal.hasSuffix("}") { whole.append(literal) }
            else { partial.append(literal) }
        }
        return (whole, partial)
    }

    // MARK: - What the contract demands

    /// The `required:` list for each schema in the contract. A tiny
    /// scanner rather than a YAML dependency: it reads the two shapes
    /// the file actually uses and fails loudly if it finds neither.
    private func requiredFields() throws -> [String: Set<String>] {
        let url = Self.repoRoot
            .appendingPathComponent("contract/asyncapi.yaml")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: Set<String>] = [:]
        var schema: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "    FileOffer:" — a schema name at exactly 4 spaces.
            if line.hasPrefix("    ") && !line.hasPrefix("     "),
               trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                schema = String(trimmed.dropLast())
                continue
            }
            // Only the schema's OWN required list: a nested object
            // (command.result's `error`) has one too, and reading it as
            // the message's demanded fields the message does not have.
            guard let name = schema, out[name] == nil,
                  line.hasPrefix("      required: ["),
                  !line.hasPrefix("       ") else {
                continue
            }
            let body = trimmed.drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
            out[name] = Set(body.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        XCTAssertFalse(out.isEmpty, "could not read the contract's schemas")
        return out
    }

    /// Contract schema names are the message type in PascalCase:
    /// file.offer -> FileOffer.
    private func schemaName(forType type: String) -> String {
        type.components(separatedBy: CharacterSet(charactersIn: "."))
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    // MARK: - The tests

    /// Every whole message the guest can send decodes on this side.
    func testEveryGuestMessageDecodes() throws {
        var checked = 0
        for (file, text) in try guestSources() {
            for template in messageTemplates(in: text).whole {
                let json = instantiate(template)
                checked += 1
                do {
                    _ = try ControlMessageCodec.decode(Data(json.utf8))
                } catch ControlMessageError.unknownType(let type) {
                    // A guest-only verb the host never receives is fine;
                    // one the host DOES receive is caught below.
                    XCTAssertFalse(type.hasPrefix("file."),
                                   "\(file): the host cannot decode \(type)")
                } catch {
                    XCTFail("""
                        \(file): the host cannot decode a message the guest \
                        sends: \(error)
                        \(json)
                        """)
                }
            }
        }
        XCTAssertGreaterThan(checked, 10,
                             "found suspiciously few messages to check")
    }

    /// Every whole message carries the fields the contract requires.
    /// This is the check that was missing: `file.offer` shipped without
    /// `path` for a day, and nothing anywhere said so.
    func testEveryGuestMessageCarriesItsRequiredFields() throws {
        let required = try requiredFields()
        for (file, text) in try guestSources() {
            for template in messageTemplates(in: text).whole {
                let json = instantiate(template)
                guard let object = try JSONSerialization.jsonObject(
                    with: Data(json.utf8)) as? [String: Any],
                      let type = object["type"] as? String else {
                    XCTFail("\(file): not a JSON object: \(json)")
                    continue
                }
                guard let want = required[schemaName(forType: type)] else {
                    continue          // not a schema this contract names
                }
                let have = Set(object.keys)
                XCTAssertTrue(want.isSubset(of: have), """
                    \(file): \(type) is missing \
                    \(want.subtracting(have).sorted().joined(separator: ", ")) \
                    — the receiver will not be able to decode it
                    """)
            }
        }
    }

    /// The inbound side of the same seam. These keys name a file the
    /// guest will open, never a protocol token: the host sends them
    /// UTF-8 and FSMakeFSSpec wants the MacRoman byte, so they must be
    /// pulled with `now_json_find_text` (which decodes) and never
    /// `now_json_find_string` (which does not). The choice is only
    /// visible in the C, which is why this reads the source — a "café®"
    /// left as raw UTF-8 resolves to a file that does not exist, and
    /// nothing on the wire says so. Regressing any one call fails here.
    func testHfsPathArgumentsAreTextDecoded() throws {
        let pathKeys = ["path", "toPath", "trashedAs"]
        var checked = 0
        for (file, text) in try guestSources() {
            for key in pathKeys {
                // now_json_find_string( <args, no ';'> "<key>"  — the
                // negated class stops at the statement's semicolon, so a
                // find_string for some OTHER key cannot reach this one.
                let pattern = "now_json_find_string\\([^;]*\"\(key)\""
                let re = try NSRegularExpression(pattern: pattern)
                let hits = re.numberOfMatches(
                    in: text, range: NSRange(text.startIndex..., in: text))
                XCTAssertEqual(hits, 0, """
                    \(file): "\(key)" is an HFS name fed to the File \
                    Manager but is read with now_json_find_string, which \
                    leaves the host's UTF-8 undecoded — use \
                    now_json_find_text so a non-ASCII name resolves.
                    """)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no guest sources scanned")
    }

    /// The guest must not advertise disk reservation after merely asking
    /// SetEOF to reserve it. Classic File Manager failures are ordinary
    /// return values; ignoring one turns a full disk into a late, misleading
    /// transfer failure.
    func testGuestChecksDiskReservationBeforeAcceptingUpload()
        throws {
        let fileshare = try XCTUnwrap(
            try guestSources().first { $0.name.hasSuffix("/fileshare.c") }?.text)
        XCTAssertTrue(fileshare.contains(
            "err = SetEOF(rx->data_ref, bytes);"))
        XCTAssertTrue(fileshare.contains(
            "return err == dskFulErr ? kFilesTooBig : kFilesIOError;"))
        XCTAssertTrue(fileshare.contains(
            "rx->reserved_bytes = need;"))
    }

    /// Messages built up across several calls cannot be checked this
    /// way. Naming them keeps the gap visible instead of letting a green
    /// suite imply coverage it does not have.
    ///
    /// Each one maps to the fixture test that stands in for it, or to nil
    /// where nothing does. Both halves of that matter: a new piecemeal
    /// message fails the set comparison until someone lists it, and listing
    /// it with a fixture name fails the second check until that fixture
    /// actually exists. A `nil` is an honest, still-open gap — leave it.
    ///
    /// hello, ping and error are here from guest68k/src, which assembles
    /// every message through numfmt appends because the 68K build has no
    /// printf family (its float tail costs ~42 KB of a 384 KB partition).
    private static let piecemealCoverage: [String: String?] = [
        "file.listing": "testFileListingAsTheGuestWritesIt",
        "file.result": "testFileResultAsTheGuestWritesIt",
        "census.report": "testCensusReportAsTheGuestWritesIt",
        "process.listing": "testProcessListingAsTheGuestWritesIt",
        "software.listing": "testSoftwareListingAsTheGuestWritesIt",
        "command.result": nil,
        "hello": "test68KHelloAsTheGuestWritesIt",
        "ping": "test68KPingAsTheGuestWritesIt",
        "error": "test68KErrorReplyAsTheGuestWritesIt",
        "bye": "test68KByeAsTheGuestWritesIt",
        "process.result": "test68KProcessResultAsTheGuestWritesIt",
        "file.accept": "test68KFileAcceptAsTheGuestWritesIt",
        "file.refuse": "test68KFileRefuseAsTheGuestWritesIt",
        "file.progress": "test68KFileProgressAsTheGuestWritesIt",
        "file.done": "test68KFileDoneAsTheGuestWritesIt",
        // NOW-68K's send half (n68_puttx.c). Assembled from append calls
        // rather than one format string, like everything else this guest
        // builds, so they need the hand-written fixtures below.
        "file.offer": "test68KFileOfferAsTheGuestWritesIt",
        "file.begin": "test68KFileBeginAsTheGuestWritesIt",
        "file.end": "test68KFileEndAsTheGuestWritesIt",
        // NOW-68K's capture envelopes (n68_shotwire.c). Same reason as the
        // send half above: built from append calls, so the scanner cannot
        // read them and a hand-written fixture is the only check there is.
        "capture.begin": "test68KCaptureBeginAsTheGuestWritesIt",
        "capture.end": "test68KCaptureEndAsTheGuestWritesIt",
        // The exec plane (wire68.c). Built from appends like everything
        // else this guest sends, and worth pinning for a reason the others
        // are not: exec.output is the only message whose payload is
        // arbitrary human-facing TEXT, so its escaping is the one place a
        // guest's own console output can corrupt the wire.
        "exec.output": "test68KExecOutputAsTheGuestWritesIt",
        "exec.result": "test68KExecResultAsTheGuestWritesIt",
    ]

    func testMessagesThisCannotCheckAreKnown() throws {
        var found: Set<String> = []
        for (_, text) in try guestSources() {
            for template in messageTemplates(in: text).partial {
                let type = template
                    .dropFirst("{\"type\":\"".count).prefix { $0 != "\"" }
                found.insert(String(type))
            }
        }
        XCTAssertEqual(found, Set(Self.piecemealCoverage.keys), """
            The set of messages assembled piecemeal changed. Those are \
            NOT covered by the conformance checks above — either give the \
            new one a hand-written fixture in GuestWireFixtureTests and \
            name it in piecemealCoverage, or build it in one call so it \
            can be checked here.
            """)
    }

    /// A fixture name in the table above has to name a test that exists.
    /// Without this, the table degrades into a list of good intentions the
    /// moment someone renames or deletes a fixture, and the cannot-check
    /// set would go on claiming coverage that is gone.
    func testNamedFixturesForPiecemealMessagesExist() throws {
        let url = Self.repoRoot
            .appendingPathComponent("host/Tests/HostTests")
            .appendingPathComponent("GuestWireFixtureTests.swift")
        let text = try String(contentsOf: url, encoding: .utf8)

        for (type, fixture) in Self.piecemealCoverage {
            guard let fixture else { continue }
            XCTAssertTrue(text.contains("func \(fixture)("), """
                \(type) is recorded as covered by \(fixture), but \
                GuestWireFixtureTests has no such test — either restore it \
                or set the entry back to nil so the gap is visible again.
                """)
        }
    }

    /// The 68K guest's piecemeal frames, put through the same contract
    /// required-field check the whole-message scan gives everything else.
    /// Decoding is proved next door; this is the other half — a frame the
    /// host happens to decode can still be missing a field the contract
    /// demands, which is the exact defect this file was written for.
    func test68KFixturesCarryTheirRequiredFields() throws {
        let required = try requiredFields()
        for json in Guest68KWire.all {
            guard let object = try JSONSerialization.jsonObject(
                with: Data(json.utf8)) as? [String: Any],
                  let type = object["type"] as? String else {
                XCTFail("not a JSON object: \(json)")
                continue
            }
            let want = try XCTUnwrap(required[schemaName(forType: type)],
                                     "the contract does not name \(type)")
            let have = Set(object.keys)
            XCTAssertTrue(want.isSubset(of: have), """
                guest68k: \(type) is missing \
                \(want.subtracting(have).sorted().joined(separator: ", ")) \
                — the host will not be able to decode it
                """)
            // additionalProperties is false on all three schemas, so a
            // field the contract does not name is as fatal as a missing
            // one, and the 68K writer emits fixed literals: a stray key
            // there would ship silently.
            let known = try contractProperties(
                of: schemaName(forType: type))
            XCTAssertTrue(have.isSubset(of: known), """
                guest68k: \(type) carries \
                \(have.subtracting(known).sorted().joined(separator: ", ")) \
                — not named by the contract schema
                """)
        }
    }

    /// The property names a schema declares, read the same shallow way
    /// `requiredFields()` reads its required list.
    private func contractProperties(of schema: String) throws -> Set<String> {
        let url = Self.repoRoot
            .appendingPathComponent("contract/asyncapi.yaml")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: Set<String> = []
        var inSchema = false, inProperties = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    ") && !line.hasPrefix("     "),
               trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                if inSchema { break }              // the next schema begins
                inSchema = String(trimmed.dropLast()) == schema
                continue
            }
            guard inSchema else { continue }
            if line.hasPrefix("      properties:") { inProperties = true; continue }
            // A property name sits at exactly 8 spaces under properties:.
            guard inProperties, line.hasPrefix("        "),
                  !line.hasPrefix("         ") else { continue }
            out.insert(String(trimmed.prefix { $0 != ":" }))
        }
        XCTAssertFalse(out.isEmpty, "no properties read for \(schema)")
        return out
    }
}
