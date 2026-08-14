import SwiftUI

/// The Files module's containment vocabulary.
///
/// These values describe hierarchy rather than individual views: the module
/// pane, ordinary controls, and row selection each have one silhouette and
/// one spacing scale. Floating controls still get material from `GlassStyle`;
/// attached bars stay visually continuous with their pane.
enum FilesStyle {
    static let outerSurfaceCornerRadius: CGFloat = 12
    static let controlCornerRadius: CGFloat = 10
    static let rowSelectionCornerRadius: CGFloat = 7

    static let chromeHorizontalPadding: CGFloat = 10
    static let controlHorizontalPadding: CGFloat = 8
    static let controlVerticalPadding: CGFloat = 5
    static let rowHorizontalPadding: CGFloat = 7
    static let rowVerticalPadding: CGFloat = 5
    static let controlHeight: CGFloat = 30

    static var outerSurfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: outerSurfaceCornerRadius,
                         style: .continuous)
    }

    static var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: controlCornerRadius,
                         style: .continuous)
    }

    static var rowSelectionShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: rowSelectionCornerRadius,
                         style: .continuous)
    }
}

extension View {
    /// Makes one browser target read as a complete native surface. The shared
    /// root applies this once, so guest and host always keep the same outline.
    func filesPaneSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
            .clipShape(FilesStyle.outerSurfaceShape)
            .overlay {
                FilesStyle.outerSurfaceShape
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }

    /// Attached title and navigation rows should belong to the browser, not
    /// float above it. Finder keeps the attached toolbar as a native bar and
    /// reserves Liquid Glass for the controls that float on it; doing the same
    /// also avoids nesting glass effects.
    func filesPaneChrome() -> some View {
        background(.bar)
    }
}
