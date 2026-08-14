import SwiftUI

/// Pure policy behind the visual modifiers. Keeping runtime and accessibility
/// fallback here makes the macOS 13 path testable without pretending a build
/// has exercised an older OS.
enum GlassSelection {
    static func resolve(preference: LiquidGlassPreference,
                        supportsLiquidGlass: Bool,
                        reduceTransparency: Bool,
                        increasedContrast: Bool) -> LiquidGlassPreference {
        guard supportsLiquidGlass,
              !reduceTransparency,
              !increasedContrast else { return .material }
        return preference
    }
}

private struct LiquidGlassPreferenceKey: EnvironmentKey {
    static let defaultValue = LiquidGlassPreference.regular
}

extension EnvironmentValues {
    var nowLiquidGlassPreference: LiquidGlassPreference {
        get { self[LiquidGlassPreferenceKey.self] }
        set { self[LiquidGlassPreferenceKey.self] = newValue }
    }
}

/// Re-publishes a changed preference into SwiftUI's value environment without
/// requiring feature views to know where host settings are stored.
struct GlassPreferenceScope<Content: View>: View {
    @ObservedObject var preferences: AppearancePreferences
    let content: Content

    var body: some View {
        content.environment(\.nowLiquidGlassPreference,
                            preferences.liquidGlass)
    }
}

/// The app's glass vocabulary — three words, stated once.
///
/// macOS 26 draws chrome in Liquid Glass, and the temptation is to sprinkle
/// `.glassEffect` at each call site. That way the app ends up with six
/// slightly different corner radii and no answer to "does this respect
/// Reduce Transparency?" — and, on a 13.0 floor, no answer to "what does
/// this look like on Ventura?" either. Both questions have to be asked at
/// every site, and it only takes one site forgetting for the app to stop
/// building or the setting to stop meaning anything. So both choices are
/// made here, once, and call sites stay unconditional.
///
/// **Two switches, and they are independent.** One asks whether the machine
/// *can* draw glass — a compiler new enough to contain the API and
/// `#available(macOS 26, *)`, a fact about the OS the person is running. The
/// other asks whether the person *wants* to see it — Reduce Transparency or
/// Increase Contrast, a preference that can flip while the app is running.
/// Neither implies the other: a macOS 26 machine with Reduce Transparency
/// on must not get glass, and a Ventura machine with every accessibility
/// setting off still cannot have it. Collapsing them into one flag loses
/// whichever case the flag was not named after.
///
/// **Glass is for chrome that floats over content**, not for every surface.
/// A module's own body is not chrome; restyling those is not what this file
/// is for.
///
/// The fallback is not "render nothing" — it is the material look this app
/// had before, which is why each modifier below names the exact material it
/// falls back to rather than dropping the background entirely. That matters
/// beyond taste: the sidebar footer is a `safeAreaInset` that rows scroll
/// *underneath*, so an inset that lost its background would put text on top
/// of text. Both paths keep one.
extension View {
    /// A floating card: the placeholder pane, an overlay, anything that
    /// reads as sitting *above* the window's content.
    func nowGlassPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(NowGlassPanel(cornerRadius: cornerRadius))
    }

    /// An attached strip — such as the sidebar footer — that content
    /// scrolls underneath.
    func nowGlassBar() -> some View {
        modifier(NowGlassBar())
    }

    /// A control that sits *on* chrome rather than inside a form. Do not
    /// reach for this inside a `nowGlassBar`: glass over glass is the one
    /// thing the material is documented not to survive.
    func nowGlassButton() -> some View {
        modifier(NowGlassButton())
    }

    /// A quiet navigation surface for a shelf row. Shelves are destinations,
    /// not source-list group headers, so they keep ordinary row semantics and
    /// use a restrained material difference to communicate containment.
    func nowGlassShelf(cornerRadius: CGFloat = 8) -> some View {
        modifier(NowGlassShelf(cornerRadius: cornerRadius))
    }
}

/// Whether the person has asked the system to stop rendering translucency.
///
/// Two settings, not one. Reduce Transparency is the obvious one; Increase
/// Contrast also suppresses glass system-wide, and an app that honours only
/// the first looks like it ignored the second.
///
/// Deliberately says nothing about the OS version — that is the other
/// switch, and a helper that answered both would make it impossible to see
/// at a call site which one refused.
private struct NowGlassPanel: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nowLiquidGlassPreference) private var preference

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                     style: .continuous)
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            switch GlassSelection.resolve(
                preference: preference,
                supportsLiquidGlass: true,
                reduceTransparency: reduce,
                increasedContrast: contrast == .increased) {
            case .material:
                content.background(.regularMaterial, in: shape)
            case .clear:
                content.glassEffect(.clear, in: shape)
            case .regular:
                content.glassEffect(.regular, in: shape)
            }
        } else {
            // The same shape, so the card's silhouette does not change when
            // only its material does.
            content.background(.regularMaterial, in: shape)
        }
#else
        // Xcode 16's SDK does not declare glassEffect, so runtime
        // availability alone cannot make this branch compile there.
        content.background(.regularMaterial, in: shape)
#endif
    }
}

private struct NowGlassBar: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nowLiquidGlassPreference) private var preference

    @ViewBuilder
    func body(content: Content) -> some View {
        /* A bar is edge-to-edge, so the shape is the rectangle it already
           occupies — rounding it would leave the window's corners showing
           through at the ends of a strip that is meant to be part of the
           frame.

           Both arms are backgrounds, never nothing: this modifier's callers
           are safe-area insets with rows scrolling under them. */
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            switch GlassSelection.resolve(
                preference: preference,
                supportsLiquidGlass: true,
                reduceTransparency: reduce,
                increasedContrast: contrast == .increased) {
            case .material:
                content.background(.bar)
            case .clear:
                content.glassEffect(.clear, in: Rectangle())
            case .regular:
                content.glassEffect(.regular, in: Rectangle())
            }
        } else {
            content.background(.bar)
        }
#else
        content.background(.bar)
#endif
    }
}

private struct NowGlassButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nowLiquidGlassPreference) private var preference

    @ViewBuilder
    func body(content: Content) -> some View {
        /* `.bordered` rather than `.borderless` as the fallback: the glass
           style draws a capsule a person can aim at, and dropping to a bare
           label would change the control's hit target as well as its look —
           neither an old OS nor an accessibility setting may make a button
           harder to click. */
#if compiler(>=6.2)
        if #available(macOS 26, *),
           GlassSelection.resolve(
                preference: preference,
                supportsLiquidGlass: true,
                reduceTransparency: reduce,
                increasedContrast: contrast == .increased) != .material {
            /* SwiftUI's native glass button style does not expose the
               clear/regular material choice. It still follows Off versus On;
               panels and bars show the two SDK-supported glass materials. */
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
#else
        content.buttonStyle(.bordered)
#endif
    }
}

private struct NowGlassShelf: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduce
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nowLiquidGlassPreference) private var preference

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius,
                                     style: .continuous)
#if compiler(>=6.2)
        if #available(macOS 26, *),
           GlassSelection.resolve(
               preference: preference,
               supportsLiquidGlass: true,
               reduceTransparency: reduce,
               increasedContrast: contrast == .increased) != .material {
            // Clear glass keeps a shelf quieter than the floating panels and
            // bars around it while still letting macOS own its material.
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
#else
        content.background(.thinMaterial, in: shape)
#endif
    }
}
