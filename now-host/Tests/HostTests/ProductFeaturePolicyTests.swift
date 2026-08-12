import XCTest
@testable import Host

final class ProductFeaturePolicyTests: XCTestCase {
    func testCurrentProfilePreservesRuntimeBehavior() {
        let policy = ProductFeaturePolicy()

        XCTAssertEqual(policy.resolve(.classicPowerPC), .admitted)
        XCTAssertEqual(policy.resolve(.residentExtension), .admitted)
        guard case .disabled(.excludedFromProfile(let profile, let note)) =
                policy.resolve(.classicPreCarbon) else {
            return XCTFail("pre-Carbon support must be excluded by the active profile")
        }
        XCTAssertEqual(profile, "alpha")
        XCTAssertTrue(note.contains("stale"))
    }

    func testFlagOverrideAdmitsAnIncludedCompiledFeature() {
        let definition = ProductFeatureDefinition(
            id: .classicPreCarbon,
            title: "Pre-Carbon support",
            releaseState: .included,
            releaseNote: "Included by the test profile.",
            runtimeBinding: .flag(key: "classic.pre-carbon", defaultEnabled: false))
        let policy = ProductFeaturePolicy(
            profileID: "test",
            definitions: [.classicPreCarbon: definition],
            flags: DictionaryProductFeatureFlags(
                values: ["classic.pre-carbon": true]))

        XCTAssertEqual(policy.resolve(.classicPreCarbon), .admitted)
    }

    func testMissingOverrideUsesDeclaredDefaultAndNamesTheFlag() {
        let definition = ProductFeatureDefinition(
            id: .classicPreCarbon,
            title: "Pre-Carbon support",
            releaseState: .included,
            releaseNote: "Included by the test profile.",
            runtimeBinding: .flag(key: "classic.pre-carbon", defaultEnabled: false))
        let decision = ProductFeaturePolicy(
            profileID: "test",
            definitions: [.classicPreCarbon: definition])
            .resolve(.classicPreCarbon)

        XCTAssertEqual(decision, .disabled(
            .runtimeFlagDisabled(key: "classic.pre-carbon")))
        XCTAssertTrue(decision.explanation?.contains("classic.pre-carbon") == true)
    }

    func testReleaseExclusionOutranksAFlagOverride() {
        let policy = ProductFeaturePolicy(
            flags: DictionaryProductFeatureFlags(
                values: ["classic.pre-carbon": true]))

        guard case .disabled(.excludedFromProfile) =
                policy.resolve(.classicPreCarbon) else {
            return XCTFail("a runtime override must not add a profile-excluded feature")
        }
    }

    func testCapabilityNegotiatedBindingIsAdmittedForSeparateGuestResolution() {
        let decision = ProductFeaturePolicy().resolve(.residentExtension)

        XCTAssertEqual(decision, .admitted)
        XCTAssertNil(decision.explanation)
    }

    func testGeneratedStableIDsAreUniqueAndComplete() {
        XCTAssertEqual(Set(ProductFeatureID.allCases.map(\.rawValue)).count,
                       ProductFeatureID.allCases.count)
        XCTAssertEqual(Set(GeneratedProductFeatures.byID.keys),
                       Set(ProductFeatureID.allCases))
        XCTAssertEqual(ProductFeatureID.classicPreCarbon.rawValue,
                       "classic.pre-carbon")
    }
}
