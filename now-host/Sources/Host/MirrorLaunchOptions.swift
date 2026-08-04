import Foundation

/// Deterministic sizing for direct-input gates. Normal launches still fit the
/// guest once and then leave the window to the person; `--mirror-scale` pins
/// the guest canvas to an explicit uniform scale so screenshot coordinates do
/// not depend on the capture tool resizing a window taller than its output.
struct MirrorLaunchOptions: Equatable {
    var scale: CGFloat?

    static func parse(_ arguments: [String]) -> MirrorLaunchOptions {
        guard let index = arguments.firstIndex(of: "--mirror-scale"),
              arguments.indices.contains(index + 1),
              let raw = Double(arguments[index + 1]),
              (0.5...1.0).contains(raw) else {
            return .init(scale: nil)
        }
        return .init(scale: CGFloat(raw))
    }
}
