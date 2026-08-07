import SwiftUI

/// **What `ImageRenderer` can and cannot see, and the one place the
/// Mirror's layout bends for it.**
///
/// `MirrorModuleLayoutRenderTests` reviews this module's layout offscreen
/// in half a second, which is the only reason a person got to look at
/// three candidates at all. The loop has a hard limit, and round one was
/// misread because of it: a `VSplitView` was found to return the
/// prohibited placeholder, and **a `ScrollView` is worse — it renders as
/// nothing whatsoever, silently.** Round one's inspector column came out
/// blank in all three candidate pictures and was read as "the cards have
/// no data", which was true and was not the whole story. Measured on
/// 2026-08-07, at the sizes that loop uses:
///
/// | furniture                    | offscreen                    |
/// |------------------------------|------------------------------|
/// | `VStack`, `Divider`, `Text`  | draws                        |
/// | `DisclosureGroup`, `Form`    | draws                        |
/// | `Picker(.menu)`, `.radioGroup`| draws                       |
/// | `Button`, `Toggle`, `LabeledContent` | draws                |
/// | **`ScrollView`**             | **draws NOTHING at all**     |
/// | `List`                       | prohibited placeholder       |
/// | `TabView`                    | prohibited placeholder       |
/// | `Picker(.segmented)`         | prohibited placeholder       |
/// | `Menu` (borderless)          | prohibited placeholder       |
/// | `VSplitView`                 | prohibited placeholder       |
///
/// Two things follow. **A component the renderer cannot see is a reason
/// to prefer another one**, because choosing it means only a person
/// sitting at the machine can ever review this module again — that is
/// why the panel switcher here is a disclosure and not a segmented
/// control. And where scrolling is genuinely required — the diagnostics
/// are longer than any column — the container becomes reviewable rather
/// than the design becoming unscrollable.
///
/// `MirrorScrollBox` is that container. In the product it is a
/// `ScrollView` and nothing has changed. Under review it is a plain
/// stack, so the renderer draws the whole of the content at its natural
/// height — which is what a reviewer wanted from a scroller anyway.
///
/// **This is a rig affordance living in production code and it should be
/// read as one.** The alternative was a design constrained by an
/// instrument, which is the wrong way round.
struct MirrorScrollBox<Content: View>: View {
    @Environment(\.mirrorRenderingForReview) private var review
    var showsIndicators: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        if review {
            /* A `GeometryReader` rather than a plain stack, and this is
               the whole subtlety: a stack taller than its box reports
               that height to its parent, so an over-long diagnostics
               column pushed the toolbar off the top of the frame — a
               review picture missing the controls it was taken to show.
               A `GeometryReader` consumes exactly the size it is
               proposed and lets its child overflow without affecting
               anything around it, so the picture shows the top of the
               content, clipped, which is what an unscrolled `ScrollView`
               shows at rest. */
            GeometryReader { proxy in
                VStack(spacing: 0) { content }
                    .frame(width: proxy.size.width, alignment: .top)
            }
            .clipped()
        } else {
            ScrollView(showsIndicators: showsIndicators) { content }
        }
    }
}

private struct MirrorReviewRenderingKey: EnvironmentKey {
    /// False everywhere but the render tests. A default of true would
    /// ship a module that does not scroll.
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set only by `MirrorModuleLayoutRenderTests`.
    var mirrorRenderingForReview: Bool {
        get { self[MirrorReviewRenderingKey.self] }
        set { self[MirrorReviewRenderingKey.self] = newValue }
    }
}
