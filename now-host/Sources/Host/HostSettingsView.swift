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

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Liquid Glass")
                        Spacer()
                        Text(preferences.liquidGlass.title)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: glassValue, in: 0...2, step: 1)
                        .accessibilityLabel("Liquid Glass")
                        .accessibilityValue(preferences.liquidGlass.title)
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

                glassPreview
            }
        }
        .formStyle(.grouped)
        .environment(\.nowLiquidGlassPreference, preferences.liquidGlass)
    }

    private var glassValue: Binding<Double> {
        Binding {
            Double(preferences.liquidGlass.rawValue)
        } set: { value in
            preferences.liquidGlass = LiquidGlassPreference(
                rawValue: Int(value.rounded())) ?? .regular
        }
    }

    private var glassPreview: some View {
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
