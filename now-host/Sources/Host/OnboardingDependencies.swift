import CryptoKit
import Foundation

struct OnboardingDependency: Identifiable, Equatable {
    enum Delivery: Equatable {
        case unchanged
        case macBinary(classicName: String, type: String, creator: String)
    }

    let id: String
    let displayName: String
    let detail: String
    let downloadFileName: String
    let acceptedNameFragments: [String]
    let downloadURL: URL
    let sourcePageURL: URL
    let expectedSHA1: String
    let delivery: Delivery

    func installedAsset(in snapshot: OnboardingAssetSnapshot)
        -> OnboardingAsset? {
        snapshot.dependencies.filter(matches).min { left, right in
            deliveryRank(left) < deliveryRank(right)
        }
    }

    func matches(_ asset: OnboardingAsset) -> Bool {
        let name = asset.fileName.lowercased()
        return acceptedNameFragments.contains {
            name.contains($0.lowercased())
        }
    }

    private func deliveryRank(_ asset: OnboardingAsset) -> Int {
        let name = asset.fileName.lowercased()
        return name.contains(".sit") || name.contains(".hqx") ? 1 : 0
    }
}

enum OnboardingDependencyCatalog {
    static let carbonLib = OnboardingDependency(
        id: "carbonlib-1.6.1",
        displayName: "CarbonLib 1.6.1",
        detail: "Required by New Old World on classic Mac OS",
        downloadFileName: "CarbonLib_161.sit.bin",
        acceptedNameFragments: ["carbonlib"],
        downloadURL: URL(
            string: "https://old.mac.gdn/apps/CarbonLib_161.sit")!,
        sourcePageURL: URL(
            string: "http://macintoshgarden.org/apps/carbonlib")!,
        expectedSHA1: "8a80248cb9acd2b26a3c7cf7af5dbde56b96fa3e",
        delivery: .macBinary(classicName: "CarbonLib_161.sit",
                             type: "SIT5", creator: "SIT!"))

    static let all = [carbonLib]

    static func additionalAssets(in snapshot: OnboardingAssetSnapshot)
        -> [OnboardingAsset] {
        snapshot.dependencies.filter { asset in
            !all.contains { $0.matches(asset) }
        }
    }

    /// The guest-bound dependency set. The starter-pack manifest is host
    /// validation metadata, not a classic payload, so it never crosses.
    static func setupAssets(in snapshot: OnboardingAssetSnapshot)
        -> [OnboardingAsset] {
        (all.compactMap { $0.installedAsset(in: snapshot) }
            + additionalAssets(in: snapshot))
            .filter {
                !DevelopmentStarterPackManifest.isManifestFileName(
                    $0.fileName)
            }
    }
}

@MainActor
struct OnboardingDependencyAcquirer {
    enum AcquisitionError: LocalizedError {
        case badResponse
        case couldNotEncode
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "The download server did not return the package."
            case .couldNotEncode:
                return "The downloaded package could not be prepared for "
                    + MachineNaming.simpleReference + "."
            case .checksumMismatch(let expected, let actual):
                return "The downloaded file did not match its published "
                    + "checksum (expected \(expected), got \(actual))."
            }
        }
    }

    typealias Loader = (URL) async throws -> Data
    let loader: Loader

    static func live(session: URLSession = .shared)
        -> OnboardingDependencyAcquirer {
        OnboardingDependencyAcquirer { url in
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                throw AcquisitionError.badResponse
            }
            return data
        }
    }

    func acquire(_ dependency: OnboardingDependency,
                 catalog: OnboardingAssetCatalog) async throws -> URL {
        let data = try await loader(dependency.downloadURL)
        let actual = Self.sha1Hex(data)
        guard actual == dependency.expectedSHA1.lowercased() else {
            throw AcquisitionError.checksumMismatch(
                expected: dependency.expectedSHA1, actual: actual)
        }
        let delivered: Data
        switch dependency.delivery {
        case .unchanged:
            delivered = data
        case .macBinary(let classicName, let type, let creator):
            guard let encoded = MacBinaryEncoder.data(
                name: classicName, type: type, creator: creator,
                dataFork: data) else {
                throw AcquisitionError.couldNotEncode
            }
            delivered = encoded
        }
        let directory = try catalog.prepareDependenciesRoot()
        let destination = directory.appendingPathComponent(
            dependency.downloadFileName, isDirectory: false)
        try delivered.write(to: destination, options: [.atomic])
        return destination
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
