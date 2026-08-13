import AppKit
import Combine
import Foundation

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum LiquidGlassPreference: Int, CaseIterable, Identifiable {
    case material
    case clear
    case regular

    var id: Self { self }

    var title: String {
        switch self {
        case .material: "Off"
        case .clear: "Clear"
        case .regular: "Regular"
        }
    }
}

/// Appearance preferences belong to the host application, not to a module.
/// Applying the theme in the model keeps every settings-window and launch
/// path on the same immediate behaviour.
@MainActor
final class AppearancePreferences: ObservableObject {
    private enum Key {
        static let theme = "appearance.theme"
        static let liquidGlass = "appearance.liquidGlass"
    }

    @Published var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyAppearance(theme.appearance)
        }
    }

    @Published var liquidGlass: LiquidGlassPreference {
        didSet {
            guard liquidGlass != oldValue else { return }
            defaults.set(liquidGlass.rawValue, forKey: Key.liquidGlass)
        }
    }

    private let defaults: UserDefaults
    private let applyAppearance: (NSAppearance?) -> Void

    convenience init(defaults: UserDefaults = ProductIdentity.defaults) {
        self.init(defaults: defaults) {
            NSApplication.shared.appearance = $0
        }
    }

    init(defaults: UserDefaults,
         applyAppearance: @escaping (NSAppearance?) -> Void) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        theme = defaults.string(forKey: Key.theme)
            .flatMap(AppTheme.init(rawValue:)) ?? .system
        liquidGlass = LiquidGlassPreference(
            rawValue: defaults.object(forKey: Key.liquidGlass) as? Int ?? -1)
            ?? .regular
        applyAppearance(theme.appearance)
    }

}
