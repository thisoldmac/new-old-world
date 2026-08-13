import Foundation

/// What remains useful on a module page while no guest is selected.
///
/// This is presentation policy only. Module models continue to own whether
/// and how their state is cached; the shell neither clears nor manufactures
/// data when the connection changes.
enum ModuleAvailability: Equatable, Sendable {
    case available
    case local
    case reduced
    case unavailable
}

enum ModuleAvailabilityShellTreatment: Equatable, Sendable {
    case none
    case staleBanner
    case unavailable
}

struct ModuleAvailabilityPresentation: Equatable, Sendable {
    let availability: ModuleAvailability
    let shellTreatment: ModuleAvailabilityShellTreatment

    static func resolve(moduleID: String,
                        status: GuestStatus) -> ModuleAvailabilityPresentation {
        guard !status.isConnected else {
            return ModuleAvailabilityPresentation(
                availability: .available,
                shellTreatment: .none)
        }

        switch moduleID {
        // These pages configure or operate services owned by this Mac.
        case "files", "icloud", "chat", "web", "development", "mcp",
             "logs", "settings":
            return ModuleAvailabilityPresentation(
                availability: .local,
                shellTreatment: .none)

        // Their models may retain useful, machine-scoped history. The shell
        // labels it as offline without taking ownership of that history.
        case "screen", "console", "census", "diagnostics":
            return ModuleAvailabilityPresentation(
                availability: .reduced,
                shellTreatment: .staleBanner)

        // Mirror has a richer lifecycle and refusal vocabulary of its own.
        // It is still reduced without a guest, but a second shell banner
        // would obscure rather than clarify that owned state.
        case "mirror":
            return ModuleAvailabilityPresentation(
                availability: .reduced,
                shellTreatment: .none)

        // These models deliberately drop machine-specific rows when focus is
        // lost, so there is no honest offline body for the shell to reveal.
        case "processes", "software", "networking":
            return ModuleAvailabilityPresentation(
                availability: .unavailable,
                shellTreatment: .unavailable)

        default:
            return ModuleAvailabilityPresentation(
                availability: .unavailable,
                shellTreatment: .unavailable)
        }
    }
}
