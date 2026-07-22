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

    private func guestSources() throws -> [(name: String, text: String)] {
        let dir = Self.repoRoot.appendingPathComponent("guest/src")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".c") }.sorted()
        XCTAssertFalse(names.isEmpty, "no guest sources at \(dir.path)")
        return try names.map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0),
                            encoding: .utf8))
        }
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

    /// Messages built up across several calls cannot be checked this
    /// way. Naming them keeps the gap visible instead of letting a green
    /// suite imply coverage it does not have.
    func testMessagesThisCannotCheckAreKnown() throws {
        var found: Set<String> = []
        for (_, text) in try guestSources() {
            for template in messageTemplates(in: text).partial {
                let type = template
                    .dropFirst("{\"type\":\"".count).prefix { $0 != "\"" }
                found.insert(String(type))
            }
        }
        XCTAssertEqual(found,
                       ["file.listing", "file.result", "command.result",
                        "census.report", "process.listing"], """
            The set of messages assembled piecemeal changed. Those are \
            NOT covered by the conformance checks above — either give the \
            new one a hand-written fixture in GuestWireFixtureTests, or \
            build it in one call so it can be checked here.
            """)
    }
}
