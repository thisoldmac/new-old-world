import Foundation

/// One disk-capacity answer for both private MCP transfer directions.
///
/// Foundation may report no important-usage capacity on a volume that still
/// has ordinary free space. Keeping the selection here prevents upload and
/// download from disagreeing about whether the same private directory can
/// hold bytes.
enum PrivateStagingCapacity {
    static func availableBytes(at root: URL) throws -> Int64? {
        let values = try root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        return availableBytes(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            ordinary: values.volumeAvailableCapacity.map(Int64.init))
    }

    static func availableBytes(
        importantUsage: Int64?, ordinary: Int64?
    ) -> Int64? {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        if let ordinary, ordinary >= 0 {
            return ordinary
        }
        return nil
    }
}
