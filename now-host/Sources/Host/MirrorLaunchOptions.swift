import Foundation

/// Deterministic sizing for direct-input gates. Normal launches still fit the
/// guest once and then leave the window to the person; `--mirror-scale` pins
/// the guest canvas to an explicit uniform scale so screenshot coordinates do
/// not depend on the capture tool resizing a window taller than its output.
///
/// `--open-mirror` exists for the headless client. The Mirror's poll, its
/// state engine and every measurement it publishes only begin when the window
/// opens, so until now an agent reading `now_semantic_ui_metrics` could get an
/// honest empty answer that no call of its own could ever change — the one
/// state a headless run cannot get itself out of. Opening at launch is not a
/// second mechanism: it is the same `NOWMirrorWindow.show` a click performs.
struct MirrorLaunchOptions: Equatable {
    var scale: CGFloat?
    var openAtLaunch: Bool = false

    static func parse(_ arguments: [String]) -> MirrorLaunchOptions {
        var options = MirrorLaunchOptions(
            scale: nil, openAtLaunch: arguments.contains("--open-mirror"))
        if let index = arguments.firstIndex(of: "--mirror-scale"),
           arguments.indices.contains(index + 1),
           let raw = Double(arguments[index + 1]),
           (0.5...1.0).contains(raw) {
            options.scale = CGFloat(raw)
        }
        return options
    }
}
