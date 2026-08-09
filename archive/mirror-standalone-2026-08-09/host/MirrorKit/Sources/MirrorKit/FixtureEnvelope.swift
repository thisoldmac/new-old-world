import Foundation

/// A capture envelope — the on-disk fixture format (`*.raw.json`) and the
/// input `make-fixtures.py` feeds the oracle. Decoding one yields the same
/// scene the live poller would build, with the clock and counters injected.
public enum FixtureEnvelope {
    public enum EnvelopeError: Error, CustomStringConvertible {
        case notAnObject
        case missingResult
        case unknownSource(String)

        public var description: String {
            switch self {
            case .notAnObject: return "envelope is not a JSON object"
            case .missingResult: return "envelope has no result"
            case .unknownSource(let s): return "unknown source \(s)"
            }
        }
    }

    /// Envelope JSON → Scene, via the same SceneBuilder path the poller uses.
    public static func scene(from data: Data) throws -> Scene {
        guard let envelope = try JSONSerialization
            .jsonObject(with: data) as? [String: Any] else {
            throw EnvelopeError.notAnObject
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw EnvelopeError.missingResult
        }
        let source = envelope["source"] as? String ?? "?"
        let seq = SceneBuilder.intValue(envelope["seq"]) ?? 0
        let screenDict = envelope["screen"] as? [String: Any] ?? [:]
        let screen = Scene.ScreenSize(
            w: SceneBuilder.intValue(screenDict["w"]) ?? 0,
            h: SceneBuilder.intValue(screenDict["h"]) ?? 0)
        let capturedAt = (envelope["capturedAt"] as? NSNumber)?
            .doubleValue ?? 0
        let latencyMs = (envelope["latencyMs"] as? NSNumber)?.doubleValue
        let bytes = SceneBuilder.intValue(envelope["bytes"])

        switch source {
        case "axtree":
            return SceneBuilder.sceneFromAxtree(
                result, seq: seq, screen: screen, capturedAt: capturedAt,
                latencyMs: latencyMs, bytes: bytes)
        case "observe":
            return SceneBuilder.sceneFromObserve(
                result, seq: seq, screen: screen, capturedAt: capturedAt,
                latencyMs: latencyMs, bytes: bytes)
        default:
            throw EnvelopeError.unknownSource(source)
        }
    }
}
