import Foundation

/// The scene IR's version stamp and the compatibility gate that guards it.
///
/// **One number, two places, and they are the same number.** A consumer sees it
/// as `result["irVersion"]` — a top-level key of `mirror.scene` and
/// `mirror.attach`, beside the payload rather than inside it, so the gate is
/// readable *without* decoding the thing it guards. The scene body also carries
/// `Scene.version`, the IR's self-stamp, which is what the fixture corpus pins.
/// Both are `IR.version`; `SceneBuilder` stamps the body and `Serve` copies it
/// into the envelope, so they cannot diverge without a compile-time edit.
///
/// ## What v1 means
///
/// - **Frozen:** the field set of the encoded scene, enumerated in
///   `IRSchema.v1Frozen` / `IRSchema.v1FrozenProperties`. `IRFreezeTests` goes
///   red the moment the produced shape stops matching, which is the whole
///   point of the freeze.
/// - **Additive within v1:** a new field is recorded in `IRSchema.v1Additions`.
///   The major does not move; old consumers keep working because they ignore
///   keys they do not know.
/// - **Removing or renaming a field moves the major.** `v1Frozen` is a
///   literal-and-final list: a diff that deletes a line from it is the
///   reviewable signal that someone broke a promise instead of extending one.
///
/// ## What a consumer must do
///
/// Read `irVersion` first, refuse an unknown *major*, and only then decode.
/// `MirrorScene.decode(result:)` is that consumer, written in that order.
public enum IR {

    /// The current IR version. Single integer, so version == major: an
    /// additive change keeps this number, a removal or rename moves it.
    public static let version = 1

    /// Majors this build can consume. A newer producer is refused, not
    /// best-efforted — a scene whose shape we cannot vouch for is worse than
    /// no scene, because the failure is silent and downstream.
    public static let supportedMajors: Set<Int> = [1]

    public enum CompatError: Error, Equatable, CustomStringConvertible {
        /// No `irVersion` at all. A pre-freeze producer, or not a mirror reply.
        case missingVersion
        /// A major this build does not support.
        case unknownMajor(Int)
        /// `irVersion` was present but not an integer.
        case malformedVersion(String)
        /// The version gate passed but the payload did not decode.
        case malformedScene(String)

        public var description: String {
            switch self {
            case .missingVersion:
                return "reply carries no irVersion (pre-freeze producer?)"
            case .unknownMajor(let v):
                return "unsupported IR major \(v); this build speaks "
                    + IR.supportedMajors.sorted().map(String.init)
                        .joined(separator: ", ")
            case .malformedVersion(let s):
                return "irVersion is not an integer: \(s)"
            case .malformedScene(let s):
                return "scene payload did not decode: \(s)"
            }
        }
    }

    /// The gate. Give it the raw `result["irVersion"]` value; it returns the
    /// major on success and throws on anything it cannot vouch for.
    ///
    /// Deliberately strict about the *type* as well as the value: a producer
    /// that sends `"1"` is not a producer we have ever tested against, and
    /// coercing it here would be inventing agreement.
    @discardableResult
    public static func requireSupportedMajor(_ raw: Any?) throws -> Int {
        guard let raw, !(raw is NSNull) else { throw CompatError.missingVersion }
        guard let number = raw as? NSNumber,
              // NSNumber wraps Bool too; `true` is not version 1.
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else {
            throw CompatError.malformedVersion(String(describing: raw))
        }
        let major = number.intValue
        guard supportedMajors.contains(major) else {
            throw CompatError.unknownMajor(major)
        }
        return major
    }
}

/// The host-side consumer of a `mirror.scene` reply — the code path the
/// compatibility gate exists for.
///
/// Order matters and is the contract: **check the version, then decode.** A
/// consumer that parses first and checks second has already run the unknown
/// shape through its decoder before deciding whether it was allowed to.
public enum MirrorScene {

    /// Decode a `mirror.scene` result (`{scene: …, irVersion: n}`).
    /// Throws `IR.CompatError` before touching the payload.
    public static func decode(result: [String: Any]) throws -> Scene {
        try IR.requireSupportedMajor(result["irVersion"])
        guard let body = result["scene"] else {
            throw IR.CompatError.malformedScene("no scene key")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            return try JSONDecoder().decode(Scene.self, from: data)
        } catch let error as IR.CompatError {
            throw error
        } catch {
            throw IR.CompatError.malformedScene("\(error)")
        }
    }

    /// Gate a `mirror.attach` result. Attach carries no scene — only the
    /// version — so this is the gate alone, run at session start where a
    /// mismatch is cheapest to act on.
    @discardableResult
    public static func acceptAttach(result: [String: Any]) throws -> Int {
        try IR.requireSupportedMajor(result["irVersion"])
    }
}
