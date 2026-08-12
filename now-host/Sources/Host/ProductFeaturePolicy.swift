import Foundation

/// A runtime source may override a declared default without owning persistence
/// or presentation. Those decisions belong to the product surface that elects
/// to expose a particular flag.
protocol ProductFeatureFlagSource {
    func value(forFeatureFlag key: String) -> Bool?
}

struct DictionaryProductFeatureFlags: ProductFeatureFlagSource {
    var values: [String: Bool] = [:]

    func value(forFeatureFlag key: String) -> Bool? {
        values[key]
    }
}

enum ProductFeatureDisableReason: Equatable, Sendable {
    case unknownFeature(ProductFeatureID)
    case excludedFromProfile(profileID: String, note: String)
    case runtimeFlagDisabled(key: String)

    var explanation: String {
        switch self {
        case .unknownFeature(let id):
            return "The product profile has no definition for \(id.rawValue)."
        case .excludedFromProfile(let profileID, let note):
            return "Excluded from the \(profileID) release profile. \(note)"
        case .runtimeFlagDisabled(let key):
            return "The \(key) runtime feature flag is disabled."
        }
    }
}

enum ProductFeatureAdmission: Equatable, Sendable {
    case admitted
    case disabled(ProductFeatureDisableReason)

    var isEnabled: Bool {
        if case .admitted = self { return true }
        return false
    }

    var explanation: String? {
        guard case .disabled(let reason) = self else { return nil }
        return reason.explanation
    }
}

/// Resolves product admission only. GuestCapabilityGate remains the authority
/// for whether a connected classic Mac can serve an admitted feature.
struct ProductFeaturePolicy {
    private let profileID: String
    private let definitions: [ProductFeatureID: ProductFeatureDefinition]
    private let flags: any ProductFeatureFlagSource

    init(
        profileID: String = GeneratedProductFeatures.activeProfileID,
        definitions: [ProductFeatureID: ProductFeatureDefinition] =
            GeneratedProductFeatures.byID,
        flags: any ProductFeatureFlagSource = DictionaryProductFeatureFlags()
    ) {
        self.profileID = profileID
        self.definitions = definitions
        self.flags = flags
    }

    func resolve(_ id: ProductFeatureID) -> ProductFeatureAdmission {
        guard let definition = definitions[id] else {
            return .disabled(.unknownFeature(id))
        }
        guard definition.releaseState != .excluded else {
            return .disabled(.excludedFromProfile(
                profileID: profileID,
                note: definition.releaseNote))
        }

        switch definition.runtimeBinding {
        case .intrinsic, .capabilityNegotiated:
            return .admitted
        case .flag(let key, let defaultEnabled):
            let enabled = flags.value(forFeatureFlag: key) ?? defaultEnabled
            return enabled ? .admitted : .disabled(.runtimeFlagDisabled(key: key))
        }
    }
}
