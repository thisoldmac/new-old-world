import Foundation

/// **Which clock the ops in `Scene.Window.display` came off, and whether
/// they still describe the window this scene is about.**
///
/// The render used to pair "the latest scene" with "the latest drained
/// content" and call the result a frame. Those are two clocks. The scene
/// arrives on a ~1.9 s structural poll; the content arrives on the guest's
/// own drain, stamped with the guest's `generation` (which moves on every
/// re-arm) and `displayEpoch` (which moves when the application redraws its
/// window afresh). Nothing made the pair coherent, and nothing could even
/// ask, because the display ops reached the renderer with no epoch at all.
///
/// This is the missing stamp. It is HOST-INTERNAL render state — like
/// `Scene.Window.island` it is deliberately absent from `CodingKeys`, so it
/// never reaches the wire and the frozen IR is unaffected. Every value in it
/// is already carried by the drain records the guest sends; no contract
/// field was needed for any of it.
///
/// ## What `stale` means, and what it deliberately does NOT mean
///
/// `stale` is true when the guest has begun drawing a NEWER epoch for this
/// window than the one these ops belong to — a repaint we have seen the
/// front of and not the whole of — or when an offscreen world that
/// contributed pixels to these ops has since been disposed (`worlddied`).
/// In both cases the pixels are the last COHERENT frame and are still worth
/// drawing; what they have lost is the right to speak for the window.
/// `ProvenanceLadder` demotes them from rung 1 accordingly, so a semantic
/// row underneath them may answer instead of being silenced by pixels that
/// describe a window state the machine has left.
///
/// **It is not "content is missing".** Content is absent by design far more
/// often than it is late: record mode off, an application never armed, a
/// window with no plane at all. A window with no `displayEpoch` is a window
/// with no content stream, and it renders semantics-only, immediately. The
/// coherence gate applies only where a stream exists — otherwise "hold the
/// last coherent frame" would become "hold forever waiting for content that
/// is not coming", which is a worse instability than the one it was added
/// to cure.
public struct DisplayEpoch: Equatable, Sendable {
    /// The guest's capture generation these ops were recorded under. Moves
    /// on every re-arm, which is also when a hooked offscreen world is
    /// released — so it is half of a source's identity, not decoration.
    public var generation: Int
    /// The guest's own display epoch for this window.
    public var epoch: Int
    /// The structural scene sequence this display was last joined against.
    /// Carried so a reader can say how far the two clocks have drifted; the
    /// gate itself never uses it, because drift between a settled display
    /// and a newer scene is the NORMAL state of a healthy session.
    public var sceneSequence: Int
    /// The guest has started a newer epoch for this window, or a world
    /// these pixels were composed from has been disposed.
    public var stale: Bool

    public init(generation: Int, epoch: Int, sceneSequence: Int,
                stale: Bool) {
        self.generation = generation
        self.epoch = epoch
        self.sceneSequence = sceneSequence
        self.stale = stale
    }

    /// Strictly-newer ordering: generation first, then the guest's epoch.
    public static func isNewer(generation lg: Int, epoch le: Int,
                               thanGeneration rg: Int, epoch re: Int) -> Bool {
        lg > rg || (lg == rg && le > re)
    }
}
