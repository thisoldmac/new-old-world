/// Compares HTTP credentials without returning at the first differing byte.
/// The API-key and MCP bearer routes share this trust-boundary primitive.
func constantTimeSecretEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8), right = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
        difference |= (index < left.count ? left[index] : 0)
            ^ (index < right.count ? right[index] : 0)
    }
    return difference == 0
}
