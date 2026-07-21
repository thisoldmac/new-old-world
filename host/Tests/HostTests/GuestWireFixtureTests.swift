import Foundation
import XCTest
@testable import Host

/// The exact bytes the guest puts on the wire, decoded by the host.
///
/// Every other test in this suite builds messages as Swift values, which
/// proves the host agrees with itself and nothing more. Two frames the
/// guest sends were missing contract-required fields and no test noticed:
/// the host could not decode them, dropped the connection, and the
/// symptom was "the send does nothing".
///
/// The strings below are copied from the snprintf calls in
/// guest/src/wire.c. When one changes there, it changes here, and that
/// is the point: this is the only place the two halves are compared.
final class GuestWireFixtureTests: XCTestCase {
    private func decode(_ json: String,
                        file: StaticString = #filePath,
                        line: UInt = #line) throws -> ControlMessage {
        do {
            return try ControlMessageCodec.decode(Data(json.utf8))
        } catch {
            XCTFail("the host cannot decode what the guest sends: \(error)",
                    file: file, line: line)
            throw error
        }
    }

    /// now_wire_send_file(): the guest offering a file to the host.
    func testFileOfferAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.offer","id":1,"name":"Notes","path":"",\
        "container":"data","bytes":66,"fileType":"TEXT",\
        "creator":"ttxt","modified":3300000000}
        """
        guard case .fileOffer(let offer) = try decode(json) else {
            return XCTFail("not an offer")
        }
        XCTAssertEqual(offer.name, "Notes")
        XCTAssertEqual(offer.path, "", "the root of this Mac's share")
        XCTAssertEqual(offer.bytes, 66)
        XCTAssertEqual(offer.container, "data")
    }

    /// send_accepted(): the guest announcing the transfer that follows.
    func testFileBeginAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.begin","id":1,"transfer":3,"name":"Notes",\
        "container":"data","bytes":66}
        """
        guard case .fileBegin(let begin) = try decode(json) else {
            return XCTFail("not a begin")
        }
        XCTAssertEqual(begin.transfer, 3)
        XCTAssertEqual(begin.name, "Notes")
        XCTAssertEqual(begin.bytes, 66)
    }

    /// xfer_finish(): how any transfer from the guest ends.
    func testFileEndAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.end","id":1,"transfer":3,"ok":true,"sendMs":412}
        """
        guard case .fileEnd(let end) = try decode(json) else {
            return XCTFail("not an end")
        }
        XCTAssertTrue(end.ok)
    }

    /// serve_file_list(): a listing, with the share label the browser
    /// puts in the breadcrumb.
    func testFileListingAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.listing","id":2,"path":"","entries":[\
        {"name":"Docs","kind":"folder","modified":3300000000},\
        {"name":"Notes","kind":"file","fileType":"TEXT","creator":"ttxt",\
        "dataBytes":66,"rsrcBytes":0,"modified":3300000000}],\
        "more":false,"cursor":3,"root":"Macintosh HD:Lab:"}
        """
        guard case .fileListing(let listing) = try decode(json) else {
            return XCTFail("not a listing")
        }
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries.first?.isFolder, true)
        XCTAssertEqual(listing.root, "Macintosh HD:Lab:")
    }

    /// A listing without the root, which is what a subfolder gets and
    /// what a guest built before the label existed sends.
    func testAListingWithoutARootStillDecodes() throws {
        let json = """
        {"type":"file.listing","id":2,"path":"Docs","entries":[],\
        "more":false,"cursor":1}
        """
        guard case .fileListing(let listing) = try decode(json) else {
            return XCTFail("not a listing")
        }
        XCTAssertNil(listing.root)
    }

    /// file_refuse(): every guest-side failure takes this shape.
    func testFileRefuseAsTheGuestWritesIt() throws {
        let json = """
        {"type":"file.refuse","id":4,"code":"busy",\
        "reason":"a transfer is already in flight"}
        """
        guard case .fileRefuse(let refuse) = try decode(json) else {
            return XCTFail("not a refusal")
        }
        XCTAssertEqual(refuse.code, "busy")
    }

    /// finish_put(): the guest's receipt for a file the host sent.
    func testFileDoneAsTheGuestWritesIt() throws {
        for json in [
            #"{"type":"file.done","id":5,"ok":true}"#,
            #"{"type":"file.done","id":5,"ok":false,"code":"io-error","#
                + #""reason":"the File Manager refused (-48)"}"#,
        ] {
            guard case .fileDone = try decode(json) else {
                return XCTFail("not a receipt")
            }
        }
    }

    /// file.progress, sent mid-put so the host's bar moves.
    func testFileProgressAsTheGuestWritesIt() throws {
        let json = #"{"type":"file.progress","id":5,"received":32768}"#
        guard case .fileProgress(let progress) = try decode(json) else {
            return XCTFail("not progress")
        }
        XCTAssertEqual(progress.received, 32768)
    }
}
