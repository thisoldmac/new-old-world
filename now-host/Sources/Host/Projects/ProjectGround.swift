import Foundation
import NOWAgentIntegration

/* A project's GROUND: which machine holds the authoritative copy, and
   which toolchain builds it. Both faces that mint projects — the agent
   surface and the chat wire — resolve the decision HERE, so the
   defaulting rule and the refusal stories cannot drift between them.

   Two toolchain values, deliberately not a registry (plan 039): a pin
   is either the guest's own measured MPW identity or the host lane's
   sentinel, and a third value waits for a second real toolchain on a
   real machine. */
enum ProjectGround {
    /// The opaque toolchain choice tokens a create may carry.
    static let guestMPWToken = "guest-mpw"
    static let hostRetro68Token = "host-retro68"

    /// The sentinel pin for a project the host workspace lane builds
    /// with Retro68. The guest never builds these, so its measured-pin
    /// check can never mismatch; the lane check belongs to the build
    /// attempt, not the create.
    static let hostRetro68Pin = "host-retro68@1"

    /// What the connected guest said about its own registered MPW —
    /// the identity `now_development_environment` serves, never a host
    /// guess. nil when nothing is registered or qualification refused.
    struct QualifiedGuestToolchain: Equatable {
        let id: String
        let version: String
        /// The exact pin the guest's build gate compares against
        /// (`development_runtime.c :: toolchain-pin-mismatch`).
        var pin: String { "\(id)@\(version)" }
    }

    /// Reads the guest's development rows (Toolchain / Version /
    /// Qualification) back into a typed answer. Anything short of a
    /// completed report with `Qualification == qualified` is "no
    /// qualified toolchain" — a refused read and an unregistered MPW
    /// both mean a pin cannot honestly be written.
    static func qualifiedToolchain(
        in result: AgentIntegrationGuestRowReportResult
    ) -> QualifiedGuestToolchain? {
        guard case .completed(let report) = result else { return nil }
        let rows = report.groups.flatMap(\.rows)
        func value(_ label: String) -> String? {
            rows.first { $0.label == label }?.value
        }
        guard value("Qualification") == "qualified",
              let id = value("Toolchain"), !id.isEmpty,
              id != "not registered",
              let version = value("Version"), !version.isEmpty,
              version != "unavailable" else { return nil }
        return QualifiedGuestToolchain(id: id, version: version)
    }

    /// Why a ground could not be resolved, with the story a caller can
    /// act on. Typed rather than free text so both minting faces refuse
    /// in the same words.
    enum Refusal: Error, Equatable {
        case guestHome
        case guestToolchainUnqualified
        case storeUnavailable
        case storeRefused(String)

        var code: String {
            switch self {
            case .guestHome:
                return "now-projects-guest-home-create-refused"
            case .guestToolchainUnqualified:
                return "now-projects-toolchain-unqualified"
            case .storeUnavailable, .storeRefused:
                return "now-projects-host-unavailable"
            }
        }

        var message: String {
            switch self {
            case .guestHome:
                /* ProjectStore.create refuses a guest-home mint without
                   a verified guest digest, deliberately — the classic
                   Mac holds the authoritative copy and a second minter
                   is exactly the drift that guard exists to prevent. So
                   the honest answer is the two-step, not a relaxation. */
                return "A guest-home project cannot be minted from this "
                    + "Mac: the classic machine holds the authoritative "
                    + "copy. Create it on the classic machine and import "
                    + "it, or create it host-home and promote."
            case .guestToolchainUnqualified:
                // The guest's own vocabulary for the human act it needs.
                return "The connected machine reports no qualified MPW "
                    + "toolchain. Register MPW Folder on the classic "
                    + "machine first, or choose host-retro68."
            case .storeUnavailable:
                return "The application-owned Projects directory is "
                    + "unavailable on this Mac."
            case .storeRefused(let reason):
                return "The project could not be minted: \(reason)"
            }
        }
    }

    /// Resolves a create's toolchain choice to the pin its descriptor
    /// carries. `home` must already be `.host` — a guest home is
    /// refused before any pin question arises.
    ///
    /// THE DEFAULTING RULE, in its one place: absent an explicit
    /// choice, a project defaults to `guest-mpw` whenever the connected
    /// guest reports a qualified toolchain, and to the `host-retro68`
    /// sentinel otherwise — for BOTH homes, because a host-home project
    /// built ON the guest via staged candidates is the mainline MPW
    /// flow (open-issues acceptance: host-home project, guest MPW
    /// build). Only the explicit `guest-mpw` ask refuses when nothing
    /// is qualified; the default degrades to the lane that can build.
    @MainActor
    static func resolvePin(
        toolchain: String?,
        environment: () async -> AgentIntegrationGuestRowReportResult
    ) async -> Result<String, Refusal> {
        switch toolchain {
        case hostRetro68Token:
            return .success(hostRetro68Pin)
        case guestMPWToken:
            guard let measured = qualifiedToolchain(in: await environment())
            else { return .failure(.guestToolchainUnqualified) }
            return .success(measured.pin)
        default:
            guard let measured = qualifiedToolchain(in: await environment())
            else { return .success(hostRetro68Pin) }
            return .success(measured.pin)
        }
    }

    /// The declarative single-file MPW plan for a starter project: one
    /// C source compiled by MrC, linked by PPCLink, plus a Rez append
    /// for every `.r` source. Exactly the shape the emulator- and
    /// metal-verified loops built 3 of 3 (open-issues, 2026-08-10 /
    /// 2026-08-19).
    ///
    /// Empty when the sources are not that shape — zero or several `.c`
    /// files — because the closed kind|input|output vocabulary cannot
    /// express a multi-object link, and a guessed plan that fails at
    /// action 1 is worse than the guest's own `build-plan-empty`
    /// refusal. A caller with a larger project revises `Project.ckp`
    /// through `apply`, as the verified loop did.
    static func buildActionLines(
        dataWritePaths: [String], product: String
    ) -> [String] {
        let cSources = dataWritePaths.filter { $0.hasSuffix(".c") }
        let rezSources = dataWritePaths.filter { $0.hasSuffix(".r") }
        guard cSources.count == 1, let source = cSources.first else {
            return []
        }
        let stem = source.split(separator: "/").last.map(String.init) ?? source
        let object = "Build/\(stem).o"
        return ["build-action=compile|\(source)|\(object)",
                "build-action=link|\(object)|\(product)"]
            + rezSources.map { "build-action=rez|\($0)|\(product)" }
    }
}
