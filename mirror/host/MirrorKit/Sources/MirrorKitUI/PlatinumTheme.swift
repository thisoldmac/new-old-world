import SwiftUI

/// Platinum asset pack, ported from `attic/web/platinum.css` — which in turn
/// took its seven grays from the guest's hand-drawn kit (`ui_theme.c`).
/// Fonts are stand-ins; a ported Chicago/Geneva bitmap pack replaces them
/// later (mirror README, "Asset packs").
public enum Platinum {
    // The seven grays.
    public static let g0 = Color(hex: 0xFFFFFF)   // highlight
    public static let g1 = Color(hex: 0xEEEEEE)   // light face
    public static let g2 = Color(hex: 0xCCCCCC)   // face
    public static let g3 = Color(hex: 0xA6A6A6)   // mid
    public static let g4 = Color(hex: 0x888888)   // shadow
    public static let g5 = Color(hex: 0x555555)   // dark
    public static let g6 = Color(hex: 0x000000)   // frame

    /// OS 9 default blue desktop.
    public static let desktopBlue = Color(hex: 0x7395BD)
    /// Menu/selection highlight.
    public static let selection = Color(hex: 0x333399)

    // Logical surface (the guest screen); scenes carry rects in this space.
    public static let logicalSize = CGSize(width: 1024, height: 768)

    // Metrics (px in logical space).
    public static let menubarHeight: CGFloat = 20
    public static let titlebarHeight: CGFloat = 20
    public static let contentTop: CGFloat = 22

    // Chicago / Geneva stand-ins.
    public static func systemFont(_ size: CGFloat) -> Font {
        .custom("Charcoal", size: size)
        .weight(.medium)
    }
    public static func appFont(_ size: CGFloat) -> Font {
        .custom("Geneva", size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
