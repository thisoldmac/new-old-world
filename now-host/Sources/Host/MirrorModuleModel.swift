import Combine
import Foundation
import MirrorKit
import NOWAgentIntegration

/// The Mirror page: what is on the other Mac's screen, drawn from the scene
/// the guest describes rather than from its pixels.
///
/// ## What it renders from today, and why
///
/// **Replayed scene documents, not the live wire.** The scene family exists in
/// the contract (`SceneRequest` / `SceneBegin` / `SceneEnd` in
/// `ContractMessages.swift`) and NOW's guest produces the document, but
/// nothing on this side requests one yet: `GuestListener` has no scene path.
/// A pane that claimed to show a live screen would therefore be showing
/// nothing, permanently, with no way to tell that from a quiet Mac.
///
/// So this model has exactly one door — `show(document:provenance:)` — and it
/// takes bytes. Today the only caller is a person opening a recorded scene
/// (`Provenance.fixture`), which is enough to judge the renderer before the
/// wire is involved; when the listener learns to ask, it calls the same door
/// with `Provenance.guest` and nothing else here changes. The pane always says
/// which one it is drawing, because a replayed Finder window that reads as
/// *this Mac, now* is the worst thing this page could do.
///
/// ## The resting states are the hard part
///
/// A mirror with nothing to mirror is the normal case on a desk where the
/// extension is not installed, and the failure to design against is a page
/// that reads as **broken** when it is merely **idle** — the most-cited defect
/// in this repo (`docs/metal-and-ux-review.md` §1: *"0 companions, 0 calls,
/// last seen never is the visual shape of a thing that failed to load"*).
///
/// Every state below therefore says three things: what is true, why that is
/// ordinary, and what would change it. None of them is drawn as a fault
/// except the one that IS a fault — a document that would not decode — and
/// `MirrorPaneState.isFault` is the switch the pane reads, asserted in tests
/// so a later state cannot quietly join the wrong side.
@MainActor
final class MirrorModuleModel: ObservableObject, GuestScopedModel {

    /// What this host knows about the NOW Extension on the connected Mac.
    ///
    /// `unasked` is a first-class value, not a stand-in for `absent`. Nothing
    /// on this side probes for the extension yet, so `unasked` is the honest
    /// answer on every connection today, and rendering it as "absent" would
    /// be this page inventing a fact about someone's Mac.
    enum ExtensionEvidence: Equatable, Sendable {
        case unasked
        case absent
        case present
    }

    /// Whether the extension's scene plane is armed. Same rule: `unasked`
    /// means nobody looked. A plane is dormant until the application arms it
    /// (`docs/resident-components.md`), so "present but unarmed" is the
    /// expected state of a freshly booted Mac and not a fault.
    enum PlaneEvidence: Equatable, Sendable {
        case unasked
        case unarmed
        case armed
    }

    /// Where the scene on screen came from. Carried beside the scene, never
    /// inferred from it: the document itself cannot say whether it was read
    /// off a wire a moment ago or off a disk from last month.
    enum Provenance: Equatable, Sendable {
        /// A recorded document replayed from a file on this Mac.
        case fixture(name: String)
        /// A scene this guest sent. No producer calls this yet.
        case guest(name: String)

        var isLive: Bool {
            if case .guest = self { return true }
            return false
        }
    }

    @Published var connection: GuestConnectionState = .disconnected

    @Published private(set) var extensionEvidence: ExtensionEvidence = .unasked
    @Published private(set) var planeEvidence: PlaneEvidence = .unasked
    @Published private(set) var scene: MirrorKit.Scene?
    @Published private(set) var provenance: Provenance?
    /// The last document that would not decode, kept as prose. Distinct from
    /// having no scene: one is silence, the other is something that went
    /// wrong, and only the second is drawn as a fault.
    @Published private(set) var failure: String?

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    private var guestName: String {
        if case .connected(let name, _) = connection { return name }
        return ""
    }

    /// The one door in. `irVersion` is the envelope's number — the gate runs
    /// on it before the body is parsed, which is `NOWSceneCodec`'s contract
    /// and the reason this does not decode first and check after.
    func show(document: Data, irVersion: Int = 1, provenance: Provenance) {
        do {
            let doc = try NOWSceneCodec.decode(irVersion: irVersion,
                                               document: document)
            scene = MirrorSceneAdapter.scene(from: doc)
            self.provenance = provenance
            failure = nil
        } catch let error as NOWSceneDecodeError {
            fail(Self.describe(error), provenance: provenance)
        } catch {
            fail("\(error)", provenance: provenance)
        }
    }

    /// Puts the page back to its resting state without touching what this
    /// host believes about the machine.
    func clearScene() {
        scene = nil
        provenance = nil
        failure = nil
    }

    /// Seams for the probe that does not exist yet. They are `internal` and
    /// called from tests only; when something learns these facts for real it
    /// calls them instead of growing a second path.
    func record(extensionEvidence: ExtensionEvidence) {
        self.extensionEvidence = extensionEvidence
    }

    func record(planeEvidence: PlaneEvidence) {
        self.planeEvidence = planeEvidence
    }

    /// A machine leaving takes its scene with it — but only a LIVE one. A
    /// replayed fixture is this Mac's document and has nothing to do with
    /// who is on the wire, so it stays on screen.
    func guestLeft(_ key: GuestKey) {
        extensionEvidence = .unasked
        planeEvidence = .unasked
        if provenance?.isLive == true { clearScene() }
    }

    private func fail(_ reason: String, provenance: Provenance) {
        scene = nil
        self.provenance = provenance
        failure = reason
    }

    private static func describe(_ error: NOWSceneDecodeError) -> String {
        switch error {
        case .unsupportedMajor(let major):
            return "This scene announces IR major \(major), which this "
                + "version of New Old World does not read. It was refused "
                + "before it was parsed."
        case .versionDisagreement(let envelope, let body):
            return "The scene's envelope says IR \(envelope) and its body "
                + "says \(body). A document that cannot agree with itself "
                + "about what it is does not get read."
        case .malformed(let detail):
            return "The scene could not be read: \(detail)"
        }
    }

    /// What the pane draws. Derived, never stored — one place decides, and a
    /// test can ask it without a view.
    var state: MirrorPaneState {
        if let failure, let provenance {
            return .unreadable(reason: failure, provenance: provenance)
        }
        if let scene, let provenance {
            return MirrorSceneAdapter.hasScreen(scene)
                ? .showing(scene: scene, provenance: provenance)
                : .sceneWithoutScreen(provenance: provenance)
        }
        guard isConnected else { return .noGuest }
        switch extensionEvidence {
        case .unasked:
            return .notLookedYet(guest: guestName)
        case .absent:
            return .extensionAbsent(guest: guestName)
        case .present:
            switch planeEvidence {
            case .unasked:
                return .notLookedYet(guest: guestName)
            case .unarmed:
                return .planeUnarmed(guest: guestName)
            case .armed:
                return .armedNoSceneYet(guest: guestName)
            }
        }
    }
}

/// The page's states, as one closed set.
///
/// An enum rather than a handful of booleans in the view, because "what does
/// this page show when there is nothing to show" is a decision with a right
/// answer per case, and a view assembling it from flags gets combinations
/// nobody designed — a spinner over an error, a hint about arming a plane on
/// a Mac that is not connected.
enum MirrorPaneState: Equatable {
    /// Nothing is on the wire.
    case noGuest
    /// A Mac is connected and nobody has asked it what it has.
    case notLookedYet(guest: String)
    /// Asked: this Mac has no NOW Extension.
    case extensionAbsent(guest: String)
    /// The extension is there and its scene plane is dormant.
    case planeUnarmed(guest: String)
    /// Armed, and no scene has arrived yet.
    case armedNoSceneYet(guest: String)
    /// A scene, and where it came from.
    case showing(scene: MirrorKit.Scene, provenance: MirrorModuleModel.Provenance)
    /// A scene that reported no screen size. Not a fault and not a blank
    /// canvas: the producer did not say how big the screen is, so there is
    /// nothing to fit the drawing into.
    case sceneWithoutScreen(provenance: MirrorModuleModel.Provenance)
    /// A document that would not decode. The only fault in the set.
    case unreadable(reason: String, provenance: MirrorModuleModel.Provenance)

    /// The one state drawn as something wrong. Everything else is idle, and
    /// idle is drawn as idle.
    var isFault: Bool {
        if case .unreadable = self { return true }
        return false
    }

    /// True when the page has something to draw rather than something to say.
    var hasScene: Bool {
        if case .showing = self { return true }
        return false
    }

    /// The resting copy: a glyph, a headline, what is true, and what would
    /// change it. Data rather than view code so the words are testable and
    /// so no state can reach the screen without having been written.
    var resting: MirrorRestingCopy? {
        switch self {
        case .showing:
            return nil
        case .noGuest:
            return MirrorRestingCopy(
                symbol: "desktopcomputer",
                title: "No Mac Connected",
                message: "The other Mac dials this one. When it connects, "
                    + "this page can show what is on its screen — drawn "
                    + "from what the Mac says is there, not from its pixels.",
                next: "A recorded scene can be opened here at any time, "
                    + "with or without a Mac on the wire.")
        case .notLookedYet(let guest):
            return MirrorRestingCopy(
                symbol: "questionmark.circle",
                title: "Not Looked Yet",
                message: "\(guest) is connected. Whether it has the NOW "
                    + "Extension — the resident piece that can see other "
                    + "programs' windows — has not been asked.",
                next: "Nothing on this side asks yet. Until it does, open a "
                    + "recorded scene to see how one is drawn.")
        case .extensionAbsent(let guest):
            return MirrorRestingCopy(
                symbol: "puzzlepiece.extension",
                title: "No NOW Extension",
                message: "\(guest) is connected and running NOW, and that is "
                    + "enough for every other page. Only this one needs the "
                    + "NOW Extension: a program can read its own windows, "
                    + "and reading another program's needs code resident "
                    + "inside it.",
                next: "Install the NOW Extension on \(guest) and restart it.")
        case .planeUnarmed(let guest):
            return MirrorRestingCopy(
                symbol: "moon.zzz",
                title: "Scene Plane Dormant",
                message: "\(guest) has the NOW Extension and its scene plane "
                    + "is asleep. That is how it ships: a plane runs no code "
                    + "at all until something asks for it, so a Mac that "
                    + "never opens this page never runs a window walk.",
                next: "Arming it is what this page will do when it can ask "
                    + "for a scene.")
        case .armedNoSceneYet(let guest):
            return MirrorRestingCopy(
                symbol: "clock",
                title: "Waiting for the First Scene",
                message: "\(guest)'s scene plane is armed. A walk takes a "
                    + "moment on a Macintosh of this vintage, and nothing "
                    + "has arrived yet.",
                next: "This is what a working page looks like for its first "
                    + "second or two.")
        case .sceneWithoutScreen(let provenance):
            return MirrorRestingCopy(
                symbol: "rectangle.dashed",
                title: "No Screen Size Reported",
                message: "This scene from \(provenance.label) describes "
                    + "windows but never says how big the screen is, so "
                    + "there is nothing to fit them into. The scene is not "
                    + "damaged — the producer did not report that plane.",
                next: "A scene from a newer guest build will carry it.")
        case .unreadable(let reason, let provenance):
            return MirrorRestingCopy(
                symbol: "exclamationmark.triangle",
                title: "Scene Could Not Be Read",
                message: "\(provenance.label): \(reason)",
                next: "Nothing was drawn from it. A scene is refused whole "
                    + "rather than shown in part.")
        }
    }
}

/// A resting state's words. Four fields, and the fourth is the point: a page
/// that says what is true without saying what would change it is a page that
/// reads as broken.
struct MirrorRestingCopy: Equatable {
    let symbol: String
    let title: String
    let message: String
    /// What a person can do, or what will happen next. Never empty.
    let next: String
}

extension MirrorModuleModel.Provenance {
    /// How the page names this scene's origin, in one phrase it can drop into
    /// a sentence.
    var label: String {
        switch self {
        case .fixture(let name): return "Recorded scene \(name)"
        case .guest(let name): return "\(name), live"
        }
    }

    /// The banner over the drawing. A replay must never read as this Mac,
    /// now — that is the whole reason provenance is carried at all.
    var banner: String {
        switch self {
        case .fixture(let name):
            return "Replayed from \(name) — a recording, not this Mac now"
        case .guest(let name):
            return "Live from \(name)"
        }
    }
}
