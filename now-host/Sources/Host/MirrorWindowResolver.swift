import Foundation
import MirrorKit

/// **From the identity a scene has to the reference `winact` takes.**
///
/// `winact` addresses one window by an opaque `now-window-…` that only the
/// responder mints, and a scene carries no such thing: NOW's scene producer
/// and the `elements` walk are two different readers of the same machine, and
/// only the second one mints. So a window op from the pane needs one call in
/// between — the observation — and this is it.
///
/// ## Why this reads the command directly instead of going through a row
///
/// `elements` has a projected row (`ObserveElementsProjection`) and no local
/// lane behind it on this host: `AgentIntegrationLocalClient` implements the
/// five acts and not the observation that mints their arguments. Building
/// that lane is the observe lane's work, not this page's — it wants a decode
/// for the whole `x-axTree`, a capability row, and a consent tier.
///
/// What this page needs is three fields of it, so it asks the same way
/// `MirrorSceneProbe` asks `axsnap`: a `command.request` on the control
/// plane, read for exactly what the caller can use. That is a precedent this
/// file follows rather than one it sets. **When the observe lane lands, this
/// should become a caller of it** — the decode below is a page-local reader,
/// not a second definition of the tree.
///
/// ## What it refuses, and why refusing is the whole job
///
/// Resolution is a place to be wrong, and being wrong here means acting on
/// **a neighbouring window** — closing the wrong document, moving the wrong
/// folder. Every one of these answers `nil` with a sentence rather than a
/// best guess:
///
/// - the scene's process serial does not parse as a PSN;
/// - the machine did not answer the observation, or does not serve it;
/// - the walk saw no window of that title in that process;
/// - it saw several and none of them has the occurrence the scene reports.
///
/// The one thing it will never do is fall back to "the frontmost window",
/// which is the target-free form the whole act plane refuses on the strength
/// of a measurement (18/20 versus 0/20; `contract/asyncapi.yaml`, `winact`).
@MainActor
struct MirrorWindowResolver {
    /// One command, asked of the connected machine. Injected so a test can
    /// answer it without a socket, and so the day this calls the observe lane
    /// instead, the seam is already the place to change.
    typealias Ask = @MainActor (_ name: String,
                                _ args: [String: String]) async -> CommandResult

    /// The contract's own spelling. `elements` is the minter — "Nothing else
    /// can produce these references, and that is the point."
    static let command = "elements"

    let ask: Ask

    init(ask: @escaping Ask) {
        self.ask = ask
    }

    /// The ordinary construction: the page's own listener, on the control
    /// plane. Not the transfer lane — an act must not queue behind the stream
    /// that is drawing the scene being acted on
    /// (`AgentIntegrationActControl`), and neither must the observation that
    /// addresses it.
    init(listener: GuestListener) {
        self.init { name, args in
            await withCheckedContinuation { continuation in
                listener.runCommand(name, args: args) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// What one resolution came to. A reference, or a sentence saying which
    /// half is missing — never a reference this side invented.
    enum Resolution: Equatable {
        case reference(String)
        case unresolved(String)
    }

    func reference(for target: WindowTarget) async -> Resolution {
        guard let psn = Self.serial(target.psn) else {
            return .unresolved(
                "The scene reports this window's process as "
                    + "\"\(target.psn)\", which is not a process serial this "
                    + "side can send. Nothing was asked of the Mac.")
        }
        let result = await ask(Self.command,
                               ["serialHi": String(psn.hi),
                                "serialLo": String(psn.lo)])
        guard result.ok else {
            let said = result.error.map { "\($0.message) [\($0.code)]" }
                ?? "it refused without saying why"
            return .unresolved(
                "A window act is addressed by a reference only an "
                    + "observation mints, and this Mac would not take the "
                    + "observation: \(said)")
        }
        let windows = Self.windows(in: result)
        guard !windows.isEmpty else {
            return .unresolved(
                "This Mac answered the observation with no windows for that "
                    + "program, so there is no reference to address. The "
                    + "drawing and the walk are two readings taken at "
                    + "different moments; the drawing may be the older one.")
        }
        let named = windows.filter { $0.title == target.title }
        guard !named.isEmpty else {
            return .unresolved(
                "No window titled \"\(target.title)\" was in that program's "
                    + "observation, so nothing was addressed. The drawing is "
                    + "older than the walk, or the window has closed.")
        }
        if named.count == 1 {
            return .reference(named[0].ref)
        }
        /* Several windows wear this title, which is ordinary — two untitled
           documents, two folders of the same name. The occurrence is what
           tells them apart, and the guest and this side count it the same
           way BY CONSTRUCTION (`ActionModel.target(for:in:)` cites the
           guest's own arithmetic). When it does not resolve, the honest
           answer is nothing: acting on "the first one" would close a
           document the person was not looking at. */
        let exact = named.filter { $0.occurrence == target.occurrence }
        guard exact.count == 1 else {
            return .unresolved(
                "\(named.count) windows in that program are titled "
                    + "\"\(target.title)\", and the drawing's position among "
                    + "them (\(target.occurrence + 1)) does not pick out one "
                    + "of the observation's. Nothing was sent: acting on "
                    + "whichever came first would act on a window you are "
                    + "not looking at.")
        }
        return .reference(exact[0].ref)
    }

    // MARK: - reading the walk

    /// The three fields of a walked window this page can use. Deliberately
    /// not a second decode of `x-axTree` — see the header.
    struct Walked: Equatable {
        var ref: String
        var title: String
        var occurrence: Int
    }

    static func windows(in result: CommandResult) -> [Walked] {
        guard case .object(let tree)? = result.outputObjects?[command],
              case .array(let processes)? = tree["processes"] else {
            return []
        }
        var walked: [Walked] = []
        for process in processes {
            guard case .object(let fields) = process,
                  case .array(let windows)? = fields["windows"] else {
                continue
            }
            for window in windows {
                guard case .object(let w) = window,
                      case .string(let ref)? = w["ref"] else { continue }
                let title: String
                if case .string(let t)? = w["title"] { title = t } else {
                    title = ""
                }
                var occurrence = 0
                if case .number(let n)? = w["occurrence"] {
                    occurrence = Int(n)
                }
                walked.append(Walked(ref: ref, title: title,
                                     occurrence: occurrence))
            }
        }
        return walked
    }

    /// "hi.lo" → the pair the observation takes. A scene's psn is a display
    /// string; anything that is not two integers names no process, and half a
    /// PSN names none either.
    static func serial(_ psn: String) -> (hi: Int, lo: Int)? {
        let halves = psn.split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count == 2,
              let hi = Int(halves[0]), let lo = Int(halves[1]) else {
            return nil
        }
        return (hi, lo)
    }
}
