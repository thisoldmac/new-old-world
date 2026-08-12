import MirrorKit
import XCTest
@testable import Host

final class MirrorFileTransferModelTests: XCTestCase {
    func testDesktopAndFinderSourcesStayDistinctOnTheWire() {
        let file = CrossMachineFileTargeting.FileIdentity(
            name: "Read Me", kind: "document", fileType: "TEXT",
            creator: "ttxt")
        XCTAssertEqual(
            MirrorFileTransferModel.wireSource(.desktop(file)),
            MirrorFileSource(kind: "desktop", name: "Read Me"))
        XCTAssertEqual(
            MirrorFileTransferModel.wireSource(
                .finderWindow(path: "Macintosh HD:Work", file: file)),
            MirrorFileSource(kind: "finder-window", name: "Read Me",
                             path: "Macintosh HD:Work"))
    }

    func testEveryReleaseTargetHasOneClosedWireIdentity() {
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(.desktop),
                       MirrorFileDrop(kind: "desktop"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .finderFolder(path: "Macintosh HD:Work")),
            MirrorFileDrop(kind: "finder-folder",
                           path: "Macintosh HD:Work"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .applicationProcess(psn: "1:2", name: "SimpleText")),
            MirrorFileDrop(kind: "application-process", psn: "1:2",
                           name: "SimpleText"))
        XCTAssertEqual(MirrorFileTransferModel.wireTarget(
            .applicationCreator(creator: "ttxt", name: "SimpleText")),
            MirrorFileDrop(kind: "application-creator", creator: "ttxt",
                           name: "SimpleText"))
    }
}
