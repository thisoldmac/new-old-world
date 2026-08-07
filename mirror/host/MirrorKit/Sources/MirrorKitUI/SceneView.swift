import SwiftUI
import MirrorKit

/// The Canvas wrapper both heads of the renderer share: the live window
/// displays it; the render-screenshot rasterizes it offscreen. One draw
/// path, one set of pixels (MIRRORKIT-PLAN decision 7).
public struct SceneView: View {
    public let scene: MirrorKit.Scene
    public let openMenu: Int?
    public let hoveredItem: Int?
    public let selectedItem: String?
    public let dragOutline: Rect?
    public let itemDrag: SceneRenderer.ProvisionalDrag?

    public init(scene: MirrorKit.Scene, openMenu: Int? = nil,
                hoveredItem: Int? = nil, selectedItem: String? = nil,
                dragOutline: Rect? = nil,
                itemDrag: SceneRenderer.ProvisionalDrag? = nil) {
        self.scene = scene
        self.openMenu = openMenu
        self.hoveredItem = hoveredItem
        self.selectedItem = selectedItem
        self.dragOutline = dragOutline
        self.itemDrag = itemDrag
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            SceneRenderer(scene: scene, openMenu: openMenu,
                          hoveredItem: hoveredItem,
                          selectedItem: selectedItem,
                          dragOutline: dragOutline,
                          itemDrag: itemDrag)
                .draw(in: ctx, size: size)
        }
        .background(Color(hex: 0x222222))
    }
}

/// Render-screenshot, the offscreen half: scene → Canvas → PNG with no
/// window at all. This rasterizes ONLY the mirror's own drawing — it is a
/// screenshot of the *render*, not the guest framebuffer and not the host
/// screen.
///
/// **One scene must always give one picture, and for a while it did not.**
/// Asking `ImageRenderer` for its own `cgImage` does not give the same pixels
/// for the same view on the first few rasterizations in a process. Measured
/// 2026-08-07: eight pixels of a two-button fixture move between a process's
/// first render and its settled one — seven by 1/255 on antialiased control
/// edges, one by 15/255 on the grow box's diagonal hatch. Every pixel-exact
/// render test in this tree was passing because it was not the first render
/// in its process, which is luck, and it inverts the day someone reorders a
/// file or runs one test alone.
///
/// **It is not our lazy state, and it is not a cache we can warm.** Resolving
/// `AssetPack.status`, `FontBook`, `DesktopPattern.answer` and `IconAtlas`
/// before the first render changes nothing; a `Canvas` containing no
/// MirrorKit code at all — a tiled 2×2 decorative image, a stroked rounded
/// rect, a diagonal — drifts the same way; and *when* it settles moves with
/// wall-clock time and not only with the count, so no fixed number of
/// throwaway renders would be a fix either. Warming would have hidden the
/// symptom and left the fragility exactly where it was.
///
/// **So the shot does not use ImageRenderer's context.** `render(_:)` hands
/// the drawing to a `CGContext` of the caller's choosing, and a bitmap
/// context we create ourselves is stable from its very first rasterization —
/// zero differing pixels over eight consecutive shots in a cold process,
/// across runs. Whatever ImageRenderer configures lazily in its own backing
/// store, we no longer inherit it. This is the load-order dependence
/// removed rather than papered over, and it costs one rasterization per
/// shot, the same as before.
///
/// **It also changes the picture, and not only by a rounding step.** Against
/// the old settled image, 1471 of that fixture's 57600 pixels move: 1141 by
/// one or two steps, the rest — up to 213/255 — on glyph interiors and 1px
/// frames. Flat fills are untouched, so palette assertions read what they
/// read; what changes is how a hairline lands. Our own 1:1 bitmap draws them
/// CRISPLY where ImageRenderer's buffer drew them soft: the semantic
/// checkbox's frame went from a pair of heavy bars with washed-out sides to
/// a clean square. For a mirror of a machine whose whole interface is 1px
/// Platinum rules that is a gain, not a cost — but it is a change to what
/// every render test samples, and exactly one assertion in the tree was
/// pinned to a glyph pixel that moved (`IslandRenderTests`, re-derived in
/// the same commit). The host's 1858 tests were unaffected.
///
/// The live window is NOT this path — it draws through `SceneView` into the
/// window's own backing store, at device scale. This is the offscreen half
/// only: tests, `writeRenderShot`, and the serve endpoint.
@MainActor
public enum RenderShot {
    /// The scene as pixels, in a context we own. See the type's note.
    public static func cgImage(scene: MirrorKit.Scene,
                               openMenu: Int? = nil,
                               hoveredItem: Int? = nil,
                               selectedItem: String? = nil,
                               itemDrag: SceneRenderer.ProvisionalDrag? = nil,
                               size: CGSize? = nil) throws -> CGImage {
        /* No size and no guest screen is a REFUSAL, not a default. A picture
           rendered at an invented surface is indistinguishable from one
           rendered at the real screen, and it is the picture an agent
           reasons about. The guard moved down here with round 8's merge:
           `png` now delegates, so this is the one place both callers pass
           through. */
        guard let size = size ?? SceneRenderer(scene: scene).logicalSize else {
            throw RenderShotError.screenUnknown
        }
        let view = SceneView(scene: scene, openMenu: openMenu,
                             hoveredItem: hoveredItem,
                             selectedItem: selectedItem,
                             itemDrag: itemDrag)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        var made: CGImage?
        renderer.render { pixelSize, draw in
            /* sRGB, 8 bits, premultiplied — the same description
               ImageRenderer's own image carried, so this is a change of WHO
               owns the buffer and not of what the picture is in. */
            guard let ctx = CGContext(
                data: nil,
                width: max(1, Int(pixelSize.width.rounded())),
                height: max(1, Int(pixelSize.height.rounded())),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            draw(ctx)
            made = ctx.makeImage()
        }
        guard let made else { throw RenderShotError.rasterizeFailed }
        return made
    }

    public static func png(scene: MirrorKit.Scene,
                           openMenu: Int? = nil,
                           hoveredItem: Int? = nil,
                           selectedItem: String? = nil,
                           itemDrag: SceneRenderer.ProvisionalDrag? = nil,
                           size: CGSize? = nil) throws -> Data {
        let image = try cgImage(scene: scene, openMenu: openMenu,
                                hoveredItem: hoveredItem,
                                selectedItem: selectedItem,
                                itemDrag: itemDrag, size: size)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderShotError.encodeFailed
        }
        return png
    }

    public enum RenderShotError: Error {
        /// The scene carries no `screen` and the caller named no size, so
        /// there is no surface to render onto. Unknown, not empty.
        case screenUnknown
        case rasterizeFailed
        case encodeFailed
    }
}
