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

    private static var headerURL: URL {
        URL(fileURLWithPath: #filePath)          // …/now-host/Tests/HostTests/x
            .deletingLastPathComponent()          // …/now-host/Tests/HostTests
            .deletingLastPathComponent()          // …/now-host/Tests
            .deletingLastPathComponent()          // …/host
            .deletingLastPathComponent()          // …/
            .appendingPathComponent("contract/wire_limits.h")
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
}
