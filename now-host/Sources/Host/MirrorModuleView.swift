import AppKit
import MirrorKit
import MirrorKitUI
import SwiftUI
import UniformTypeIdentifiers

/// The Mirror page: the other Mac's screen, drawn from what it says is there.
///
/// The whole page is `model.state`. There is no second source of truth in
/// here and no combination of flags — one closed set of states, one branch,
/// and the resting words come from the model as data (`MirrorRestingCopy`) so
/// they can be read by a test rather than only by an eye.
///
/// **What a person still has to judge**, because no test here can: whether
/// each resting state reads as *idle* rather than as *broken*, and whether
/// the replay banner is loud enough that a recorded Finder window is never
/// mistaken for this Mac right now. Both are in
/// `docs/metal-and-ux-review.md`.
struct MirrorModuleView: View {
    @ObservedObject var model: MirrorModuleModel

    var body: some View {
        VStack(spacing: 0) {
            header
            refusalNote
            liveNote
            contentNote
            Divider()
            content
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirror")
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                /* When the drawing arrived, counting up on its own. The
                   page dates the scene rather than implying it is live —
                   a fetched scene is a moment that has passed even when
                   the loop is running. */
                if let arrived = model.lastSceneAt, model.state.hasScene {
                    HStack(spacing: 4) {
                        Text("Scene from")
                        Text(arrived, style: .relative)
                        Text("ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if model.state.hasScene {
                Button("Close Scene") { model.clearScene() }
            }
            /* The switch. It is the person's Mac and their one transfer
               lane, so live-by-default comes with a visible way to stop —
               and the label says which state it is IN, not which button it
               is, because a control that reads as its own action is the
               commonest way a status gets misread. */
            if model.canFetch {
                Button {
                    model.setLive(!model.isLive)
                } label: {
                    Label(model.isLive ? "Live" : "Paused",
                          systemImage: model.isLive
                              ? "dot.radiowaves.left.and.right" : "pause.circle")
                }
                .help(model.isLive
                      ? "Updating on its own: this Mac is asked a cheap "
                        + "question about twice a second, and asked for a "
                        + "whole scene only when the answer changes. Press "
                        + "to stop."
                      : "Not updating. Look Now still asks once. Press to "
                        + "start the loop.")
            }
            /* The person's half of rule 3, and still the only caller that
               happens because somebody decided to: the loop below asks
               because something moved, this asks because they said so. */
            if model.canFetch {
                Button {
                    /* `withContent: true` is what makes this press different
                       from the loop's fetch. The content plane is joined on
                       ASK and never on a timer — one extra control message
                       for a press somebody made, and none at all for the
                       loop's. See MirrorContentJoin's transport note. */
                    model.fetchScene(withContent: true)
                } label: {
                    Label(model.state.hasScene ? "Look Again" : "Look Now",
                          systemImage: "eye")
                }
                .disabled(isLooking)
                .help("Ask this Mac to walk its screen and send back what "
                      + "it finds. It can move one thing at a time, so this "
                      + "waits its turn behind a screenshot or a file.")
            }
            Button {
                openScene()
            } label: {
                Label("Open Scene…", systemImage: "doc.badge.plus")
            }
            .help("Open a recorded scene document (the JSON a guest sends) "
                  + "and draw it here.")
        }
        .padding(12)
    }

    private var isLooking: Bool {
        if case .looking = model.state { return true }
        return false
    }

    /// The header says what is on screen, and where it came from. A page
    /// showing a replay says so in the second line a person reads, not in a
    /// tooltip.
    private var subtitle: String {
        model.provenance?.banner
            ?? "What is on the other Mac's screen, drawn from what it says "
            + "is there rather than from its pixels."
    }

    /// A refused ask, said out loud even when the page has a scene to draw.
    ///
    /// Without this the one case `MirrorPaneState` cannot carry would be
    /// silent: a scene is on screen, Look Again was pressed, and the Mac said
    /// no. The refusal must not blank the good scene — so it goes here, from
    /// the same stored value the `.refused` state is derived from.
    @ViewBuilder
    private var refusalNote: some View {
        if model.state.hasScene, let note = model.fetchNote {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                Text("The last ask was not answered with a scene. \(note)")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// Why the loop is doing what it is doing, when that is worth saying:
    /// backed off behind somebody else's transfer, stopped because the Mac
    /// refused, running without the cheap question. Idle silence is the
    /// normal case and gets no line.
    @ViewBuilder
    private var liveNote: some View {
        if let note = model.liveNote {
            HStack(spacing: 6) {
                Image(systemName: model.isLive ? "clock.arrow.circlepath"
                                               : "pause.circle")
                Text(note)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// What became of the last content join.
    ///
    /// **Shown whenever there was one, success included.** An empty window
    /// interior has at least six causes — nothing armed, armed in count mode,
    /// nothing drawn, two ports and no way to tell them apart, an overrun, a
    /// plane the extension carries dark — and a blank rectangle is the same
    /// picture for all of them. This line is where they stop being the same
    /// picture. The commonest of them, today, is that this host cannot arm
    /// the plane at all (`MirrorContentJoin.armGap`).
    @ViewBuilder
    private var contentNote: some View {
        if let note = model.contentNote {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scribble")
                Text(note)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .showing(let scene, _):
            drawing(scene)
        default:
            if let copy = model.state.resting {
                resting(copy, isFault: model.state.isFault)
            }
        }
    }

    /// The renderer, fitted. `SceneView` does the aspect fit itself
    /// (`FitTransform`), so this only has to give it a box with the guest's
    /// own proportions — a canvas stretched to the pane would put every
    /// window in the wrong place.
    private func drawing(_ scene: MirrorKit.Scene) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                SceneView(scene: scene)
                    /* The gesture's coordinates and the drawing's must come
                       from ONE box. `proxy.size` is the box the Canvas was
                       given, and `MirrorPointMapping` inverts the same fit
                       the renderer applied to it — a click computed against
                       any other rectangle lands near-but-wrong, which reads
                       as the Macintosh misbehaving.

                       A zero-distance drag rather than a tap gesture: it
                       reports where it ended on every platform this ships
                       to, and a press with no movement is a click. */
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { gesture in
                                press(at: gesture.location,
                                      in: proxy.size, scene: scene)
                            })
            }
            .aspectRatio(CGFloat(scene.screen.w) / CGFloat(scene.screen.h),
                         contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            Divider()
            actionNote
            sceneFooter(scene)
        }
    }

    /// One press on the drawing.
    ///
    /// The view's whole share of this is the mapping — which box, which
    /// point. What the point MEANS is the hit tester's, what may be sent is
    /// the vocabulary's, and whether it reached the machine is the driver's.
    private func press(at point: CGPoint, in size: CGSize,
                       scene: MirrorKit.Scene) {
        guard let guest = MirrorPointMapping.guestPoint(point, in: size,
                                                        scene: scene) else {
            model.clickedOffScreen()
            return
        }
        model.click(x: guest.x, y: guest.y)
    }

    /// What became of the last press. **Always shown when there was one**,
    /// including — especially — when nothing could be sent: a person
    /// clicking a control the scene cannot address must be told that, not
    /// left to conclude the Mac ignored them.
    @ViewBuilder
    private var actionNote: some View {
        if let report = model.lastAction {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol(for: report.outcome))
                Text("\(report.target): \(report.sentence)")
                Spacer()
                Button("Dismiss") { model.clearLastAction() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func symbol(for outcome: MirrorModuleModel.ActionReport.Outcome)
        -> String {
        switch outcome {
        /* Not a checkmark. The event was handed to the application and
           nothing here saw what it did with it — a tick would be this page
           claiming more than the machine did. */
        case .dispatched: return "paperplane"
        case .refused: return "bubble.left"
        case .unavailable: return "slash.circle"
        case .inert: return "circle.dashed"
        case .asking: return "hourglass"
        case .offScreen: return "rectangle.dashed"
        }
    }

    /// What the scene did and did not report, in the page's own words.
    ///
    /// **A sparse scene is normal here.** NOW's guest reports no QuickDraw
    /// content at all, so a window drawn as empty chrome is the expected
    /// picture and not a rendering failure — this line is what keeps a person
    /// from reading it as one. Absent and empty are printed differently for
    /// the same reason the adapter keeps them apart.
    private func sceneFooter(_ scene: MirrorKit.Scene) -> some View {
        HStack(spacing: 14) {
            Label(plural(scene.windows.count, "window", "windows",
                         present: scene.windowsPresent),
                  systemImage: "macwindow")
            Label(plural(scene.apps.count, "program", "programs",
                         present: scene.appsPresent),
                  systemImage: "app.dashed")
            Label(menubarSummary(scene), systemImage: "menubar.rectangle")
            if scene.meta.errorsPresent, !scene.meta.errors.isEmpty {
                Label("\(scene.meta.errors.count) noted",
                      systemImage: "exclamationmark.bubble")
                    .help(scene.meta.errors.joined(separator: "\n"))
            }
            Spacer()
            Text("IR v\(scene.version)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "not reported" is a different sentence from "none": one is silence,
    /// the other is an answer.
    private func plural(_ n: Int, _ one: String, _ many: String,
                        present: Bool) -> String {
        guard present else { return "\(many) not reported" }
        return n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    private func menubarSummary(_ scene: MirrorKit.Scene) -> String {
        guard let bar = scene.menubar else { return "no menu bar reported" }
        guard bar.menusPresent else { return "menus not reported" }
        return bar.menus.count == 1 ? "1 menu" : "\(bar.menus.count) menus"
    }

    /// The resting state. Deliberately the same shape the rest of the app
    /// uses (glyph, title, sentence) — plus one line saying what would change
    /// it, which is the difference between a page that looks idle and a page
    /// that looks broken.
    private func resting(_ copy: MirrorRestingCopy,
                         isFault: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: copy.symbol)
                .font(.system(size: 40))
                .foregroundStyle(isFault ? AnyShapeStyle(Color.orange)
                                         : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            Text(copy.title).font(.title3.weight(.semibold))
            Text(copy.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text(copy.next)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: opening a recorded scene

    /// Reads a scene document off this Mac. The IR major comes from the
    /// document's own `version` here, because a file has no envelope to carry
    /// it — the gate still runs before the body is decoded, on the number the
    /// file itself declares.
    private func openScene() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recorded scene document."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        model.show(document: data,
                   irVersion: MirrorSceneFile.declaredVersion(in: data) ?? 0,
                   provenance: .fixture(name: url.lastPathComponent))
    }
}

/// Reading a scene out of a file rather than off the wire.
///
/// On the wire the IR major arrives in `scene.begin` and the body is refused
/// before it is parsed. A file has no envelope, so this peeks at exactly one
/// key — `version` — and hands that to the same gate. A file that does not
/// declare one yields nil, which the gate then refuses: an undeclared version
/// is not a licence to guess 1.
enum MirrorSceneFile {
    static func declaredVersion(in data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }
            .flatMap { $0["version"] as? Int }
    }
}
