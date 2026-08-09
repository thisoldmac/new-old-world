import Foundation

/// A live scrollbar thumb uses the same resident press/move/release vehicle
/// as an item drag, but it names the Finder window rather than pretending the
/// thumb is a draggable file. A source without that vehicle leaves this nil.
@MainActor
public protocol ScrollbarDragDriver: AnyObject {
    func thumbPress(windowID: String, at point: Point,
                    answer: @escaping (ItemDragAnswer) -> Void)
    func thumbMove(to point: Point)
    func thumbRelease(answer: @escaping (ItemDragAnswer) -> Void)
}
