import Foundation

/// Presentation-only rows derived from the Hardware module's Overview probe.
/// The probe is deliberately not repeated here: the shelf reads the same
/// cached `CensusProbeState` as the full Hardware page.
struct MachineOverviewFact: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct MachineOverviewFactSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let facts: [MachineOverviewFact]
}

struct MachineOverviewApplication: Identifiable, Equatable, Sendable {
    let id: String
    let process: ProcessEntry
}

enum MachineOverviewPresentation {
    /// PPC sends caption rows followed by indented facts. NOW-68K sends a
    /// flat list. Both are the same contract rows, so normalize those two
    /// native guest presentations without assigning meaning to raw values.
    static func factSections(from rows: [[String]])
        -> [MachineOverviewFactSection] {
        var builders: [(title: String?, facts: [(String, String)])] = []

        for row in rows {
            let rawLabel = row.first ?? ""
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = row.count > 1
                ? row[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let meaning = row.count > 2
                ? row[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !label.isEmpty else { continue }

            if raw.isEmpty && meaning.isEmpty && rawLabel == label {
                builders.append((title: label, facts: []))
                continue
            }

            if builders.isEmpty { builders.append((title: nil, facts: [])) }
            let value = meaning.isEmpty ? raw : meaning
            guard !value.isEmpty else { continue }
            builders[builders.count - 1].facts.append((label, value))
        }

        var sectionOccurrences: [String: Int] = [:]
        return builders.compactMap { builder in
            guard !builder.facts.isEmpty else { return nil }
            let sectionBase = builder.title ?? "overview"
            let sectionOrdinal = sectionOccurrences[sectionBase, default: 0]
            sectionOccurrences[sectionBase] = sectionOrdinal + 1

            var factOccurrences: [String: Int] = [:]
            let facts = builder.facts.map { label, value in
                let base = "\(label)|\(value)"
                let ordinal = factOccurrences[base, default: 0]
                factOccurrences[base] = ordinal + 1
                return MachineOverviewFact(
                    id: "\(sectionBase)|\(base)|\(ordinal)",
                    label: label,
                    value: value)
            }
            return MachineOverviewFactSection(
                id: "\(sectionBase)|\(sectionOrdinal)",
                title: builder.title,
                facts: facts)
        }
    }

    /// Use the Processes page's classification and ordering: faceless
    /// processes are omitted, Finder remains an application, and the front
    /// process leads the list. The wrapper supplies stable identity even for
    /// an old responder that omitted PSNs or reported duplicate metadata.
    static func applications(from rows: [ProcessEntry])
        -> [MachineOverviewApplication] {
        let applications = rows.filter { !$0.isBackground }.sorted { lhs, rhs in
            if (lhs.front ?? false) != (rhs.front ?? false) {
                return lhs.front ?? false
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
        }

        var occurrences: [String: Int] = [:]
        return applications.map { process in
            let base: String
            if let high = process.psnHigh, let low = process.psnLow {
                base = "psn:\(high):\(low)"
            } else {
                base = "\(process.name)|\(process.code ?? "")|"
                    + "\(process.creator ?? "")"
            }
            let ordinal = occurrences[base, default: 0]
            occurrences[base] = ordinal + 1
            return MachineOverviewApplication(
                id: "\(base)|\(ordinal)", process: process)
        }
    }
}
