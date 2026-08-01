import CryptoKit
import Foundation
import NOWAgentIntegration

/// The host's half of the agent scene lane: ask the paired guest for one
/// Mirror IR walk through the existing listener, gate its major version, and
/// hand the raw document out one page at a time.
///
/// It owns no listener lifecycle and no scene policy of its own. The request
/// is `GuestListener.requestScene` — the same call the Mirror page's Fetch
/// button makes, with the same watchdog — and this control adds only the
/// staging: a document rarely fits one 16 KiB local response, so it is held
/// briefly and read out in pages, exactly as `AgentIntegrationCaptureControl`
/// does for a screen.
///
/// **Unlike capture, there is no defensive busy pre-check here.**
/// `requestCapture` overwrites its own pending completion, which is why
/// `AgentIntegrationCaptureControl` has to guard the lane itself before
/// asking; `requestScene` REFUSES a concurrent call instead (its own header
/// argues why), so this control can simply ask and translate whatever comes
/// back — the lane guard already lives on the other side of this call.
///
/// **And there is no abandon.** The contract states plainly that a scene
/// transfer is short enough that cancelling it costs more than finishing
/// it — there is no `scene.cancel` to fall back on, so this surface does not
/// invent a local-only "stop waiting" that the guest has no way to honour.
@MainActor
final class AgentIntegrationSceneControl {
    /// One scene, staged for the pages of the call that took it.
    private struct Stage {
        let facts: AgentIntegrationSceneFacts
        let document: Data
        let stagedAt: Date
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date
    private var stage: Stage?

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
    }

    // MARK: - Taking one

    func scene(staleAfterMs: Int?) async -> AgentIntegrationSceneResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        let delivery = await withCheckedContinuation { continuation in
            listener.requestScene(staleAfterMs: staleAfterMs) {
                continuation.resume(returning: $0)
            }
        }
        /* Re-read rather than trusted, for the reason capture's own control
           states: the request took real time on a classic Mac, and a
           session that ended or changed underneath it means this document
           describes a machine nobody asked about. */
        guard currentSessionID() == sessionID else {
            stage = nil
            return .guestUnavailable
        }

        switch delivery {
        case .failure(let failure):
            return .refused(.guestFailed(failure.message))
        case .success(let scene):
            /* The gate, before anything about the body is trusted — the
               same order `NOWSceneCodec.decode` states and this control
               repeats rather than calls, because it only needs the major
               number and not a structural decode: this surface pages raw
               bytes through to an agent caller, who parses the JSON
               itself, and re-deciding what the guest's absent keys mean by
               decoding here would risk exactly the crash class a real
               captured scene once produced against MirrorKit's stricter
               Codable model. */
            guard NOWSceneVersion.isSupported(scene.irVersion) else {
                return .refused(.unsupportedMajor(scene.irVersion))
            }
            guard scene.document.count
                <= AgentIntegrationScenePolicy.maximumBytes else {
                return .refused(.tooLarge)
            }
            let facts = AgentIntegrationSceneFacts(
                sceneID: UUID(),
                sessionID: sessionID,
                observedAt: clock(),
                irVersion: scene.irVersion,
                seq: scene.seq,
                source: scene.source,
                walkMs: scene.walkMs,
                transferMs: scene.transferMs,
                bytes: scene.document.count,
                sha256: Self.hex(SHA256.hash(data: scene.document)))
            stage = Stage(facts: facts, document: scene.document,
                          stagedAt: clock())
            return page(sceneID: facts.sceneID, offset: 0)
        }
    }

    // MARK: - Reading it out

    func page(sceneID: UUID, offset: Int) -> AgentIntegrationSceneResult {
        guard let sessionID = currentSessionID() else {
            stage = nil
            return .guestUnavailable
        }
        guard let current = stage,
              current.facts.sceneID == sceneID,
              current.facts.sessionID == sessionID,
              clock().timeIntervalSince(current.stagedAt)
                <= AgentIntegrationScenePolicy.stageLifetime else {
            /* A stage that has expired is dropped here rather than left to
               be found again — the same reasoning capture's own page
               method states. */
            if let current = stage,
               clock().timeIntervalSince(current.stagedAt)
                   > AgentIntegrationScenePolicy.stageLifetime {
                stage = nil
            }
            return .refused(.stale)
        }
        guard offset >= 0, offset < current.document.count,
              offset % AgentIntegrationScenePolicy.pageBytes == 0 else {
            return .refused(.init(
                code: "now-scene-offset-invalid",
                message: "\(offset) is not a page boundary inside this "
                    + "scene's \(current.document.count) bytes"))
        }
        let end = min(offset + AgentIntegrationScenePolicy.pageBytes,
                      current.document.count)
        let bytes = current.document[offset..<end]
        /* The last page drops the stage on its way out, for capture's exact
           reason: holding it for a retry would mean holding every scene any
           agent ever took until its two minutes were up. */
        if end == current.document.count { stage = nil }
        return .captured(.init(
            facts: current.facts,
            page: .init(offset: offset,
                        base64: Data(bytes).base64EncodedString())))
    }

    // MARK: - Letting go of the lane

    /// Drops any staged document. Called when the connection goes: the next
    /// guest is not this one.
    func forgetGuest() {
        stage = nil
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String
        where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
