import SwiftUI

/// The Mirror page: two buttons, the commands they run, and whatever those
/// commands said.
///
/// It draws no mirror. Everything a person sees of Mirror is Mirror's own
/// window, opened by Mirror's own binary against Mirror's own guest — this
/// page's whole job is to say where that lives and start it.
struct MirrorLauncherView: View {
    @ObservedObject var model: MirrorLauncherModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let problem = model.locationProblem {
                        notFound(problem)
                    } else {
                        half(.guestSession,
                             title: "Mirror's guest",
                             detail: "Boots a throwaway Mac OS 9.1 emulator "
                                   + "clone, stages Mirror's guest app and "
                                   + "its three INITs, cold-reboots so they "
                                   + "load, and proves the wire answers. "
                                   + "This is Mirror's OWN emulator session — "
                                   + "separate from any NOW guest, on its own "
                                   + "ports, and it takes about three minutes.",
                             action: "Start Mirror's guest")
                        half(.hostApp,
                             title: "Mirror's window",
                             detail: "Builds and runs MirrorApp, the native "
                                   + "macOS app that draws the guest's real "
                                   + "windows, controls and menus and sends "
                                   + "input back. It needs a Mirror guest "
                                   + "session already running, because it "
                                   + "takes that session's port.",
                             action: "Open Mirror's window")
                        stopping
                    }
                    transcript
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Mirror").font(.headline)
            Text("Mirror is a separate application in this repository "
                 + "(`mirror/`) that draws a classic Mac's live interface from "
                 + "structure rather than pixels. It has its own wire, its own "
                 + "resident extensions and its own agent surface — none of "
                 + "them NOW's — so this page starts it rather than "
                 + "reimplementing it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let root = model.installation?.root {
                Text(root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Nothing to launch, so nothing but the reason. Everything else on this
    /// page is about a directory that is not there.
    private func notFound(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mirror was not found")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.orange)
            Text(problem)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    /// One of Mirror's two halves: what it is, what it would run, and either
    /// the button or the reasons the button cannot help.
    @ViewBuilder
    private func half(_ which: MirrorLauncherModel.Half,
                      title: String, detail: String,
                      action: String) -> some View {
        let plan = model.plan(which)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if model.running == which {
                    ProgressView().controlSize(.small)
                }
                Button(action) { model.run(which) }
                    .disabled(model.running != nil || plan.invocation == nil)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let invocation = plan.invocation {
                /* The exact command, before the click. A launcher that hides
                   what it runs is a launcher nobody can debug from the
                   outside, and this one shells out to another project. */
                Text(invocation.displayCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(plan.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.what)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.orange)
                        Text(blocker.why)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    /// Stopping is Mirror's job too, and it is not a button here: a session
    /// left running is a live VM and a 600 MB clone, so the way to end it
    /// should be visible even though this page does not own it.
    @ViewBuilder
    private var stopping: some View {
        if let stop = model.installation?.stopScript {
            VStack(alignment: .leading, spacing: 2) {
                Text("When you are done")
                    .font(.callout.weight(.medium))
                Text("Mirror quits its own VM through QMP and deletes the "
                     + "clone. Run it from a terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stop.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if !model.transcript.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Output").font(.headline)
                    Spacer()
                    if let outcome = model.outcome {
                        Text(outcome.summary)
                            .font(.caption)
                            .foregroundStyle(outcome.succeeded
                                             ? .secondary : Color.orange)
                    }
                }
                /* Mirror's own words, unedited. A launcher that summarises a
                   failure it does not understand is how a reason gets lost —
                   the whole point of showing this is that the process below
                   knows things this page does not. */
                ScrollView {
                    Text(model.transcript.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06)))
        }
    }
}
