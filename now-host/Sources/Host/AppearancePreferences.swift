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

struct LiquidGlassPreference: Equatable, Sendable {
    enum NativeStyle: Equatable, Sendable {
        case material
        case clear
        case regular
    }

    static let material = LiquidGlassPreference(amount: 0)
    static let clear = LiquidGlassPreference(amount: 0.5)
    static let regular = LiquidGlassPreference(amount: 1)

    let amount: Double

    init(amount: Double) {
        self.amount = amount.isFinite ? min(max(amount, 0), 1) : 1
    }

    /// Apple exposes identity/material, clear, and regular glass rather than
    /// an intensity parameter. The person's value remains continuous and is
    /// persisted exactly; rendering selects the nearest native material.
    var nativeStyle: NativeStyle {
        switch amount {
        case ..<0.25: .material
        case ..<0.75: .clear
        default: .regular
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
        static let legacyLiquidGlass = "appearance.liquidGlass"
        static let liquidGlassAmount = "appearance.liquidGlassAmount"
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
            defaults.set(liquidGlass.amount, forKey: Key.liquidGlassAmount)
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
        if defaults.object(forKey: Key.liquidGlassAmount) != nil {
            liquidGlass = LiquidGlassPreference(
                amount: defaults.double(forKey: Key.liquidGlassAmount))
        } else if let legacy = defaults.object(
            forKey: Key.legacyLiquidGlass) as? Int,
                  (0...2).contains(legacy) {
            liquidGlass = LiquidGlassPreference(amount: Double(legacy) / 2)
        } else {
            liquidGlass = .regular
        }
        applyAppearance(theme.appearance)
    }

}
