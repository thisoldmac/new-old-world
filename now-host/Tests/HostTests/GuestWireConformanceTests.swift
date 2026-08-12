import Foundation
import XCTest
@testable import Host
import NOWAgentIntegration

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
        URL(fileURLWithPath: #filePath)          // …/now-host/Tests/HostTests/x
            .deletingLastPathComponent()          // …/now-host/Tests/HostTests
            .deletingLastPathComponent()          // …/now-host/Tests
            .deletingLastPathComponent()          // …/now-host
            .deletingLastPathComponent()          // …/
    }

    /// Both guests, not one. `now-guest-ppc/src` is the PowerPC Carbon client;
    /// `now-guest-68k/src` is the 68K MacTCP client for the PowerBook 180c.
    /// They are separate applications built by separate toolchains that
    /// meet the host only on the wire, so a check that reads just one of
    /// them lets the other drift — which is the same "two halves never met
    /// in a test" failure this file exists to prevent, one half further on.
    ///
    /// `now-guest-68k/src` is optional: branches that predate it must still run
    /// these tests. A missing directory is skipped, an empty one is not —
    /// silently checking nothing is the outcome worth failing on.
    ///
    /// The walk RECURSES, because the sources live in domain directories
    /// (`core/`, `commands/`, `files/`, …) rather than flat under `src/`.
    /// The not-empty assertion below does NOT catch a shallow walk — it
    /// still finds `main.c` and is satisfied. What catches it is the rest
    /// of the file: reverting this to `contentsOfDirectory` was tried, and
    /// three tests fail, because the message inventory and the
    /// cannot-check set both go looking for frames that live in `core/`.
    /// So the guard here is real but indirect; if this ever becomes the
    /// only reader of these files, give it a floor on the count.
    private func guestSources() throws -> [(name: String, text: String)] {
        var out: [(name: String, text: String)] = []

        for half in ["now-guest-ppc/src", "now-guest-68k/src"] {
            let dir = Self.repoRoot.appendingPathComponent(half)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path,
                                                 isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }
            let names = (FileManager.default
                .enumerator(atPath: dir.path)?
                .compactMap { $0 as? String } ?? [])
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

    /// The same sources **with their comments removed** — see `GateSource`.
    ///
    /// `guestSources()` above stays RAW on purpose: the literal scanner below
    /// does its own comment skipping, and it needs the raw text to get the
    /// character-literal parity right (the `'"'` case, whose absence once hid
    /// `bye`). Stripping first and then scanning would work, but it would move
    /// that hard-won logic somewhere nothing exercises it.
    ///
    /// A gate that reads the text DIRECTLY — `contains`, a regex — must read
    /// through here instead, because a comment naming the identifier satisfies
    /// a raw scan. That is the fourth time this defect has been found in this
    /// suite: on 2026-07-31 the disk-reservation check below was satisfied
    /// entirely by a comment. Deleting the `SetEOF` reservation from
    /// `fileshare.c` and leaving the three pinned lines in the comment that
    /// replaced them built both guests, passed the native suite, and passed all
    /// 915 host tests — while every write extended the file and a full disk
    /// became a late, misleading transfer failure, which is the exact outcome
    /// the gate's own prose says it prevents.
    private func guestSourcesWithoutComments() throws -> [(name: String,
                                                           text: String)] {
        try guestSources().map {
            ($0.name, GateSource.withoutCComments($0.text))
        }
    }

    // MARK: - Reading templates out of C

    /// C string literals that sit next to each other are one literal.
    /// That is how every message in wire.c is written, so gathering them
    /// is how a whole message is recovered.
    private func adjacentLiterals(in source: String) -> [String] {
        var out: [String] = []
        var current: String?
        let chars = Array(source)
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
            // That was not hypothetical. now-guest-68k/src/core/wire68.c had three
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

    /// A message whose `type` is COMPUTED rather than spelled, and the
    /// concrete types it can be.
    ///
    /// `xfer_finish` writes `"{\"type\":\"%s.end\"…"` with `"file"` or
    /// `"capture"`, so the scanner reads a type that no guest ever sends.
    /// Naming the alternatives lets both be checked for real instead of
    /// waved through — and a NEW computed type fails until someone lists it,
    /// which is the same bargain `piecemealCoverage` strikes.
    private static let computedTypes: [String: [String]] = [
        // `xfer_end_type` maps a transfer kind onto the message that closes
        // it, and a scene rides the same lane and the same sender as a
        // capture — so `%s.end` now stands for three types, not two.
        "X.end": ["file.end", "capture.end", "scene.end"],
    ]

    /// Every whole message the guest can send decodes on this side.
    ///
    /// **This used to forgive any undecodable type that was not `file.*`.**
    /// The carve-out read "a guest-only verb the host never receives is
    /// fine", but every one of these is a frame the guest writes onto the
    /// wire, so the host receives all of them — and the file's own opening
    /// paragraph is about frames the host could not decode dropping the
    /// connection. Probed on 2026-07-31: exactly one message reaches that
    /// branch, and it is `X.end` — the scanner's own `%s` placeholder. So the
    /// assertion could never fire (a placeholder never starts with `file.`)
    /// while every genuinely undecodable non-`file.` type went through it in
    /// silence. A computed type is now resolved to its real alternatives and
    /// an unknown type is a failure.
    func testEveryGuestMessageDecodes() throws {
        var checked = 0
        for (file, text) in try guestSources() {
            for template in messageTemplates(in: text).whole {
                let json = instantiate(template)
                checked += 1
                do {
                    _ = try ControlMessageCodec.decode(Data(json.utf8))
                } catch ControlMessageError.unknownType(let type) {
                    guard let concrete = Self.computedTypes[type] else {
                        XCTFail("""
                            \(file): the host cannot decode \(type), a \
                            message this guest sends. If the type is \
                            COMPUTED from a %s, name it in computedTypes \
                            with the types it can actually be; otherwise \
                            the host needs a decoder for it.
                            """)
                        continue
                    }
                    // The placeholder resolved: check what it stands for.
                    for real in concrete {
                        let substituted = json.replacingOccurrences(
                            of: "\"type\":\"\(type)\"",
                            with: "\"type\":\"\(real)\"")
                        XCTAssertNoThrow(
                            try ControlMessageCodec.decode(
                                Data(substituted.utf8)), """
                            \(file): the host cannot decode \(real), which \
                            is one of the types \(type) stands for.
                            """)
                    }
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

    /// The object-shaped `command.result` outputs decode, and their contents
    /// survive.
    ///
    /// **The test above could not see these, and they were broken.** Every
    /// reply here assembles itself piecemeal with `append`/`emit` rather than
    /// as one `snprintf`, so no whole template exists for the scanner to
    /// find — and the host's `CommandResult.output` was
    /// `[String: [[String]]]?`, which cannot hold any of them. A host that
    /// cannot decode a frame drops the connection, so asking a guest to
    /// `observe` — the verb the entire act plane is aimed through — would
    /// have taken the link down, and the contract has declared these shapes
    /// (`x-axTree`) since the reference layer landed.
    ///
    /// `qdtrace` is what surfaced it, by being the first object-shaped reply
    /// written as a single template. It was reported as a qdtrace defect and
    /// was never one.
    ///
    /// Written as literal fixtures rather than scanned, on purpose: the
    /// scanner is what missed this, so a check that depends on it inherits
    /// the blind spot. These are hand-copied from the emitters in
    /// `observe.c` and `qdtrace_json.c`.
    func testObjectShapedCommandOutputsDecodeAndKeepTheirContents() throws {
        let cases: [(String, String, String)] = [
            ("axsnap", "observe.c", #"""
            {"type":"command.result","id":1,"ok":true,"output":{"axsnap":\#
            {"front":{"name":"Finder"},"hasWindows":true,"hasMenus":true,\#
            "references":{"live":3,"minted":9,"evicted":6,"capacity":64}}}}
            """#),
            ("observe", "observe.c", #"""
            {"type":"command.result","id":2,"ok":true,"output":{"observe":\#
            {"scope":"front","processes":[],"count":0,"truncated":false,\#
            "live":0}}}
            """#),
            ("handle", "observe.c", #"""
            {"type":"command.result","id":3,"ok":true,"output":{"handle":\#
            {"ref":"now-element-0","verdict":"stale","reason":"gone",\#
            "resolved":false}}}
            """#),
            ("qdtrace status", "qdtrace_json.c", #"""
            {"type":"command.result","id":4,"ok":true,"output":{"qdtrace":\#
            {"cmd":"status","ring":{"writeCursor":4096,"seq":2,\#
            "overrun":false},"ops":{"total":0,"text":0}}}}
            """#),
        ]
        for (verb, file, json) in cases {
            let message: ControlMessage
            do {
                message = try ControlMessageCodec.decode(Data(json.utf8))
            } catch {
                XCTFail("""
                    \(file): the host cannot decode \(verb)'s reply, which \
                    the contract declares as an object: \(error)
                    """)
                continue
            }
            guard case .commandResult(let result) = message else {
                XCTFail("\(verb) did not decode as a command.result")
                continue
            }
            // Decoding is half of it. A decoder that quietly dropped the
            // object would pass a decodes-without-throwing check and lose
            // the whole answer, which is the failure mode a lenient decoder
            // invites — so the payload is read back.
            guard case .object(let payload)? = result.outputObjects?[
                verb.split(separator: " ").first.map(String.init) ?? verb]
            else {
                XCTFail("""
                    \(verb) decoded and its output object is gone. A \
                    decoder that skips what it cannot type has lost the \
                    reply while reporting success.
                    """)
                continue
            }
            XCTAssertFalse(payload.isEmpty, "\(verb)'s output object is empty")
        }
    }

    /// A row-array output still lands in `output`, where every reader looks.
    ///
    /// The other half of the split above: if the lenient decoder put rows in
    /// `outputObjects` too, every consumer in the app would go quietly blind
    /// while this file stayed green.
    func testRowArrayOutputsStillLandInTheRowProperty() throws {
        let json = #"""
        {"type":"command.result","id":5,"ok":true,"output":{"gestalt":\#
        [["Model","Power Macintosh"],["RAM","64 MB"]]}}
        """#
        guard case .commandResult(let result) =
            try ControlMessageCodec.decode(Data(json.utf8)) else {
            return XCTFail("not a command.result")
        }
        XCTAssertEqual(result.output?["gestalt"],
                       [["Model", "Power Macintosh"], ["RAM", "64 MB"]])
        XCTAssertNil(result.outputObjects,
                     "a row array must not be diverted to outputObjects")
        XCTAssertEqual(result.rows("gestalt"), result.output?["gestalt"])
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
        // Comments stripped. This gate's direction is the safe one — a
        // comment can only ADD hits to a check that demands zero — but a
        // commented-out call is then a failure about code that does not run,
        // and the suite has paid for that shape of false positive four times
        // in a week (see AgentIntegrationCapabilityTests).
        //
        // The list of keys is hand-written, and that is the real limit: a
        // NEW key naming an HFS path is invisible here until someone adds
        // it. Nothing in the contract marks a field as a filename, so there
        // is nothing to derive the list from.
        for (file, text) in try guestSourcesWithoutComments() {
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
    ///
    /// **Comments are stripped**, and that is not tidiness — see
    /// `guestSourcesWithoutComments()` for the mutation that removed the
    /// reservation outright and left this gate reading the comment that
    /// replaced it, green, across every suite this project has.
    ///
    /// What it still cannot see, and no `contains` can: these are three
    /// *lines*, pinned by their exact text. They prove the statements are
    /// written somewhere in the file — not that they run, not that they run in
    /// this order, and not that they run before the guest answers `file.accept`.
    /// Reformatting any one of them across two lines fails this gate while
    /// changing nothing, and hoisting all three into a helper that is never
    /// called passes it. The claim in the sentence above is about REACHABILITY,
    /// and reachability is what reading text cannot establish — the standing
    /// decision not to grow a partial parser for it is at `HostFaceReach.reached`.
    func testGuestChecksDiskReservationBeforeAcceptingUpload()
        throws {
        let fileshare = try XCTUnwrap(
            try guestSourcesWithoutComments()
                .first { $0.name.hasSuffix("/fileshare.c") }?.text)
        XCTAssertTrue(fileshare.contains(
            "err = SetEOF(rx->data_ref, bytes);"))
        XCTAssertTrue(fileshare.contains(
            "return err == dskFulErr ? kFilesTooBig : kFilesIOError;"))
        XCTAssertTrue(fileshare.contains(
            "rx->reserved_bytes = need;"))
    }

    /// Mirror's semantic target is receiver-resolved, and an application is
    /// notified only after the checked same-folder rename has succeeded.
    /// This is a source-shaped guard because the classic File Manager and
    /// Apple Event Manager cannot run in the native host suite; the guest
    /// cross-build remains the compile half of the same boundary.
    func testMirrorFileDropResolvesAndDeliversAfterSettlement() throws {
        let drop = try GateSource.guestC(
            "now-guest-ppc/src/files/files_drop.c")
        let wire = try GateSource.guestC(
            "now-guest-ppc/src/core/wire.c")

        XCTAssertTrue(drop.contains("FindFolder(kOnSystemDisk, kDesktopFolderType"))
        XCTAssertTrue(drop.contains("FSMakeFSSpec(0, 0, ppath, &spec)"))
        XCTAssertTrue(drop.contains("now_files_downloads(&vref, &dir)"))
        XCTAssertTrue(drop.contains("kAEOpenDocuments"))
        XCTAssertTrue(wire.contains("now_json_next_object(value, object"),
                      "nested Mirror keys must not collide with file.offer keys")

        let settled = try XCTUnwrap(
            wire.range(of: "rc = now_files_receive_finish(&g_put.rx);"))
        let delivered = try XCTUnwrap(
            wire.range(of: "now_files_mirror_deliver(&g_put.drop_target"))
        XCTAssertLessThan(settled.lowerBound, delivered.lowerBound,
                          "an application was notified before its file settled")
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
    /// hello, ping and error are here from now-guest-68k/src, which assembles
    /// every message through numfmt appends because the 68K build has no
    /// printf family (its float tail costs ~42 KB of a 384 KB partition).
    private static let piecemealCoverage: [String: String?] = [
        "file.listing": "testFileListingAsTheGuestWritesIt",
        "file.result": "testFileResultAsTheGuestWritesIt",
        "census.report": "testCensusReportAsTheGuestWritesIt",
        "process.listing": "testProcessListingAsTheGuestWritesIt",
        "software.listing": "testSoftwareListingAsTheGuestWritesIt",
        "command.result": nil,
        "scene.begin": "testSceneBeginSettlementsAsTheGuestWritesIt",
        // The no-change answer, built across several snprintf calls because
        // its phases block is a loop over the phase table. It is the
        // CHEAPEST and most common answer in the scene family, which is
        // exactly why it needs a fixture: nothing else exercises the path.
        "scene.same": "testSceneSameAsTheGuestWritesIt",
        "mirror.invalidate": "testMirrorInvalidationAsTheGuestWritesIt",
        "hello": "test68KHelloAsTheGuestWritesIt",
        "ping": "test68KPingAsTheGuestWritesIt",
        "error": "test68KErrorReplyAsTheGuestWritesIt",
        "continuity.report":
            "test68KContinuityRefusalAsTheGuestWritesIt",
        "bye": "test68KByeAsTheGuestWritesIt",
        // The guest's half of the revision gate (wire68.c,
        // send_refuse_and_close). `refuse` used to be the host's message
        // alone; the contract binds the check to whoever RECEIVES a hello,
        // so both guests now send one.
        "refuse": "test68KRefuseAsTheGuestWritesIt",
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
            .appendingPathComponent("now-host/Tests/HostTests")
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
    // MARK: - The build stamp rides hello

    /// The PowerPC guest's hello carries a `build`, and it is the build
    /// stamp rather than a literal.
    ///
    /// `PRODUCT_VERSION` is hand-edited, so two builds routinely report the
    /// same version — on 2026-07-30 a stale guest on the 1400c failing every
    /// exec test looked identical to a current one, and an hour of diagnosis
    /// went to the wrong half of the system (docs/open-issues.md). What makes
    /// the field worth anything is that nobody types its value:
    /// `now_build_stamp()` is `__DATE__ " " __TIME__` of a file CMake touches
    /// every build. A hello that carried a literal here, or dropped the field,
    /// would leave a host back where it started, so both are checked.
    func testThePowerPCGuestsHelloCarriesItsBuildStamp() throws {
        /* Through the shared reader, which strips comments: the comment
           beside this line names now_build_stamp(), so a raw-text scan
           passed even with the call replaced by a literal. */
        let body = try sendHelloBody()

        XCTAssertTrue(
            body.contains(#"\"build\":\"%s\""#),
            "The PowerPC guest's hello no longer carries a build field. "
                + "Without it a host cannot tell a stale guest from a "
                + "current one, because PRODUCT_VERSION is hand-edited and "
                + "answers the same for both.")
        XCTAssertTrue(
            body.contains("now_build_stamp()"),
            "hello names a build but does not fill it from "
                + "now_build_stamp(). A hand-written build string is the "
                + "same defect as a hand-written version, one field over.")
    }

    /// The contract admits the field the guest writes, and does not require
    /// it. Both directions are the point: an unadmitted field is refused by
    /// a schema that closes `additionalProperties`, and a REQUIRED one would
    /// break the 68K guest, which sends no build.
    func testTheContractMakesBuildOptionalOnHello() throws {
        XCTAssertTrue(
            try contractProperties(of: "Hello").contains("build"),
            "contract/asyncapi.yaml does not name `build` on Hello, and the "
                + "schema closes additionalProperties, so a guest sending "
                + "one is sending an illegal message.")
        XCTAssertFalse(
            try XCTUnwrap(requiredFields()["Hello"]).contains("build"),
            "`build` is required on Hello. NOW-68K sends none, so requiring "
                + "it makes every 68K hello non-conformant; absence has a "
                + "defined reading and that is the whole design.")
    }

    // MARK: - The machine's own answer rides hello

    /// The PowerPC guest's hello carries `agent`, and it comes from
    /// `now_agent_access()` rather than a literal.
    ///
    /// The literal is the failure mode worth naming: the field's whole
    /// purpose is that a machine can answer `disabled`, and a token spelled
    /// into `send_hello` is one a switch or an installer could never change.
    /// One function, one place for both of those to land.
    func testThePowerPCGuestsHelloCarriesItsMachinesAnswer() throws {
        let body = try sendHelloBody()

        XCTAssertTrue(
            body.contains(#"\"agent\":\"%s\""#),
            "The PowerPC guest's hello no longer carries an `agent` field. "
                + "Silence is not consent by contract — but it is also not "
                + "refusal, so a machine that says nothing cannot refuse, "
                + "and this guest has no other way to say `disabled`.")
        XCTAssertTrue(
            body.contains("now_agent_access()"),
            "hello names an agent tier but does not fill it from "
                + "now_agent_access(). A literal here is a machine whose "
                + "answer nothing can ever change.")
    }

    /// `send_hello` stays ONE snprintf.
    ///
    /// Not style: this file reads the guest's source, and a message built
    /// across several calls is one it cannot check — the failure text at the
    /// top of this file says so and offers a fixture instead. `build` kept
    /// it to one call, and `agent` is the second field to be tempted.
    func testSendHelloIsStillASingleSnprintf() throws {
        let body = try sendHelloBody()
        let calls = body.components(separatedBy: "snprintf(").count - 1

        XCTAssertEqual(
            calls, 1,
            "send_hello builds its JSON across \(calls) snprintf calls. "
                + "This file can only read a message written in one, so "
                + "splitting it takes hello out of the scan that proves it "
                + "conforms — quietly, and in the one message every "
                + "connection begins with.")
    }

    /// The two seams fill the two fields **the way round the format string
    /// names them**.
    ///
    /// Found by mutation, and it is the limit of every check above: they ask
    /// whether an identifier is somewhere in the body, which a call in the
    /// argument list satisfies and so does one nowhere near it. Swapping the
    /// two arguments —
    ///
    ///     kNowContractRevision, PRODUCT_VERSION, now_agent_access(),
    ///     now_build_stamp(), esc, kNowDefaultChunk
    ///
    /// — left every gate in this file green while the guest put its access
    /// tier in `build` and its build stamp in `agent`. That is not a subtle
    /// wrong answer: an `agent` the host cannot decode is not consent, so
    /// the machine would read as refusing, and the field that exists to tell
    /// two builds apart would answer "full" for every one of them.
    ///
    /// C's varargs have no other way to say which value fills which `%s`, so
    /// position IS the meaning here and pinning it is a fair check rather
    /// than a style rule. Both seams must appear AFTER the format string —
    /// which is what makes them arguments and not merely present — in the
    /// order the format string names their fields, and before `esc`, which
    /// fills the `name` that follows both.
    func testHelloFillsBuildAndAgentFromTheirSeamsInThatOrder() throws {
        let body = try sendHelloBody()

        guard let formatEnd = body.range(of: #"\"chunk\":%d}""#),
              let build = body.range(of: "now_build_stamp()",
                                     range: formatEnd.upperBound
                                        ..< body.endIndex),
              let agent = body.range(of: "now_agent_access()",
                                     range: formatEnd.upperBound
                                        ..< body.endIndex),
              let name = body.range(of: "esc,", range: formatEnd.upperBound
                                        ..< body.endIndex) else {
            return XCTFail(
                "send_hello does not pass now_build_stamp(), "
                    + "now_agent_access() and the escaped machine name as "
                    + "arguments after its format string. A seam named in "
                    + "the body but not in the argument list fills no "
                    + "field, which is the hole the checks above cannot "
                    + "see on their own.")
        }
        XCTAssertTrue(
            build.upperBound < agent.lowerBound,
            "send_hello passes now_agent_access() before now_build_stamp(), "
                + "and the format string names `build` before `agent` — so "
                + "the guest sends its access tier as a build stamp and its "
                + "build stamp as an access tier. The host cannot decode "
                + "the latter, and an undecodable tier is read as refusal.")
        XCTAssertTrue(
            agent.upperBound < name.lowerBound,
            "send_hello passes the escaped machine name before "
                + "now_agent_access(), so `agent` and `name` carry each "
                + "other's values.")
        XCTAssertTrue(
            body.range(of: #"\"build\":\"%s\""#)!.lowerBound
                < body.range(of: #"\"agent\":\"%s\""#)!.lowerBound,
            "The format string names `agent` before `build` while the "
                + "argument list is still in build-then-agent order, so the "
                + "two fields carry each other's values.")
    }

    /// The contract admits `agent` on Hello and does not require it.
    ///
    /// Required would break `test68KFixturesCarryTheirRequiredFields`
    /// against the 68K guest's captured hello, which is direct evidence
    /// rather than an argument: a guest that predates the field has to stay
    /// conformant, because absence is a defined reading and not an error.
    func testTheContractMakesAgentOptionalOnHello() throws {
        XCTAssertTrue(
            try contractProperties(of: "Hello").contains("agent"),
            "contract/asyncapi.yaml does not name `agent` on Hello, and the "
                + "schema closes additionalProperties, so a guest sending "
                + "one is sending an illegal message.")
        XCTAssertFalse(
            try XCTUnwrap(requiredFields()["Hello"]).contains("agent"),
            "`agent` is required on Hello. NOW-68K sends none and older "
                + "guests send none, so requiring it makes their hellos "
                + "non-conformant — and absence having a defined reading is "
                + "the whole design.")
    }

    /// The three tokens the contract lists and the three the host can name
    /// are the same three.
    ///
    /// A tier added to one side only is the defect class this file exists
    /// for, and it would be quiet in exactly the wrong direction: a token
    /// the host cannot name is not consent, so a tier added to the contract
    /// alone would read as a refusal nobody wrote.
    func testTheContractsAgentTokensAreTheOnesTheHostNames() throws {
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "contract/asyncapi.yaml"),
            encoding: .utf8)
        guard let line = text.components(separatedBy: .newlines).first(
                where: { $0.hasPrefix("          enum: [disabled") }) else {
            return XCTFail("contract/asyncapi.yaml no longer declares an "
                           + "enum of agent tokens on Hello")
        }
        let declared = line
            .drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(
            declared, ["disabled", "read-only", "full"],
            "The contract's agent tokens changed. Whoever changed them owes "
                + "AgentIntegrationGuestAccess the same edit, and the "
                + "ordering clause an explanation.")
        for token in declared {
            XCTAssertEqual(
                AgentIntegrationGuestAccess(wire: token)?.wire, token,
                "the host does not name `\(token)`, so it would decode as "
                    + "unrecognised — which is not consent, and would read "
                    + "as a refusal the contract never wrote")
        }
    }

    /// `send_hello`'s body, by its DEFINITION rather than the forward
    /// declaration above it — wire.c has both, and matching the declaration
    /// hands back the body of whatever function happens to follow it.
    ///
    /// COMMENTS ARE STRIPPED, through the shared reader in `GateSource`,
    /// and that is not tidiness. Every comment in this function names the
    /// very identifiers these gates look for, so a scan of the raw text
    /// passes on the prose while the code says something else: replacing
    /// `now_agent_access()` with a literal was invisible to this gate until
    /// the stripping went in, and the comment three lines above explaining
    /// why a literal is wrong was what hid it.
    ///
    /// **Not finding the function is a FAILURE, not a skip.** It was a skip
    /// once, and a skip here is the quietest hole in the file: renaming
    /// `send_hello` — or writing its brace K&R-style — took three gates off
    /// the board and left a green run reporting one more skip among fifty.
    /// The file is in the repository; there is no environment in which its
    /// absence is a legitimate excuse.
    private func sendHelloBody() throws -> String {
        let wire = try GateSource.raw("now-guest-ppc/src/core/wire.c")
        guard let start = wire.range(of: "static void send_hello(void)\n{"),
              let end = wire.range(of: "\n}", range: start.upperBound
                                    ..< wire.endIndex) else {
            throw HelloUnreadable.noDefinition
        }
        return GateSource.withoutCComments(
            String(wire[start.upperBound..<end.lowerBound]))
    }

    private enum HelloUnreadable: Error, CustomStringConvertible {
        case noDefinition

        var description: String {
            "No `static void send_hello(void)` definition in "
                + "now-guest-ppc/src/core/wire.c. Every hello gate in this "
                + "file reads that function by name, so a rename or a "
                + "reformatted brace takes them all off the board at once — "
                + "which is why this is a failure and not a skip. Point the "
                + "reader at wherever the function went."
        }
    }
}
