import Combine
import Foundation
import MirrorKit
import NOWAgentIntegration

/// The Mirror page: what is on the other Mac's screen, drawn from the scene
/// the guest describes rather than from its pixels.
///
/// ## What it renders from, and who asks
///
/// **Two sources, one door.** `show(document:irVersion:provenance:)` takes
/// bytes and an envelope version, and both sources go through it: a person
/// opening a recorded document (`Provenance.fixture`), and a scene fetched off
/// the wire (`Provenance.guest`). The pane always says which one it is
/// drawing, because a replayed Finder window that reads as *this Mac, now* is
/// the worst thing this page could do.
///
/// **A fetch happens because a person asked for one.** `fetchScene()` is
/// called from the page's button and from nowhere else — not on appearance,
/// and not on a timer. Three reasons, in order of weight:
///
/// 1. **The Mac moves one thing at a time.** A scene is a transfer on the one
///    bulk lane that screenshots, streams and file transfers share. A poll
///    would take that lane at intervals nobody chose, and the person whose
///    download it interrupted would have no way to connect the two.
/// 2. **A walk is real work on the machine being walked** — every process and
///    window, through a resident extension, on hardware where that is not
///    free. Selecting a tab is not a request for it.
/// 3. **Rule 3 says a person can initiate what an agent can.** There is no
///    scene projection row yet, so today the person is the *only* caller and
///    their button is the entire surface. When an agent verb lands it calls
///    `GuestListener.requestScene` alongside this, and the lane guard already
///    handles the two of them colliding.
///
/// The cost of choosing the button is that a scene on screen is a moment in
/// the past, so the page dates it rather than implying it is live.
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
    /// `unasked` is a first-class value, not a stand-in for `absent`, and it
    /// **survives the arrival of a caller**. It used to mean "nothing on this
    /// side can ask"; it now means "nobody has asked yet", which is still the
    /// honest answer on every fresh connection precisely because asking is a
    /// person's decision here. Rendering it as "absent" would be this page
    /// inventing a fact about someone's Mac — no less so now that the fact is
    /// obtainable.
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
        /// A scene this guest sent, in answer to a fetch.
        case guest(name: String)

        var isLive: Bool {
            if case .guest = self { return true }
            return false
        }
    }

    /// Where the last ask got to. Three values, because "nobody asked",
    /// "asking" and "asked and told no" are three different things to say and
    /// a boolean would collapse two of them.
    ///
    /// `refused` holds the reason whatever produced it — the guest declining,
    /// this side declining because the lane is busy, silence, a short
    /// transfer. The prose is already written for a person by whoever refused;
    /// this does not rewrite it.
    enum Fetch: Equatable, Sendable {
        case idle
        case looking
        case refused(String)
    }

    @Published var connection: GuestConnectionState = .disconnected
    @Published private(set) var fetch: Fetch = .idle

    /// The wire. Optional so a test or a preview gets a model that can render
    /// every state without a socket — and so that a model without one simply
    /// cannot fetch, rather than fetching into a stub that always fails.
    private let listener: GuestListener?

    init(listener: GuestListener? = nil) {
        self.listener = listener
    }

    /// Whether the button is offered at all. A page with no wire, or no Mac,
    /// has nothing to ask.
    var canFetch: Bool { listener != nil && isConnected }

    /// Asks the connected Mac for one scene. **The only producer of a live
    /// scene on this page**, and it runs because a person pressed something.
    ///
    /// A second press while one is in flight is ignored rather than queued:
    /// the listener would refuse it against its own lane guard anyway, and
    /// turning an impatient click into a visible refusal would teach a person
    /// that the page is broken when it is merely working.
    func fetchScene() {
        guard let listener, isConnected, fetch != .looking else { return }
        fetch = .looking
        listener.requestScene { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let delivery):
                self.fetch = .idle
                /* A scene that arrived is proof of both rungs of the ladder
                   at once: only the extension can walk other programs'
                   windows, and only an armed plane runs the walk. Recorded
                   through the same seams a probe would use, so there is one
                   path to these facts and not two. */
                self.record(extensionEvidence: .present)
                self.record(planeEvidence: .armed)
                self.show(document: delivery.document,
                          /* The ENVELOPE's major, not the body's. The gate
                             inside `show` runs on this number before the body
                             is parsed; reading it off the document instead
                             would be a parse before the gate. */
                          irVersion: delivery.irVersion,
                          provenance: .guest(name: delivery.guestName))
            case .failure(let failure):
                /* Deliberately does NOT touch the evidence ladder. A guest
                   that refuses has answered — but what it answered is "not
                   now", which is not a fact about whether the extension is
                   installed, and a local refusal ("the lane is busy") is not
                   a fact about the other Mac at all. Demoting the ladder on
                   a refusal would let a busy moment be recorded as a missing
                   extension. */
                self.fetch = .refused(failure.message)
            }
        }
    }

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
        /* Whatever the last ask ended in, this is a newer answer than that
           refusal. Left standing, a refusal from a minute ago would sit over
           a scene that plainly arrived. */
        fetch = .idle
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
        fetch = .idle
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
        /* A refusal is a thing ONE Mac said. It does not travel to the next
           machine on the wire, and it must not outlive the one that said it:
           the listener settles an in-flight scene with a disconnect reason,
           and that answer describes a connection that no longer exists. */
        fetch = .idle
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
        /* The ask outranks the ladder, and in this order. A fetch in flight
           is the most recent true thing about this page; a refusal is the
           most recent ANSWER, and both are more useful than repeating what
           the page believed before anyone asked.

           Both sit BELOW the scene checks above, on purpose: a refused
           refresh must not blank a scene that arrived perfectly a minute
           ago. `fetchNote` is how that refusal is still said out loud while
           the drawing stays. */
        switch fetch {
        case .looking:
            return .looking(guest: guestName)
        case .refused(let reason):
            return .refused(guest: guestName, reason: reason)
        case .idle:
            break
        }
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

    /// The last refusal, for the case `state` cannot carry it: a scene is on
    /// screen and a refresh was declined.
    ///
    /// Not a second source of truth — it is the same stored `fetch`, answering
    /// a different question. `state` answers "what does this page DRAW";
    /// this answers "what did the last ask COME TO". While there is nothing
    /// drawn the two agree, because `state` reports the refusal itself.
    var fetchNote: String? {
        guard case .refused(let reason) = fetch else { return nil }
        return reason
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
    /// A scene has been asked for and has not come back yet.
    case looking(guest: String)
    /// The ask was answered no, and this is what was said. **Not a fault**:
    /// the commonest reason is that the Mac is doing one of the other things
    /// its single transfer lane carries, which is the system working.
    case refused(guest: String, reason: String)
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
                /* This line used to say nothing on this side asks. Something
                   does now, and it is the person reading this: asking makes
                   the Mac walk every window it has, so it happens when they
                   say so and not because they opened a page. */
                next: "Look Now asks \(guest) to walk its screen and send "
                    + "back what it finds. A recorded scene can be opened "
                    + "here instead, at any time.")
        case .looking(let guest):
            return MirrorRestingCopy(
                symbol: "hourglass",
                title: "Looking",
                message: "\(guest) was asked to walk its screen. It visits "
                    + "every program and every window to answer, which takes "
                    + "a moment on a Macintosh of this vintage.",
                next: "The scene appears here when it arrives.")
        case .refused(let guest, let reason):
            return MirrorRestingCopy(
                /* A speech bubble, not a warning triangle. \(guest) answered
                   the question — the answer was no. */
                symbol: "bubble.left",
                title: "Not This Time",
                message: "\(guest) was asked for a scene and did not send "
                    + "one. \(reason)",
                next: "Look Now asks again. Nothing about \(guest) was "
                    + "changed by the refusal, and nothing was drawn from it.")
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
                /* Was: "what this page will do when it can ask for a
                   scene". It can ask now. */
                next: "Look Now asks for a scene, which is what arms it.")
        case .armedNoSceneYet(let guest):
            return MirrorRestingCopy(
                symbol: "clock",
                title: "Nothing on Screen",
                /* Rewritten. This used to be the first-second-or-two state of
                   a page that was waiting for a scene to arrive by itself.
                   Scenes do not arrive by themselves — they are fetched — so
                   the only way here now is having HAD one: a scene answered,
                   and then was closed. Saying "waiting" would describe a page
                   that is not waiting for anything. */
                message: "\(guest) has answered this page before, so its NOW "
                    + "Extension is there and its scene plane is armed. "
                    + "Nothing is being shown right now.",
                next: "Look Now asks \(guest) for a fresh scene.")
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
        case .guest(let name): return "\(name)"
        }
    }

    /// The banner over the drawing. A replay must never read as this Mac,
    /// now — that is the whole reason provenance is carried at all.
    var banner: String {
        switch self {
        case .fixture(let name):
            return "Replayed from \(name) — a recording, not this Mac now"
        case .guest(let name):
            /* Not "live". A scene is FETCHED, one ask at a time, and by
               the time it is drawn it is a description of a moment that has
               passed. Calling it live would make the page's own words the
               thing that misleads — the same failure the replay banner
               beside it exists to prevent. */
            return "From \(name) — the moment it was asked, not a live view"
        }
    }
}
