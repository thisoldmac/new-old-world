import XCTest
@testable import Host

/// The third copy of the frame format's numbers, checked against the one
/// the guests compile.
///
/// `contract/wire_limits.h` is a C header, and the Swift target cannot
/// include it without restructuring this package's build. So it is read
/// and parsed here instead — the same technique `GuestWireConformanceTests`
/// already uses to hold this side against the guests' own sources. A
/// third copy that is *checked* is not a third source of truth.
///
/// This exists because the arrangement it replaces is the one AGENTS.md
/// names as this project's costliest defect: the frame constants lived in
/// `now-guest-ppc/src/core/contract.h`, `now-guest-68k/src/core/frame.h` and `FrameCodec.swift`,
/// and frame.h's comment recorded that a human had "cross-checked" the
/// other two by hand. Hand-cross-checking is how three copies stay equal
/// right up until the once they do not — and the failure mode is not a
/// wrong answer, it is a guest that cannot connect and cannot say why.
final class WireLimitsAgreementTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/now-host/Tests/HostTests/x
            .deletingLastPathComponent()          // …/now-host/Tests/HostTests
            .deletingLastPathComponent()          // …/now-host/Tests
            .deletingLastPathComponent()          // …/host
            .deletingLastPathComponent()          // …/
    }

    private static var headerURL: URL {
        repoRoot.appendingPathComponent("contract/wire_limits.h")
    }

    /// `#define NAME VALUE` → the value, as an Int. Tolerates the C
    /// suffixes the header uses (32768L) and hex (0x01), because the
    /// point is to compare NUMBERS, not spellings.
    private func define(_ name: String, in text: String) throws -> Int {
        let pattern = #"^#define\s+"# + name + #"\s+(\S+)"#
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else {
            XCTFail("no #define \(name) in contract/wire_limits.h")
            throw CocoaError(.fileReadCorruptFile)
        }
        var raw = String(text[r])
        while let last = raw.last, "LlUu".contains(last) { raw.removeLast() }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            guard let v = Int(raw.dropFirst(2), radix: 16) else {
                XCTFail("\(name) is not a number: \(raw)"); throw CocoaError(.fileReadCorruptFile)
            }
            return v
        }
        guard let v = Int(raw) else {
            XCTFail("\(name) is not a number: \(raw)"); throw CocoaError(.fileReadCorruptFile)
        }
        return v
    }

    func testFrameCodecAgreesWithTheContractHeader() throws {
        let text = try String(contentsOf: Self.headerURL, encoding: .utf8)

        XCTAssertEqual(FrameHeader.byteCount,
                       try define("NOW_WIRE_FRAME_HEADER_BYTES", in: text),
                       "frame header size disagrees with contract/wire_limits.h")
        XCTAssertEqual(FrameHeader.maxPayloadLength,
                       try define("NOW_WIRE_MAX_PAYLOAD", in: text),
                       "max payload disagrees with contract/wire_limits.h")
        XCTAssertEqual(Int(FrameHeader.Channel.control.rawValue),
                       try define("NOW_WIRE_CHANNEL_CONTROL", in: text))
        XCTAssertEqual(Int(FrameHeader.Channel.bulk.rawValue),
                       try define("NOW_WIRE_CHANNEL_BULK", in: text))
        XCTAssertEqual(Int(FrameHeader.Flags.end.rawValue),
                       try define("NOW_WIRE_FLAG_END", in: text))
    }

    /// The revision gates the hello handshake, so a stale copy on one
    /// side is a guest that refuses to connect. Checked against whatever
    /// this side actually sends rather than a literal repeated here,
    /// which would just be a fourth copy.
    func testContractRevisionAgrees() throws {
        let text = try String(contentsOf: Self.headerURL, encoding: .utf8)
        XCTAssertEqual(Contract.revision, 2,
                       "the unified NOW Extension lifecycle is a breaking "
                       + "mirror schema cut and must not ride revision 1")
        XCTAssertEqual(Contract.revision,
                       try define("NOW_WIRE_CONTRACT_REVISION", in: text),
                       "contract revision disagrees with contract/wire_limits.h")
    }

    // MARK: - the contract's own statement of it

    /// `contract/asyncapi.yaml` is the source of truth AGENTS.md names, and
    /// nothing was checking that the header the guests compile agreed with
    /// it. Everything else in this file compares two copies to each other;
    /// this compares them to the document.
    func testTheContractDocumentAgrees() throws {
        let yaml = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("contract/asyncapi.yaml"),
            encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"^\s*x-contract-revision:\s*(\d+)"#,
                                         options: [.anchorsMatchLines])
        let range = NSRange(yaml.startIndex..., in: yaml)
        guard let m = re.firstMatch(in: yaml, range: range),
              let r = Range(m.range(at: 1), in: yaml),
              let stated = Int(yaml[r]) else {
            return XCTFail("no info.x-contract-revision in contract/asyncapi.yaml")
        }
        XCTAssertEqual(Contract.revision, stated,
                       "this side sends a revision the contract does not state")
    }

    // MARK: - the guests' own hello gate

    /// The body of a C function, from its signature to the closing brace in
    /// column 1 — enough to ask what a specific handler does, rather than
    /// what its file mentions somewhere.
    private func body(of signature: String, inFileAt path: String) throws -> String {
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(path),
            encoding: .utf8)
        guard let start = text.range(of: signature) else {
            XCTFail("no \(signature) in \(path)")
            throw CocoaError(.fileReadCorruptFile)
        }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n}\n") else {
            XCTFail("\(signature) in \(path) has no closing brace")
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(rest[..<end.lowerBound])
    }

    /// **Both guests gate the revision, and both answer with a `refuse`.**
    ///
    /// The contract's connection rules bind the check to whoever RECEIVES a
    /// hello, and for a whole revision only one guest did it: NOW-PPC's
    /// `on_hello` read `name` and `version` and served the session, so a
    /// harness stuck on revision 1 held a link here that it could never
    /// have held against NOW-68K. The missing check is what made the stale
    /// harness look healthy — the `two-halves-never-met-in-a-test` shape,
    /// where nothing is visibly wrong until a message changes.
    ///
    /// Source-read rather than driven, for the reason
    /// `GuestWireConformanceTests` is: no gate in this tree cross-compiles a
    /// guest, let alone runs one, so the only thing that can hold both
    /// guests to a rule on every commit is their own source.
    func testBothGuestsGateTheContractRevisionInTheirHelloHandler() throws {
        let ppc = try body(of: "static int on_hello(const char *reply)",
                           inFileAt: "now-guest-ppc/src/core/wire.c")
        XCTAssertTrue(ppc.contains("\"contract\""),
                      "now-guest-ppc on_hello never reads the host's "
                      + "contract revision")
        XCTAssertTrue(ppc.contains("kNowContractRevision"),
                      "now-guest-ppc on_hello reads a contract revision but "
                      + "compares it against nothing")
        XCTAssertTrue(ppc.contains("\\\"type\\\":\\\"refuse\\\""),
                      "now-guest-ppc on_hello rejects a revision without "
                      + "sending the refuse the contract requires")

        let m68k = try body(of: "static void handle_host_hello(",
                            inFileAt: "now-guest-68k/src/core/wire68.c")
        XCTAssertTrue(m68k.contains("\"contract\""),
                      "now-guest-68k handle_host_hello never reads the "
                      + "host's contract revision")
        XCTAssertTrue(m68k.contains("NOW68K_CONTRACT_REVISION"),
                      "now-guest-68k handle_host_hello reads a contract "
                      + "revision but compares it against nothing")
        XCTAssertTrue(m68k.contains("send_refuse_and_close"),
                      "now-guest-68k handle_host_hello rejects a revision "
                      + "without sending the refuse the contract requires")
    }

    // MARK: - the Python harnesses

    /// The harnesses are the fourth reader of these numbers and the only one
    /// no build touches, so they drifted alone: `tools/askguest.py` and
    /// `tools/liveness-experiment.py` declared revision 1 for as long as the
    /// contract has said 2, and `scripts/probes/nowwire.py` did too — which
    /// is not cosmetic, because that file gates the hello it answers, so
    /// every probe was refusing the guest it had just accepted.
    ///
    /// They now import `contract/wire_limits.py`. This holds that file to the
    /// header, and the next test forbids a harness from going back to a
    /// literal of its own.
    func testThePythonSiblingAgrees() throws {
        let py = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("contract/wire_limits.py"),
            encoding: .utf8)
        let header = try String(contentsOf: Self.headerURL, encoding: .utf8)

        func assign(_ name: String) throws -> Int {
            let re = try NSRegularExpression(pattern: #"^"# + name + #"\s*=\s*(\S+)"#,
                                             options: [.anchorsMatchLines])
            let range = NSRange(py.startIndex..., in: py)
            guard let m = re.firstMatch(in: py, range: range),
                  let r = Range(m.range(at: 1), in: py) else {
                XCTFail("no \(name) in contract/wire_limits.py")
                throw CocoaError(.fileReadCorruptFile)
            }
            let raw = String(py[r])
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                guard let v = Int(raw.dropFirst(2), radix: 16) else {
                    XCTFail("\(name) is not a number: \(raw)")
                    throw CocoaError(.fileReadCorruptFile)
                }
                return v
            }
            guard let v = Int(raw) else {
                XCTFail("\(name) is not a number: \(raw)")
                throw CocoaError(.fileReadCorruptFile)
            }
            return v
        }

        for (python, c) in [("WIRE_CONTRACT_REVISION", "NOW_WIRE_CONTRACT_REVISION"),
                            ("FRAME_HEADER_BYTES", "NOW_WIRE_FRAME_HEADER_BYTES"),
                            ("CHANNEL_CONTROL", "NOW_WIRE_CHANNEL_CONTROL"),
                            ("CHANNEL_BULK", "NOW_WIRE_CHANNEL_BULK"),
                            ("FLAG_END", "NOW_WIRE_FLAG_END"),
                            ("MAX_PAYLOAD", "NOW_WIRE_MAX_PAYLOAD")] {
            XCTAssertEqual(try assign(python), try define(c, in: header),
                           "\(python) in contract/wire_limits.py disagrees with "
                           + "\(c) in contract/wire_limits.h")
        }
    }

    /// A harness that declares its own revision is the defect, not the wrong
    /// number — the number was only wrong because nothing tied it to
    /// anything. So the shape is what is banned: outside
    /// `contract/wire_limits.py`, no Python file under `tools/` or
    /// `scripts/probes/` may assign a bare integer revision or put one
    /// straight into a hello.
    func testNoHarnessDeclaresItsOwnRevision() throws {
        let fm = FileManager.default
        let patterns = [
            #"^\s*(WIRE_)?CONTRACT(_REVISION)?\s*=\s*\d"#,          // CONTRACT = 1
            #"^[A-Z_, ]*\bCONTRACT\b[A-Z_, ]*=\s*[\d, ]+$"#,        // CONTROL, END, CONTRACT = 0, 1, 1
            #""contract"\s*:\s*\d"#,                                // {"contract": 1}
        ].map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }

        var offenders: [String] = []
        for dir in ["tools", "scripts/probes"] {
            let root = Self.repoRoot.appendingPathComponent(dir)
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walk where url.pathExtension == "py" {
                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for re in patterns where re.firstMatch(in: text, range: range) != nil {
                    let rel = url.path.replacingOccurrences(
                        of: Self.repoRoot.path + "/", with: "")
                    if !offenders.contains(rel) { offenders.append(rel) }
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "these harnesses state a contract revision of their own "
                       + "instead of importing contract/wire_limits.py; that is "
                       + "how tools/askguest.py sat on revision 1 for a whole "
                       + "revision without anyone noticing")
    }
}
