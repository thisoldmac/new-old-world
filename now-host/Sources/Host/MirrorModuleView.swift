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
            }
            Spacer()
            if model.state.hasScene {
                Button("Close Scene") { model.clearScene() }
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

    /// The header says what is on screen, and where it came from. A page
    /// showing a replay says so in the second line a person reads, not in a
    /// tooltip.
    private var subtitle: String {
        model.provenance?.banner
            ?? "What is on the other Mac's screen, drawn from what it says "
            + "is there rather than from its pixels."
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
            SceneView(scene: scene)
                .aspectRatio(CGFloat(scene.screen.w) / CGFloat(scene.screen.h),
                             contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            Divider()
            sceneFooter(scene)
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
