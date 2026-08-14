import SwiftUI

/// Product maturity comes from `ModuleDescriptor.tier`; navigation surfaces
/// render that one authority instead of recognizing individual module IDs.
struct ModuleTierBadge: View {
    let tier: ModuleTier
    var selected = false

    @ViewBuilder
    var body: some View {
        switch tier {
        case .core:
            EmptyView()
        case .experimental:
            badge("Experimental", tint: .orange)
        case .debug:
            badge("Debug", tint: .purple)
        }
    }

    private func badge(_ title: LocalizedStringKey, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(selected
                             ? Color(nsColor: .alternateSelectedControlTextColor)
                             : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(selected
                    ? Color.white.opacity(0.16)
                    : tint.opacity(0.12)))
    }
}
