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
    public let pressed: SceneRenderer.PressedControl?

    public init(scene: MirrorKit.Scene, openMenu: Int? = nil,
                hoveredItem: Int? = nil, selectedItem: String? = nil,
                dragOutline: Rect? = nil,
                itemDrag: SceneRenderer.ProvisionalDrag? = nil,
                pressed: SceneRenderer.PressedControl? = nil) {
        self.scene = scene
        self.openMenu = openMenu
        self.hoveredItem = hoveredItem
        self.selectedItem = selectedItem
        self.dragOutline = dragOutline
        self.itemDrag = itemDrag
        self.pressed = pressed
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            SceneRenderer(scene: scene, openMenu: openMenu,
                          hoveredItem: hoveredItem,
                          selectedItem: selectedItem,
                          dragOutline: dragOutline,
                          itemDrag: itemDrag,
                          pressed: pressed)
                .draw(in: ctx, size: size)
        }
        .background(Color(hex: 0x222222))
    }
}

/// Render-screenshot, the offscreen half: scene → Canvas → PNG with no
/// window at all. This rasterizes ONLY the mirror's own drawing — it is a
/// screenshot of the *render*, not the guest framebuffer and not the host
/// screen.
@MainActor
public enum RenderShot {
    public static func png(scene: MirrorKit.Scene,
                           openMenu: Int? = nil,
                           hoveredItem: Int? = nil,
                           selectedItem: String? = nil,
                           itemDrag: SceneRenderer.ProvisionalDrag? = nil,
                           pressed: SceneRenderer.PressedControl? = nil,
                           size: CGSize? = nil) throws -> Data {
        let size = size ?? SceneRenderer(scene: scene).logicalSize
        let view = SceneView(scene: scene, openMenu: openMenu,
                             hoveredItem: hoveredItem,
                             selectedItem: selectedItem,
                             itemDrag: itemDrag, pressed: pressed)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            throw RenderShotError.rasterizeFailed
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderShotError.encodeFailed
        }
        return png
    }

    public enum RenderShotError: Error {
        case rasterizeFailed
        case encodeFailed
    }
}
