import CoreGraphics

enum FilesResponsivePresentation: Equatable {
    case spacious
    case compactSidebars
    case compactChrome
    case guestOnly
}

struct FilesResponsivePreferences: Equatable {
    var guestSidebarCompact: Bool
    var hostSidebarCompact: Bool
    var hostPaneCollapsed: Bool
}

struct FilesResponsiveState: Equatable {
    var presentation: FilesResponsivePresentation
    var guestSidebarCompact: Bool
    var hostSidebarCompact: Bool
    var hostPaneCollapsed: Bool

    var usesCompactChrome: Bool {
        presentation == .compactChrome || presentation == .guestOnly
    }
}

enum FilesResponsivePolicy {
    static func presentation(for width: CGFloat)
        -> FilesResponsivePresentation {
        switch width {
        case ..<1_050: .guestOnly
        case ..<1_250: .compactChrome
        case ..<1_450: .compactSidebars
        default: .spacious
        }
    }

    static func resolve(width: CGFloat,
                        preferences: FilesResponsivePreferences)
        -> FilesResponsiveState {
        let presentation = presentation(for: width)
        let forcesCompactSidebars = presentation != .spacious
        return FilesResponsiveState(
            presentation: presentation,
            guestSidebarCompact: preferences.guestSidebarCompact
                || forcesCompactSidebars,
            hostSidebarCompact: preferences.hostSidebarCompact
                || forcesCompactSidebars,
            hostPaneCollapsed: preferences.hostPaneCollapsed
                || presentation == .guestOnly)
    }
}
