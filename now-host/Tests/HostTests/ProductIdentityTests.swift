import XCTest
@testable import Host

final class ProductIdentityTests: XCTestCase {
    /// The shipped app must be unaffected: no env var, no change. This is
    /// the case that matters — a suffix leaking into a normal launch would
    /// silently orphan every setting on a real desk.
    func testNormalLaunchUsesTheBaseSuite() {
        XCTAssertNil(ProcessInfo.processInfo.environment["NOW_PREFS_SUFFIX"],
                     "the test process must not itself be suffixed")
        XCTAssertEqual(ProductIdentity.preferencesSuite,
                       ProductIdentity.basePreferencesSuite)
    }

    /// A suite may not equal the bundle id — UserDefaults rejects that, and
    /// the suffixed form must stay distinct from it too.
    func testSuiteIsNeverTheBundleIdentifier() {
        XCTAssertNotEqual(ProductIdentity.basePreferencesSuite,
                          ProductIdentity.bundleIdentifier)
        XCTAssertTrue(
            ProductIdentity.basePreferencesSuite
                .hasPrefix(ProductIdentity.bundleIdentifier + "."),
            "the suite should sit under the bundle id, not beside it")
    }

    /// The suffixed suite has to be a real, openable domain — a name that
    /// UserDefaults refuses would send every isolated run to `.standard`,
    /// which is the desk's own preferences and the exact thing this hook
    /// exists to keep out of.
    func testSuffixedSuiteIsOpenable() throws {
        let name = "\(ProductIdentity.basePreferencesSuite).unit-test"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }

        defaults.set(4242, forKey: "port")
        XCTAssertEqual(defaults.integer(forKey: "port"), 4242)
        XCTAssertNotEqual(name, ProductIdentity.basePreferencesSuite)
    }
}
