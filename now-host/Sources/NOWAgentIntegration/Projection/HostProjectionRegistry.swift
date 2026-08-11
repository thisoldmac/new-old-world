import Foundation

/// Every host projection, in declaration order, indexed by capability.
///
/// The order is the order faces present them, so it is a decision rather
/// than an accident of how a literal happened to be typed. Two rows
/// claiming one capability is a programming error, and it fails **loudly**
/// — a silent winner would mean one face reaching a capability the next one
/// does not, which is precisely the drift the parity work is for.
/// Sendable by construction: `byCapability` is filled once with stateless
/// projection metatypes and is never mutated after `init` returns.
public struct HostProjectionRegistry: @unchecked Sendable {
    /// Two rows, one capability. Named rather than counted, because the
    /// useful half of this failure is which name collided.
    public struct DuplicateCapability: Error, CustomStringConvertible {
        public let capability: HostCapabilityID

        public var description: String {
            "Two host projections claim the capability "
                + "\"\(capability.rawValue)\". A capability is registered "
                + "exactly once; one of the two rows would otherwise win "
                + "silently and the other would be unreachable."
        }
    }

    /// Declaration order.
    public let projections: [any HostProjection.Type]
    private let byCapability: [HostCapabilityID: any HostProjection.Type]

    public init(_ projections: [any HostProjection.Type]) throws {
        var index: [HostCapabilityID: any HostProjection.Type] = [:]
        for projection in projections {
            let capability = projection.capability
            guard index[capability] == nil else {
                throw DuplicateCapability(capability: capability)
            }
            index[capability] = projection
        }
        self.projections = projections
        byCapability = index
    }

    public var capabilities: [HostCapabilityID] {
        projections.map { $0.capability }
    }

    public static let catalogVersion = 1

    /// Stable FNV-1a over the sorted JSON descriptors. This is a compatibility
    /// identity, not a security primitive: equal values mean both processes
    /// compiled the same callable surface.
    public var catalogDigest: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for projection in projections {
            var descriptor = projection.mcpDescriptor
            descriptor["name"] = projection.capability.rawValue
            guard let data = try? JSONSerialization.data(
                withJSONObject: descriptor, options: [.sortedKeys]) else { continue }
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(format: "%016llx", hash)
    }

    public subscript(capability: HostCapabilityID)
        -> (any HostProjection.Type)? {
        byCapability[capability]
    }

    /// Lookup by the name a caller sent. Unknown names are a caller error,
    /// not a lookup failure to paper over.
    public func projection(named name: String)
        -> (any HostProjection.Type)? {
        byCapability[HostCapabilityID(name)]
    }

    /// The one registry every host face reads.
    ///
    /// `try!` on purpose: a duplicate row cannot be recovered from at run
    /// time and must not be survivable, so it takes the process down naming
    /// the capability rather than leaving a face quietly short of one.
    /// `HostProjectionRegistryTests` builds the same catalog and asserts it
    /// does not throw, so the trap is not the first place anyone finds out.
    public static let hostFaces =
        try! HostProjectionRegistry(HostProjectionCatalog.projections)
}
