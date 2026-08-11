import Darwin
import Foundation
import XCTest
@testable import Host
import NOWAgentIntegration

@MainActor
final class AgentIntegrationArtifactTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func source(_ root: URL, name: String = "Read Me.txt",
                        data: Data = Data("first\nsecond\n".utf8)) throws
        -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func approve(
        _ store: AgentIntegrationArtifactApprovalStore,
        source: URL,
        sessionID: UUID = UUID(),
        approvedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> (AgentIntegrationArtifactApprovalNotice, UUID) {
        guard case .success(let approval) = store.approve(
            sourceURL: source,
            destination: "Lab:Incoming",
            convertText: true,
            sessionID: sessionID,
            approvedAt: approvedAt) else {
            throw UnexpectedTestResult(description: "expected approval")
        }
        return (approval, sessionID)
    }

    func testApprovalStagesOneReadOnlyCopyAndRedeemsWithoutPaths()
        throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try source(root)
        let staging = root.appendingPathComponent(
            "staging", isDirectory: true)
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: staging)
        let (approval, sessionID) = try approve(
            store, source: sourceURL)
        let staged = try XCTUnwrap(store.stagedURL(for: approval.receipt))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: staged.path)

        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o400)
        XCTAssertFalse(approval.receipt.contains(sourceURL.path))
        XCTAssertEqual(approval.destination, "Lab:Incoming")
        XCTAssertEqual(approval.conversion,
                       "UTF-8 → MacRoman, LF → CR")

        guard case .artifact(let artifact) = store.redeem(
            receipt: approval.receipt,
            sessionID: sessionID,
            redeemedAt: Date(timeIntervalSince1970: 1_001)) else {
            return XCTFail("a current immutable approval should redeem")
        }
        XCTAssertEqual(artifact.destination, "Lab:Incoming")
        XCTAssertEqual(artifact.source.bytes, 13)
        XCTAssertEqual(artifact.plan.bytes, Data("first\rsecond\r".utf8))
        XCTAssertNotEqual(
            artifact.source.sha256, artifact.handedToNOW.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let encoded = String(
            decoding: try JSONEncoder().encode(artifact.source),
            as: UTF8.self)
        XCTAssertFalse(encoded.contains(root.path))
        XCTAssertFalse(encoded.contains("CodeKitten"))
    }

    func testExpiredSessionAndReplayEmitNoReusableAuthority() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let sourceURL = try source(root)
        let (approval, sessionID) = try approve(
            store, source: sourceURL)

        guard case .expired(let expired) = store.redeem(
            receipt: approval.receipt,
            sessionID: sessionID,
            redeemedAt: Date(timeIntervalSince1970: 1_601)) else {
            return XCTFail("an approval older than ten minutes must expire")
        }
        XCTAssertEqual(expired.code, "now-artifact-approval-expired")
        guard case .refused(let replay) = store.redeem(
            receipt: approval.receipt,
            sessionID: sessionID) else {
            return XCTFail("an expired receipt must also be consumed")
        }
        XCTAssertEqual(replay.code, "now-artifact-already-redeemed")

        let second = try approve(store, source: sourceURL)
        guard case .expired(let changedSession) = store.redeem(
            receipt: second.0.receipt,
            sessionID: UUID(),
            redeemedAt: Date(timeIntervalSince1970: 1_001)) else {
            return XCTFail("a reconnect must expire the approval")
        }
        XCTAssertEqual(changedSession.code,
                       "now-artifact-session-expired")
    }

    func testSourceLinksDirectoriesAndOversizedFilesAreRefused()
        throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let plain = try source(root)
        let linkURL = root.appendingPathComponent("linked.txt")
        XCTAssertEqual(symlink(plain.path, linkURL.path), 0)
        let tooLarge = root.appendingPathComponent("large.bin")
        try Data(
            repeating: 0,
            count: AgentIntegrationArtifactPolicy.maximumSourceBytes + 1
        ).write(to: tooLarge)

        for url in [linkURL, root, tooLarge] {
            guard case .failure(.refused) = store.approve(
                sourceURL: url,
                destination: "",
                convertText: false,
                sessionID: UUID()) else {
                return XCTFail("\(url.lastPathComponent) must be refused")
            }
        }
    }

    func testSymlinkHardLinkAndChangedStageAreRefusedAtFinalOpen()
        throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let sourceURL = try source(root)

        let symlinkApproval = try approve(store, source: sourceURL)
        let symlinkStage = try XCTUnwrap(
            store.stagedURL(for: symlinkApproval.0.receipt))
        try FileManager.default.removeItem(at: symlinkStage)
        XCTAssertEqual(symlink(sourceURL.path, symlinkStage.path), 0)
        assertChanged(
            store.redeem(
                receipt: symlinkApproval.0.receipt,
                sessionID: symlinkApproval.1,
                redeemedAt: Date(timeIntervalSince1970: 1_001)))

        let hardLinkApproval = try approve(store, source: sourceURL)
        let hardLinkStage = try XCTUnwrap(
            store.stagedURL(for: hardLinkApproval.0.receipt))
        let alias = root.appendingPathComponent("alias")
        XCTAssertEqual(link(hardLinkStage.path, alias.path), 0)
        assertChanged(
            store.redeem(
                receipt: hardLinkApproval.0.receipt,
                sessionID: hardLinkApproval.1,
                redeemedAt: Date(timeIntervalSince1970: 1_001)))

        let changedApproval = try approve(store, source: sourceURL)
        let changedStage = try XCTUnwrap(
            store.stagedURL(for: changedApproval.0.receipt))
        XCTAssertEqual(chmod(changedStage.path, 0o600), 0)
        try Data("altered bytes".utf8).write(to: changedStage)
        XCTAssertEqual(chmod(changedStage.path, 0o400), 0)
        assertChanged(
            store.redeem(
                receipt: changedApproval.0.receipt,
                sessionID: changedApproval.1,
                redeemedAt: Date(timeIntervalSince1970: 1_001)))
    }

    func testApprovedTransferSettlesOnlyOnFileDoneAndCannotReplay()
        async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let adapter = AgentIntegrationHostAdapter(
            listener: listener,
            artifactApprovals: store)
        let sourceURL = try source(
            root, name: "Agent Note.txt",
            data: Data("hello\n".utf8))
        guard case .success(let approval) = adapter.approveArtifact(
            sourceURL: sourceURL,
            destination: "",
            convertText: true) else {
            return XCTFail("expected native host approval")
        }

        let task = Task { @MainActor in
            await adapter.transferApprovedArtifact(
                receipt: approval.receipt)
        }
        var offerID: Int?
        try await waitUntil("approved file offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerID = offer.id
                    // The source file was just written, so it carries a
                    // real (modern) modification date. This used to be
                    // nil unconditionally - not because the artifact
                    // lane omits dates by design, but because
                    // ClassicDate.guestWireSeconds stopped at Int32.max
                    // (~Jan 1972) and every modern date came back nil.
                    return offer.name == "Agent Note.txt"
                        && offer.path == ""
                        && offer.modified != nil
                        && offer.overwrite != true
                }
            }
            return false
        }
        let id = try XCTUnwrap(offerID)

        guard case .refused(let concurrent) =
                await adapter.transferApprovedArtifact(
                    receipt: approval.receipt) else {
            return XCTFail("a duplicate in-flight request must be refused")
        }
        XCTAssertEqual(concurrent.code, "now-artifact-transfer-busy")
        XCTAssertEqual(guest.received.filter {
            if case .fileOffer = $0 { return true }
            return false
        }.count, 1)

        try guest.send(.fileAccept(.init(id: id)))
        try await waitUntil("approved bytes and end") {
            guest.bulkReceived == Data("hello\r".utf8)
                && guest.received.contains {
                    if case .fileEnd(let end) = $0 {
                        return end.id == id && end.ok
                    }
                    return false
                }
        }
        XCTAssertFalse(task.isCancelled)
        try guest.send(.fileDone(.init(
            id: id, ok: true, code: nil, reason: nil)))

        guard case .delivered(let receipt) = await task.value else {
            return XCTFail("file.done ok:true should mint delivery receipt")
        }
        XCTAssertTrue(receipt.guestAcknowledgedWrite)
        XCTAssertFalse(receipt.destinationBytesVerified)
        XCTAssertEqual(receipt.source.bytes, 6)
        XCTAssertEqual(receipt.handedToNOW.bytes, 6)
        XCTAssertFalse(receipt.guestMessage.contains(root.path))

        let offersBeforeReplay = guest.received.filter {
            if case .fileOffer = $0 { return true }
            return false
        }.count
        guard case .refused(let replay) =
                await adapter.transferApprovedArtifact(
                    receipt: approval.receipt) else {
            return XCTFail("a delivered approval must not replay")
        }
        XCTAssertEqual(replay.code, "now-artifact-already-redeemed")
        let offersAfterReplay = guest.received.filter {
            if case .fileOffer = $0 { return true }
            return false
        }.count
        XCTAssertEqual(offersAfterReplay, offersBeforeReplay)
    }

    func testGuestFailureReturnsNoDeliveryReceipt() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let adapter = AgentIntegrationHostAdapter(
            listener: listener,
            artifactApprovals: store)
        let sourceURL = try source(root, name: "Failure.txt")
        guard case .success(let approval) = adapter.approveArtifact(
            sourceURL: sourceURL,
            destination: "",
            convertText: false) else {
            return XCTFail("expected approval")
        }
        let task = Task { @MainActor in
            await adapter.transferApprovedArtifact(
                receipt: approval.receipt)
        }
        var offerID: Int?
        try await waitUntil("file offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerID = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileRefuse(.init(
            id: try XCTUnwrap(offerID),
            code: "exists",
            reason: "HD:Secret:Failure.txt")))

        guard case .refused(let failure) = await task.value else {
            return XCTFail("a collision cannot mint a delivery receipt")
        }
        XCTAssertEqual(failure.code, "now-artifact-destination-exists")
        XCTAssertFalse(failure.message.contains("HD:"))
    }

    func testUnavailableGuestAndUnmintedReceiptEmitNoOffer() async throws {
        let listener = GuestListener(
            identity: .init(version: "test", name: "Host"))
        let root = try temporaryDirectory()
        defer {
            listener.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let adapter = AgentIntegrationHostAdapter(
            listener: listener,
            artifactApprovals: store)
        let sourceURL = try source(root)

        guard case .failure(.unavailable) = adapter.approveArtifact(
            sourceURL: sourceURL,
            destination: "",
            convertText: false) else {
            return XCTFail("approval requires a current paired guest")
        }
        guard case .unavailable(.guest) =
                await adapter.transferApprovedArtifact(
                    receipt: AgentIntegrationArtifactPolicy.makeReceipt())
        else {
            return XCTFail("transfer requires a current paired guest")
        }

        let (connected, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            connected.stop()
        }
        let connectedAdapter = AgentIntegrationHostAdapter(
            listener: connected,
            artifactApprovals: store)
        guard case .refused(let failure) =
                await connectedAdapter.transferApprovedArtifact(
                    receipt: AgentIntegrationArtifactPolicy.makeReceipt())
        else {
            return XCTFail("an unminted receipt must be refused")
        }
        XCTAssertEqual(failure.code, "now-artifact-approval-invalid")
        XCTAssertFalse(guest.received.contains {
            if case .fileOffer = $0 { return true }
            return false
        })
    }

    func testMissingFileDoneReturnsNoDeliveryReceipt() async throws {
        let (listener, guest) = try await connectedListener()
        defer {
            guest.connection.cancel()
            listener.stop()
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentIntegrationArtifactApprovalStore(
            rootURL: root.appendingPathComponent("staging"))
        let adapter = AgentIntegrationHostAdapter(
            listener: listener,
            artifactApprovals: store)
        let sourceURL = try source(root, name: "No Receipt.txt")
        guard case .success(let approval) = adapter.approveArtifact(
            sourceURL: sourceURL,
            destination: "",
            convertText: false) else {
            return XCTFail("expected approval")
        }
        let task = Task { @MainActor in
            await adapter.transferApprovedArtifact(receipt: approval.receipt)
        }
        var offerID: Int?
        try await waitUntil("file offer") {
            for message in guest.received {
                if case .fileOffer(let offer) = message {
                    offerID = offer.id
                    return true
                }
            }
            return false
        }
        try guest.send(.fileAccept(.init(id: try XCTUnwrap(offerID))))
        try await waitUntil("file end") {
            guest.received.contains {
                if case .fileEnd(let end) = $0 {
                    return end.id == offerID
                }
                return false
            }
        }
        listener.expireWatchdogsForTesting()

        guard case .failed(let failure) = await task.value else {
            return XCTFail("missing file.done cannot mint a receipt")
        }
        XCTAssertEqual(failure.code, "now-artifact-outcome-unknown")
    }

    private func assertChanged(
        _ result: AgentIntegrationArtifactRedemption,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .refused(let failure) = result else {
            return XCTFail(
                "changed staging must be refused", file: file, line: line)
        }
        XCTAssertEqual(
            failure.code, "now-artifact-staging-changed",
            file: file, line: line)
    }
}
