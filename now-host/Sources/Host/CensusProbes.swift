import Foundation

/// One probe the guest can run, as the host needs to know it: an id (the
/// wire value), the column titles for its rows, and a human sentence.
///
/// This is the host's copy of the guest's `k_probes[]` and the contract's
/// `x-census/x-probes`. It is a copy, so it can drift - which is the defect
/// class this project has paid for most. `CensusProbeRegistryTests` pins it:
/// the id set must equal the contract's `x-probes` keys, and the id ORDER
/// must equal the guest's `k_probes[]` (the rail's display order), so a
/// probe added on one side and forgotten here fails a test rather than
/// silently missing a card from the dossier.
struct CensusProbe: Identifiable, Equatable, Sendable {
    /// The wire value sent in `census.request.probe`.
    let id: String
    /// Shown in the sidebar; Title Case of a plain name.
    let title: String
    /// The three column headers, leading label first; raw and meaning are
    /// the constant pair beside it (contract `x-census/x-probes.columns`).
    let columns: [String]
    /// One sentence for the row's subtitle and the empty-state.
    let summary: String
}

enum CensusProbes {
    /// In the guest rail's order - the sequence a person watching both
    /// machines sees. Membership is pinned to the contract, order to the
    /// guest, by CensusProbeRegistryTests.
    static let all: [CensusProbe] = [
        CensusProbe(
            id: "overview", title: "Overview",
            columns: ["Fact", "Raw", "Meaning"],
            summary: "The machine in plain words, synthesized from the "
                + "probes below."),
        CensusProbe(
            id: "identity", title: "Identity",
            columns: ["Fact", "Raw", "Meaning"],
            summary: "Model, processor, memory and system, a curated dozen."),
        CensusProbe(
            id: "selectors", title: "Selectors",
            columns: ["Selector", "Raw", "Meaning"],
            summary: "The full documented Gestalt walk, decoded."),
        CensusProbe(
            id: "video", title: "Video",
            columns: ["Field", "Raw", "Meaning"],
            summary: "Every graphics device: bounds, depth, driver."),
        CensusProbe(
            id: "volumes", title: "Volumes",
            columns: ["Volume", "Raw", "Meaning"],
            summary: "Mounted volumes, their size and free space."),
        CensusProbe(
            id: "drives", title: "Drives",
            columns: ["Drive", "Raw", "Meaning"],
            summary: "The drive queue - every block device the OS tracks."),
        CensusProbe(
            id: "drivers", title: "Drivers",
            columns: ["Driver", "Raw", "Meaning"],
            summary: "The Device Manager unit table, ROM or RAM."),
        CensusProbe(
            id: "adb", title: "ADB",
            columns: ["Device", "Raw", "Meaning"],
            summary: "The Apple Desktop Bus device table."),
        CensusProbe(
            id: "ata", title: "ATA",
            columns: ["Device", "Raw", "Meaning"],
            summary: "IDENTIFY through the ATA Manager - the IDE boot disk "
                + "SCSI cannot see."),
        CensusProbe(
            id: "pccard", title: "PC Card",
            columns: ["Field", "Raw", "Meaning"],
            summary: "Card Services' version and socket count."),
        CensusProbe(
            id: "pram", title: "PRAM",
            columns: ["Offset", "Raw", "Meaning"],
            summary: "Parameter RAM - decoded spans, then raw bytes."),
        CensusProbe(
            id: "power", title: "Power",
            columns: ["Battery", "Raw", "Meaning"],
            summary: "The Power Manager's battery view, on a portable."),
        CensusProbe(
            id: "pci", title: "PCI",
            columns: ["Device", "Raw", "Meaning"],
            summary: "The Name Registry device tree, on a PCI Mac."),
        CensusProbe(
            id: "scsi", title: "SCSI",
            columns: ["Target", "Raw", "Meaning"],
            summary: "An INQUIRY bus scan - the one active-I/O probe."),
    ]

    static func probe(id: String) -> CensusProbe? {
        all.first { $0.id == id }
    }
}
