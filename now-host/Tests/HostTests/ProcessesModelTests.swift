import XCTest
@testable import Host

/// The pure half of the Processes module: how a wire entry becomes a row.
/// The wire path itself is proven end to end by MetalProcessTests; this
/// pins the classification and formatting that a person reads.
@MainActor
final class ProcessesModelTests: XCTestCase {
    private func entry(_ name: String, kind: String, code: String? = nil,
                       creator: String? = nil, sizeKB: Int? = nil,
                       front: Bool? = nil) -> ProcessEntry {
        ProcessEntry(name: name, kind: kind, code: code, creator: creator,
                     sizeKB: sizeKB, front: front)
    }

    func testFinderGroupsWithApplicationsNotBackground() {
        // The Finder is an application; filing it under "Background"
        // would read as wrong to anyone who knows the machine.
        XCTAssertEqual(ProcessesModel.group(of: entry("Finder", kind: "finder")),
                       .applications)
        XCTAssertEqual(
            ProcessesModel.group(of: entry("NOW", kind: "application")),
            .applications)
        XCTAssertEqual(
            ProcessesModel.group(of: entry("Control Strip", kind: "background")),
            .background)
    }

    func testKindLabelIsFaceForward() {
        XCTAssertEqual(entry("Finder", kind: "finder").kindLabel, "Finder")
        XCTAssertEqual(entry("x", kind: "application").kindLabel, "Application")
        XCTAssertEqual(entry("x", kind: "background").kindLabel, "Background")
    }

    func testSignatureLabelJoinsBothCodesAndDropsBlanks() {
        XCTAssertEqual(
            entry("NOW", kind: "application", code: "APPL", creator: "NwWs")
                .signatureLabel, "APPL · NwWs")
        // The host's own mirror direction sends neither, so there is no
        // caption rather than a lone separator.
        XCTAssertNil(entry("NOW", kind: "application").signatureLabel)
        XCTAssertNil(entry("NOW", kind: "application", code: "", creator: "")
            .signatureLabel)
        XCTAssertEqual(
            entry("x", kind: "application", code: "APPL").signatureLabel,
            "APPL")
    }

    func testSizeLabelPicksTheLegibleUnit() {
        XCTAssertEqual(entry("x", kind: "application", sizeKB: 512).sizeLabel,
                       "512 KB")
        XCTAssertEqual(entry("x", kind: "application", sizeKB: 3072).sizeLabel,
                       "3.0 MB")
        // A process with no size sent (or a nonsense zero) shows nothing,
        // not "0 KB".
        XCTAssertNil(entry("x", kind: "application", sizeKB: 0).sizeLabel)
        XCTAssertNil(entry("x", kind: "application").sizeLabel)
    }
}
