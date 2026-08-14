import XCTest
@testable import Host

/// Expectations here are the DOCUMENTED classic Mac keyboard values (Inside
/// Macintosh: Text, "ASCII character codes", and the ADB virtual codes), typed
/// out independently of the table under test. Reading them back out of
/// `ClassicKeyByte.byVirtualCode` would test the map against itself.
final class ClassicKeyByteTests: XCTestCase {
    /// virtual code, AppKit `characters` for that key, classic character byte.
    private struct Case {
        let name: String
        let code: UInt16
        let appKitCharacters: String
        let expected: UInt8
    }

    /// AppKit reports the arrows, page keys and home/end as private-use
    /// function-key scalars; Delete as DEL. Both forms are what a real
    /// `NSEvent` carries, so the fixtures spell them rather than the fix's
    /// idea of them.
    private let cases: [Case] = [
        .init(name: "left arrow", code: 0x7B,
              appKitCharacters: "\u{F702}", expected: 0x1C),
        .init(name: "right arrow", code: 0x7C,
              appKitCharacters: "\u{F703}", expected: 0x1D),
        .init(name: "up arrow", code: 0x7E,
              appKitCharacters: "\u{F700}", expected: 0x1E),
        .init(name: "down arrow", code: 0x7D,
              appKitCharacters: "\u{F701}", expected: 0x1F),
        .init(name: "backspace", code: 0x33,
              appKitCharacters: "\u{7F}", expected: 0x08),
        .init(name: "forward delete", code: 0x75,
              appKitCharacters: "\u{F728}", expected: 0x7F),
        .init(name: "return", code: 0x24,
              appKitCharacters: "\r", expected: 0x0D),
        .init(name: "tab", code: 0x30,
              appKitCharacters: "\t", expected: 0x09),
        .init(name: "escape", code: 0x35,
              appKitCharacters: "\u{1B}", expected: 0x1B),
        .init(name: "page up", code: 0x74,
              appKitCharacters: "\u{F72C}", expected: 0x0B),
        .init(name: "page down", code: 0x79,
              appKitCharacters: "\u{F72D}", expected: 0x0C),
        .init(name: "home", code: 0x73,
              appKitCharacters: "\u{F729}", expected: 0x01),
        .init(name: "end", code: 0x77,
              appKitCharacters: "\u{F72B}", expected: 0x04),
    ]

    func testSpecialKeysCarryTheirClassicCharacterByte() {
        for item in cases {
            XCTAssertEqual(
                ClassicKeyByte.character(forVirtualCode: item.code,
                                         characters: item.appKitCharacters),
                item.expected,
                "\(item.name) (virtual code 0x\(String(item.code, radix: 16)))")
        }
    }

    /// The measured defect: a lossy Mac OS Roman conversion turns every
    /// 0xF700-range scalar into '?', which the guest then TYPED.
    func testNoSpecialKeyDegradesToAQuestionMark() {
        for item in cases {
            XCTAssertNotEqual(
                ClassicKeyByte.character(forVirtualCode: item.code,
                                         characters: item.appKitCharacters),
                0x3F, "\(item.name) still lossily converts to '?'")
        }
    }

    /// The virtual code is the identity of the key. A chord changes AppKit's
    /// `characters` and must not change the byte the classic machine expects.
    func testModifiedArrowKeepsItsClassicByte() {
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x7B,
                                     characters: "\u{F702}"), 0x1C)
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x7B, characters: nil),
            0x1C)
    }

    func testOrdinaryPrintingKeysStillCrossAsThemselves() {
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x00, characters: "a"),
            0x61)
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x31, characters: " "),
            0x20)
        // Mac OS Roman, not Latin-1: option-8 is 0xA5 there.
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x1C, characters: "•"),
            0xA5)
    }

    /// F1…F15 and Help have no classic byte. Sending nothing is honest;
    /// sending '?' is the defect one key over.
    func testUnmappedFunctionKeysSendNoCharacter() {
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x7A,
                                     characters: "\u{F704}"), 0)
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x72,
                                     characters: "\u{F746}"), 0)
        XCTAssertEqual(
            ClassicKeyByte.character(forVirtualCode: 0x50, characters: ""), 0)
    }
}
