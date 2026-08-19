import SwiftUI

/* The Project Location choice, one view for every host face that mints
   a project: the Projects module's create sheet and the chat sidebar's
   New Project sheet. Two options, in the person's words, mapping to
   the two grounds ProjectGround can resolve (plan 039, slice D):

   - "On the guest, using MPW" — the verified mainline: the
     authoritative working copy stays on this Mac TODAY, and builds
     stage the files to the classic machine and run its registered MPW
     (home host, toolchain guest-mpw).
   - "On this Mac, using Retro68" — the workspace lane: files on this
     Mac, built here, binaries sent over (home host, toolchain
     host-retro68).

   The MPW option needs the guest to have reported a qualified
   toolchain; unqualified, it shows disabled with ProjectGround's own
   refusal words, so this sheet and the agent surface refuse in the
   same sentence. */
struct ProjectLocationPicker: View {
    @Binding var toolchain: String
    /// Whether the connected guest reported a qualified MPW toolchain
    /// (`ProjectGround.qualifiedToolchain`). nil means "not measured
    /// yet" and reads as unqualified, honestly: a pin cannot be
    /// written from a report nobody has.
    let guestToolchainQualified: Bool

    var body: some View {
        Picker("Project Location", selection: $toolchain) {
            option(
                "On \(MachineNaming.simpleReference), using MPW (as registered on it)",
                caption: guestToolchainQualified
                    ? "The working copy stays on this Mac; its files sync to "
                        + "\(MachineNaming.simpleReference) and build there with its MPW."
                    : ProjectGround.Refusal.guestToolchainUnqualified.message)
                .tag(ProjectGround.guestMPWToken)
                .disabled(!guestToolchainQualified)
            option(
                "On this Mac, using Retro68",
                caption: "Project files stay on this Mac and build here with "
                    + "Retro68; binaries are sent to \(MachineNaming.simpleReference).")
                .tag(ProjectGround.hostRetro68Token)
        }
        .pickerStyle(.radioGroup)
        .onAppear {
            /* A selection the ground would refuse is corrected before a
               person can submit it — the same degradation as
               ProjectGround's defaulting rule. */
            if !guestToolchainQualified,
               toolchain == ProjectGround.guestMPWToken {
                toolchain = ProjectGround.hostRetro68Token
            }
        }
    }

    /// The token a sheet should preselect: the ground's own defaulting
    /// rule, applied to what the guest has reported so far.
    static func defaultToken(guestToolchainQualified: Bool) -> String {
        guestToolchainQualified
            ? ProjectGround.guestMPWToken : ProjectGround.hostRetro68Token
    }

    private func option(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
