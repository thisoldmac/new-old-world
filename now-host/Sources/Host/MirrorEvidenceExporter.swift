import Foundation
import MirrorKit

/// Writes the native Mirror frame and the exact engine projection it displayed
/// as one correlated observation. It owns neither guest capture nor actuation;
/// those remain separate evidence sources joined by the strict gate.
@MainActor
final class MirrorEvidenceExporter {
    enum ExportError: Error, Equatable {
        case noSnapshot
        case emptyFrame
        case visibleProjectionMismatch
        case snapshotChanged
    }

    struct StateArtifact: Codable, Equatable {
        var schema: String
        var snapshotId: String
        var guest: String
        var session: String
        var sequence: Int
        var sceneGeneration: Int
        var contentGeneration: Int
        var digest: String
        var baseComplete: Bool
        var scene: Scene
    }

    struct Export {
        var snapshotId: String
        var capturedAt: Date
        var frameURL: URL
        var stateURL: URL
    }

    private let engine: MirrorStateEngine
    private let visibleScene: (() -> Scene?)?

    init(engine: MirrorStateEngine,
         visibleScene: (() -> Scene?)? = nil) {
        self.engine = engine
        self.visibleScene = visibleScene
    }

    func export(to directory: URL, framePNG: () throws -> Data) throws
        -> Export {
        guard let before = engine.snapshot else { throw ExportError.noSnapshot }
        if let visibleScene, visibleScene() != before.scene {
            throw ExportError.visibleProjectionMismatch
        }
        let png = try framePNG()
        guard !png.isEmpty else { throw ExportError.emptyFrame }
        guard let after = engine.snapshot,
              after.id == before.id,
              after.session == before.session,
              after.digest == before.digest,
              after.sceneGeneration == before.sceneGeneration,
              after.contentGeneration == before.contentGeneration,
              visibleScene.map({ $0() == after.scene }) ?? true else {
            throw ExportError.snapshotChanged
        }

        let snapshotId = Self.snapshotID(before)
        let artifact = StateArtifact(
            schema: "now-mirror-state-evidence/v1",
            snapshotId: snapshotId,
            guest: before.session.guest,
            session: before.session.incarnation,
            sequence: before.sequence,
            sceneGeneration: before.sceneGeneration,
            contentGeneration: before.contentGeneration,
            digest: before.digest,
            baseComplete: before.baseComplete,
            scene: before.scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let state = try encoder.encode(artifact)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let frameURL = directory.appendingPathComponent(
            "mirror-\(before.id).png")
        let stateURL = directory.appendingPathComponent(
            "state-\(before.id).json")
        try png.write(to: frameURL, options: .atomic)
        do {
            try state.write(to: stateURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: frameURL)
            throw error
        }
        return .init(snapshotId: snapshotId, capturedAt: Date(),
                     frameURL: frameURL, stateURL: stateURL)
    }

    static func snapshotID(_ projection: MirrorProjection) -> String {
        "\(projection.session.guest)-\(projection.session.incarnation)-"
            + "\(projection.id)"
    }
}
