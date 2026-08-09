import XCTest
@testable import Host

/// The scheduler is a product boundary, not a convention at each caller.
/// This census pins the transport sends which are easy to accidentally add
/// beside it: a second direct send would restore head-of-line blocking while
/// every behavioural test of the existing path remained green.
final class GuestWorkSourceCensusTests: XCTestCase {
    private let listener = "now-host/Sources/Host/GuestListener.swift"

    func testPagedAndInteractiveFamiliesHaveOneAdmittedTransportSend() throws {
        let text = try GateSource.raw(listener)
        let sends = [
            "session.sendFileList(": "listFilesAdmitted",
            "session.sendProcessList(": "listProcessesAdmitted",
            "session.sendSoftwareList(": "listSoftwareAdmitted",
            "session.sendProcessDrive(": "driveProcessAdmitted",
            "session.sendCaptureRequest(": "requestCaptureAdmitted",
        ]

        for (send, admittedFunction) in sends {
            XCTAssertEqual(
                text.components(separatedBy: send).count - 1, 1,
                "\(send) must have one transport site; every additional "
                    + "site needs admission through GuestWorkScheduler")
            XCTAssertTrue(
                text.contains("private func \(admittedFunction)"),
                "the sole \(send) site must remain behind "
                    + "\(admittedFunction)")
        }
    }

    func testNoOtherHostSourceSendsThoseFamiliesDirectly() throws {
        let root = GateSource.repoRoot
            .appendingPathComponent("now-host/Sources/Host")
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        let sends = [
            ".sendFileList(", ".sendProcessList(", ".sendSoftwareList(",
            ".sendProcessDrive(", ".sendCaptureRequest(",
        ]
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "Session.swift",
                  url.lastPathComponent != "GuestListener.swift" else {
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            if sends.contains(where: text.contains) {
                offenders.append(url.path.replacingOccurrences(
                    of: GateSource.repoRoot.path + "/", with: ""))
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            "request-family transport sends bypass GuestWorkScheduler in "
                + offenders.sorted().joined(separator: ", "))
    }

    func testMirrorSceneAndContentEnterTheUnifiedScheduler() throws {
        let source = try GateSource.raw(
            "now-host/Sources/Host/NOWMirrorSource.swift")
        XCTAssertEqual(
            source.components(separatedBy:
                "workScheduler.submitCallback(.scene, as: .ambient").count - 1,
            1,
            "the Mirror scene request must have exactly one ambient "
                + "scheduler entry")
        XCTAssertEqual(
            source.components(separatedBy: "cycleIO.requestScene(").count - 1,
            1,
            "a second scene send site could bypass the scheduler")

        let content = try GateSource.raw(
            "now-host/Sources/Host/NOWMirrorContentPlane.swift")
        XCTAssertTrue(content.contains("listener.runScheduledCommand("))
        XCTAssertTrue(content.contains("purpose: .content"))
        XCTAssertTrue(content.contains("workClass: .ambient"))
    }

    func testTheOldParallelDirectActLaneCannotReturn() throws {
        let source = GateSource.repoRoot.appendingPathComponent(
            "now-host/Sources/Host/MirrorDirectActLane.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "a second direct-act lane would make priority unknowable again")
    }
}
