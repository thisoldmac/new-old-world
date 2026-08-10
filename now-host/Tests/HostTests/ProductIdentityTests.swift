import XCTest
@testable import Host

final class ProductIdentityTests: XCTestCase {
    func testReleaseVersionCopiesMatchTheContractAuthority() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let header = try String(contentsOf: root
            .appendingPathComponent("contract/product_version.h"))
        let regex = try NSRegularExpression(
            pattern: #"#define NOW_PRODUCT_VERSION \"([^\"]+)\""#)
        let match = try XCTUnwrap(regex.firstMatch(
            in: header, range: NSRange(header.startIndex..., in: header)))
        let expected = String(header[Range(match.range(at: 1),
                                           in: header)!])
        XCTAssertEqual(ProductIdentity.version, expected)

        let resource = try String(contentsOf: root.appendingPathComponent(
            "now-guest-ppc/resources/app.r"))
        XCTAssertTrue(resource.contains("\"\(expected)\""))
        let project = try String(contentsOf: root.appendingPathComponent(
            "now-host/NewOldWorld.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("MARKETING_VERSION = \(expected);"))
        let fallbackPlist = try String(contentsOf: root.appendingPathComponent(
            "scripts/HostInfo.plist.in"))
        XCTAssertTrue(fallbackPlist.contains("<string>\(expected)</string>"))

        // AsyncAPI's info.version describes the contract document. The
        // handshake is gated by info.x-contract-revision. Neither is the
        // product release identity, even when their strings coincide.
        let contract = try String(contentsOf: root.appendingPathComponent(
            "contract/asyncapi.yaml"))
        XCTAssertTrue(contract.contains("x-contract-revision: "))
    }
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
