import SwiftUI

struct HostSettingsView: View {
    @ObservedObject var preferences: AppearancePreferences

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                LiquidGlassSettings(preferences: preferences)
                GlassPreview()
            }
        }
        .formStyle(.grouped)
        .environment(\.nowLiquidGlassPreference, preferences.liquidGlass)
    }

}

private struct LiquidGlassSettings: View {
    @ObservedObject var preferences: AppearancePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Liquid Glass")
                Spacer()
                Text(preferences.liquidGlass.amount,
                     format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: glassAmount, in: 0...1)
                .accessibilityLabel("Liquid Glass")
                .accessibilityValue(Text(
                    preferences.liquidGlass.amount,
                    format: .percent.precision(.fractionLength(0))))
            HStack {
                Text("Off")
                Spacer()
                Text("Clear")
                Spacer()
                Text("Regular")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var glassAmount: Binding<Double> {
        Binding {
            preferences.liquidGlass.amount
        } set: { value in
            preferences.liquidGlass = LiquidGlassPreference(amount: value)
        }
    }
}

private struct GlassPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Window chrome")
                    .fontWeight(.medium)
                Text("Accessibility settings can replace glass with material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .nowGlassPanel(cornerRadius: 12)
    }
}
