import Foundation

/// **What the guest will tell its Finder it is about to receive.**
///
/// The promise skeleton for `continuity.hostDragBegin`, derived from the
/// SAME `OutboundFile.Plan` the offer is published with — never from a
/// second look at the file. That is the property worth having: the guest
/// advertises `flavorTypePromiseHFS` from these numbers, the Finder sizes
/// its own copy from them, and the bytes that later arrive are the plan's
/// bytes. Two independent derivations of "how big is this file" is how a
/// promise ends up lying to the receiver about what it is promising.
///
/// The forks are described AS THEY WILL ARRIVE, not as they sit on this
/// Mac. A plan whose container is `data` sends the data fork alone, so
/// `rsrcSize` is 0 even for a file with a resource fork here; a `macbinary`
/// plan sends both, and the two lengths are read out of the header that is
/// about to travel rather than re-measured on disk.
enum ContinuityHostDragSkeleton {

    /// MacBinary II header offsets for the two fork lengths (big-endian
    /// `UInt32` each). Named rather than spelled inline because the same
    /// two numbers decide what the Finder reserves.
    private enum MacBinary {
        static let headerBytes = 128
        static let dataLengthOffset = 83
        static let rsrcLengthOffset = 87
    }

    static func item(for plan: OutboundFile.Plan)
        -> ContinuityHostDragBegin.Item {
        let forks = forkSizes(for: plan)
        return ContinuityHostDragBegin.Item(
            name: plan.name, type: plan.fileType, creator: plan.creator,
            dataSize: forks.data, rsrcSize: forks.rsrc)
    }

    /// Exposed for the gate next door: the fork arithmetic is the part of
    /// this that can be wrong in a way nothing else notices.
    static func forkSizes(for plan: OutboundFile.Plan)
        -> (data: Int, rsrc: Int) {
        guard plan.container == "macbinary" else {
            return (plan.bytes.count, 0)
        }
        guard plan.bytes.count >= MacBinary.headerBytes,
              let data = bigEndianUInt32(plan.bytes,
                                         at: MacBinary.dataLengthOffset),
              let rsrc = bigEndianUInt32(plan.bytes,
                                         at: MacBinary.rsrcLengthOffset)
        else {
            /* A container this side named `macbinary` whose header will not
               read is not a reason to refuse the handoff — the bytes still
               travel and the guest still rebuilds both forks. What is lost
               is the SPLIT, so say the whole length as data and claim no
               resource fork rather than inventing a division. */
            return (plan.bytes.count, 0)
        }
        /* Sanity, not trust: a header claiming more than the file holds is
           a corrupt header, and a Finder that reserved from it would fail
           the copy for a reason nobody could see. */
        let total = Int(data) + Int(rsrc)
        guard total <= plan.bytes.count else {
            return (plan.bytes.count, 0)
        }
        return (Int(data), Int(rsrc))
    }

    private static func bigEndianUInt32(_ bytes: Data, at offset: Int)
        -> UInt32? {
        guard offset >= 0, bytes.count >= offset + 4 else { return nil }
        let start = bytes.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(bytes[start + index])
        }
        return value
    }
}
