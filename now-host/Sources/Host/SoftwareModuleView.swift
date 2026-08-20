import SwiftUI

/// The connected Mac's installed software: the host face of the
/// software.* family. A domain picker and a search field over a split
/// view — the inventory table on the left, the selected item's detail
/// and its actions on the right — mirroring the guest's own Software
/// page. Launch and Show in Finder both act by the entry's path, the
/// listing's launch key, so the guest's name-ambiguity refusal can
/// never fire from this page.
///
/// **Launch is the one gated control here.** What the item IS decides whether
/// launching it means anything — an extension is loaded at startup, not
/// opened — and that is `GuestCapabilityGate`'s answer, off the type code the
/// machine already sent, rather than a type test written into this view.
/// Show in Finder is deliberately left rule-free: see `detailActions`.
struct SoftwareModuleView: View {
    @ObservedObject var model: SoftwareModel

    /// The table's row type — an item, or a duplicate group's container.
    private typealias Row = SoftwareModel.SoftwareRow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.canBrowse {
                controls
                HSplitView {
                    table
                        .frame(minWidth: 320, idealWidth: 440,
                               maxWidth: .infinity)
                    detail
                        .frame(minWidth: 260, idealWidth: 300,
                               maxWidth: 460)
                }
                .frame(maxHeight: .infinity)
                footer
            } else {
                disconnectedState
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        // Opening the page is not a reason to make the other Mac sweep its
        // disk again. It asks only for a domain this machine has not
        // answered yet; everything else is the Rescan button.
        .onAppear { model.openIfNeeded() }
        .onChange(of: model.connection) { _ in model.openIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Software")
                    .font(.largeTitle.weight(.semibold))
                Text("Installed software on \(peerLabel).")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.connection {
            case .connected(let name, _):
                Label(name, systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .connecting:
                Label("Connecting", systemImage: "circle.dotted")
                    .foregroundStyle(.orange)
            case .disconnected:
                Label("No \(MachineNaming.properNoun) Connected", systemImage: "circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.domain) {
                ForEach(SoftwareModel.Domain.allCases) { domain in
                    Text(domain.label).tag(domain)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    // MARK: list

    /// Duplicates disclose under a container row, matching the guest's own
    /// Software page — a disk with five SimpleTexts reads as one line on
    /// both Macs, and opening it says which five.
    private var table: some View {
        Table(model.visibleRows, selection: selectionBinding) {
            TableColumn("Name") { (row: Row) in
                nameCell(row)
            }
            TableColumn("Version") { (row: Row) in
                Text(row.versionText)
                    .foregroundStyle(row.versionIsKnown
                                     ? AnyShapeStyle(.primary)
                                     : AnyShapeStyle(.secondary))
            }
            .width(min: 60, ideal: 70, max: 110)
            TableColumn("Size") { (row: Row) in
                Text(row.sizeText)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 110)
            TableColumn("State") { (row: Row) in
                Text(row.stateText)
                    .foregroundStyle(row.isRunning ? Color.green : .secondary)
            }
            .width(min: 60, ideal: 70, max: 110)
        }
        .overlay {
            if model.visibleRows.isEmpty {
                emptyState
            }
        }
    }

    /// A group's name carries its own disclosure triangle, because `Table`
    /// cannot draw a real outline before macOS 14 and this app ships to 13.
    /// Members sit one indent in, under an open container.
    @ViewBuilder
    private func nameCell(_ row: Row) -> some View {
        HStack(spacing: 4) {
            if row.isGroup {
                Button {
                    model.toggle(group: row.id)
                } label: {
                    Image(systemName: model.expandedGroups.contains(row.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    model.expandedGroups.contains(row.id)
                    ? "Hide the \(row.members.count) copies of \(row.name)"
                    : "Show the \(row.members.count) copies of \(row.name)")
            } else if row.depth > 0 {
                Spacer().frame(width: 16)
            }
            Text(row.name)
                .fontWeight(row.isGroup ? .medium : .regular)
        }
    }

    /// A container row discloses, never selects — the guest makes its group
    /// rows unselectable for the same reason, so the detail pane and the
    /// Launch / Show in Finder buttons always name one real file rather than
    /// a heading standing in for five.
    private var selectionBinding: Binding<Row.ID?> {
        Binding {
            model.selection
        } set: { picked in
            guard let picked else {
                model.selection = nil
                return
            }
            if !SoftwareModel.isGroupID(picked) { model.selection = picked }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView()
                Text(model.domain == .apps
                     ? "Sweeping the disk for applications…"
                     : "Reading the \(model.domain.label)…")
                    .foregroundStyle(.secondary)
            } else if !model.search.isEmpty {
                Text("Nothing matches “\(model.search)”.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: model.lastError == nil
                      ? "shippingbox" : "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(model.lastError ?? "Nothing here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let entry = model.selectedEntry {
            detailBody(entry)
        } else {
            detailEmpty
        }
    }

    private func detailBody(_ entry: SoftwareEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let kind = entry.kindLabel {
                    Text(kind)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                factRow("Version", entry.version ?? "—")
                factRow("Size", entry.sizeLabel ?? "—")
                factRow("State", entry.stateLabel.isEmpty
                        ? "—" : entry.stateLabel)
                factColumn("Where", entry.path.isEmpty
                           ? "\(peerLabel) could not name this item’s path; "
                             + "it "
                             + "cannot be launched or revealed from here."
                           : entry.path)
            }
            Spacer(minLength: 0)
            detailActions(entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
        .padding(16)
    }

    /// Launch and Show in Finder, and they are deliberately not gated alike.
    ///
    /// **Launch goes through the gate; Show in Finder does not, and must not.**
    /// Revealing opens nothing — any item the machine can name can be shown in
    /// its own Finder, extension or not — so giving it a rule would grey out a
    /// control that works, which is the failure this whole axis exists to
    /// avoid, only pointed the other way.
    @ViewBuilder
    private func detailActions(_ entry: SoftwareEntry) -> some View {
        let launch = model.launchGate(entry)
        HStack(spacing: 10) {
            Button {
                model.launch(entry)
            } label: {
                Label("Launch", systemImage: "arrow.up.forward.app")
            }
            .disabled(!entry.isLaunchable || !model.canBrowse
                      || model.actionInFlight || !launch.isEnabled)
            .help(launch.explanation ?? "Launch this on \(peerLabel).")

            Button {
                model.reveal(entry)
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            .disabled(!entry.isRevealable || !model.canBrowse
                      || model.actionInFlight)

            if model.actionInFlight {
                ProgressView().controlSize(.small)
            }
        }
        if let note = model.launchUnavailableNote(entry) {
            /* Beside the button rather than only in its tooltip: a greyed
               control a person has to hover to understand is one they read as
               broken first. */
            Label(note, systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The machine this page is about, in sentence position.
    private var peerLabel: String {
        MachineNaming.sentence(model.connection)
    }

    private var detailEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Select an item for its version, size and location, and to "
                 + "launch it or show it in the Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func factColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No \(MachineNaming.properNoun) Connected")
                .font(.title2.weight(.semibold))
            Text("The \(MachineNaming.commonNoun) connects to "
                 + "\(MachineNaming.thisMac). Installed software appears "
                 + "once connected.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError, model.canBrowse {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let action = model.lastAction {
                Label(action, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let rows = model.sweepCost {
                sweepCostRows(rows)
            }
            if let note = model.note {
                // The listing's honest edge (a truncated inventory,
                // an unknown domain) in the guest's own words.
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stale = staleLine {
                // A rescan that failed left the OLDER listing on screen. It
                // says so, with both times, rather than letting the rows
                // pass for the answer that was just asked for.
                Label(stale, systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button {
                    model.refresh()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canBrowse || model.isLoading)
                .help("Re-scan this domain on \(peerLabel). Listings "
                      + "are cached for the life of the connection; this "
                      + "is the only re-read.")

                // What building the Applications list COSTS the
                // machine being driven, as opposed to what is in it.
                // Expensive on purpose — it sweeps its whole catalog
                // twice — so it is a
                // deliberate click rather than part of Refresh.
                Button {
                    model.measureCatalogSearch()
                } label: {
                    Label("Measure Sweep Cost", systemImage: "stopwatch")
                }
                .disabled(!model.canBrowse || model.isLoading
                          || model.actionInFlight)
                .help("Times a whole-disk search for applications on "
                      + "\(peerLabel) — cold, then warm. Takes seconds, "
                      + "and up to 20 seconds per pass on a slow disk.")

                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !model.rows.isEmpty {
                    Text(countLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The last sweep measurement, verbatim. Label and value as the Mac
    /// wrote them and in its order — including the rows that say the volume
    /// has no CatSearch, or that the sweep gave up before finishing, which
    /// are the cases where the answer is narrower rather than shorter.
    private func sweepCostRows(
        _ rows: [SoftwareModel.SweepRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .frame(width: 96, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    /// "8 of 205 · as of 14:02:11 (23 minutes ago)" — the search-narrowed
    /// count over the whole, when the sweep was taken, and how long ago that
    /// was once it stops being "just now".
    ///
    /// The absolute time is the load-bearing half and never goes wrong; the
    /// relative age is a convenience computed as the page draws, so it
    /// sharpens on the next interaction rather than ticking. It appears only
    /// past a couple of minutes, because a listing swept while you watched
    /// does not need to be told it is a snapshot — "as of" already says so.
    private var countLine: String {
        let shown = model.visibleItemCount
        let total = model.rows.count
        var line = shown == total
            ? "\(total) item\(total == 1 ? "" : "s")"
            : "\(shown) of \(total) shown"
        if let at = model.fetchedAt {
            line += " · as of \(Self.time.string(from: at))"
            if let age = Self.age(of: at) { line += " (\(age))" }
        }
        return line
    }

    /// The sentence a failed rescan owes the person: what failed, when, and
    /// which listing they are therefore still reading.
    private var staleLine: String? {
        guard let failed = model.rescanFailedAt,
              let at = model.fetchedAt else { return nil }
        return "Rescan failed at \(Self.time.string(from: failed)) — still "
            + "showing the listing swept at \(Self.time.string(from: at))."
    }

    /// Nil while the sweep is recent enough that the clock time says it
    /// better than a phrase would.
    static func age(of date: Date, now: Date = Date()) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 120 else { return nil }
        return relative.localizedString(for: date, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}
