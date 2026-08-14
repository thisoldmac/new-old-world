import AppKit
import XCTest
@testable import Host

@MainActor
final class AppearancePreferencesTests: XCTestCase {
    func testThemeAndGlassPersistAndApplyImmediately() throws {
        let suite = "AppearancePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        var applied: [NSAppearance.Name?] = []

        let preferences = AppearancePreferences(defaults: defaults) {
            applied.append($0?.name)
        }

        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.liquidGlass, .regular)
        XCTAssertEqual(applied, [nil], "the saved theme applies at startup")

        preferences.theme = .dark
        preferences.liquidGlass = .clear

        XCTAssertEqual(applied, [nil, .darkAqua],
                       "theme changes apply without reopening a window")
        let restored = AppearancePreferences(defaults: defaults) { _ in }
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.liquidGlass, .clear)
    }

    func testGlassAmountMovesContinuouslyAndPersistsExactValue() throws {
        let suite = "AppearancePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let preferences = AppearancePreferences(defaults: defaults) { _ in }

        preferences.liquidGlass = LiquidGlassPreference(amount: 0.37)

        XCTAssertEqual(preferences.liquidGlass.amount, 0.37,
                       accuracy: 0.000_001)
        let restored = AppearancePreferences(defaults: defaults) { _ in }
        XCTAssertEqual(restored.liquidGlass.amount, 0.37,
                       accuracy: 0.000_001)
    }

    func testLegacyThreeStopGlassPreferenceMigratesToTheSameNativeStyle()
        throws {
        let suite = "AppearancePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removeSuite(named: suite) }
        defaults.set(1, forKey: "appearance.liquidGlass")

        let preferences = AppearancePreferences(defaults: defaults) { _ in }

        XCTAssertEqual(preferences.liquidGlass, .clear)
        XCTAssertEqual(preferences.liquidGlass.amount, 0.5)
    }

    func testEffectiveGlassFallsBackForRuntimeAndAccessibility() {
        XCTAssertEqual(
            GlassSelection.resolve(preference: .regular,
                                   supportsLiquidGlass: true,
                                   reduceTransparency: false,
                                   increasedContrast: false),
            .regular)
        XCTAssertEqual(
            GlassSelection.resolve(preference: .clear,
                                   supportsLiquidGlass: true,
                                   reduceTransparency: false,
                                   increasedContrast: false),
            .clear)
        for preference in [LiquidGlassPreference.material, .clear, .regular,
                           LiquidGlassPreference(amount: 0.37)] {
            XCTAssertEqual(
                GlassSelection.resolve(preference: preference,
                                       supportsLiquidGlass: false,
                                       reduceTransparency: false,
                                       increasedContrast: false),
                .material)
            XCTAssertEqual(
                GlassSelection.resolve(preference: preference,
                                       supportsLiquidGlass: true,
                                       reduceTransparency: true,
                                       increasedContrast: false),
                .material)
            XCTAssertEqual(
                GlassSelection.resolve(preference: preference,
                                       supportsLiquidGlass: true,
                                       reduceTransparency: false,
                                       increasedContrast: true),
                .material)
        }
    }

    func testSettingsMenuOwnsOneReusableWindow() throws {
        let delegate = quietAppDelegate("SettingsWindow")
        let mainMenu = delegate.makeMainMenu()
        let appMenu = try XCTUnwrap(mainMenu.items.first {
            $0.title == ProductIdentity.displayName
        }?.submenu)
        let item = try XCTUnwrap(appMenu.items.first {
            $0.title == "Settings…"
        })
        XCTAssertEqual(item.action, #selector(AppDelegate.showSettings))
        XCTAssertEqual(item.keyEquivalent, ",")

        delegate.showSettings()
        let firstController = try XCTUnwrap(delegate.settingsWindowController)
        let firstWindow = try XCTUnwrap(firstController.window)

        delegate.showSettings()

        XCTAssertTrue(firstController === delegate.settingsWindowController)
        XCTAssertTrue(firstWindow === delegate.settingsWindowController?.window)
        XCTAssertEqual(firstWindow.title, "Settings")
        firstWindow.close()
    }
}
