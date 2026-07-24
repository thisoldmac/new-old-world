import Foundation

/// One canonical path below NOW's configured agent guest root.
///
/// This is not a host path. It uses the guest contract's colon-separated HFS
/// spelling and rejects every alternate spelling rather than normalizing one
/// potentially surprising path into another.
struct GuestFilePath: Equatable, Hashable, Sendable {
    static let maximumSegmentBytes = 31
    static let maximumWireBytes = 223

    let wireValue: String
    let components: [String]

    init(_ value: String) throws {
        if value.isEmpty {
            wireValue = ""
            components = []
            return
        }
        guard !value.hasPrefix("/"), !value.hasPrefix(":"),
              !value.hasSuffix(":") else {
            throw ValidationError.invalid
        }
        let parts = value.components(separatedBy: ":")
        guard !parts.isEmpty else { throw ValidationError.invalid }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  !part.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7F
                  }),
                  let bytes = part.data(
                    using: .macOSRoman, allowLossyConversion: false),
                  bytes.count <= Self.maximumSegmentBytes else {
                throw ValidationError.invalid
            }
        }
        guard let wireBytes = value.data(
            using: .macOSRoman, allowLossyConversion: false),
              wireBytes.count <= Self.maximumWireBytes else {
            throw ValidationError.invalid
        }
        wireValue = value
        components = parts
    }

    /// Only for values already validated and stored by this type.
    init(unchecked value: String) {
        wireValue = value
        components = value.isEmpty
            ? [] : value.components(separatedBy: ":")
    }

    func appending(to root: GuestFilePath) throws -> GuestFilePath {
        guard !root.wireValue.isEmpty else { return self }
        guard !wireValue.isEmpty else { return root }
        return try GuestFilePath(root.wireValue + ":" + wireValue)
    }

    var parent: GuestFilePath {
        guard components.count > 1 else {
            return GuestFilePath(unchecked: "")
        }
        return GuestFilePath(
            unchecked: components.dropLast().joined(separator: ":"))
    }

    var leaf: String? { components.last }

    enum ValidationError: Error {
        case invalid
    }
}
