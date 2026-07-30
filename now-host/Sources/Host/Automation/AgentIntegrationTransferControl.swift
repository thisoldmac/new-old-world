import Foundation
import NOWAgentIntegration

/// The host's half of #8: end the transfer in flight, in whichever
/// direction it is going.
///
/// It owns no transfer and no lifecycle. `GuestListener.cancelFile()` is the
/// same call the Files page's Cancel button makes; what is added here is the
/// part a button never needed — reading the lane BEFORE and AFTER, so the
/// answer can tell "stopped it" from "there was nothing to stop", and can
/// say which of the two halves of a cancel is actually known.
///
/// **The two halves, because everything below follows from them.**
///
/// - *This host's half is knowable.* After `cancelFile()` the host is
///   sending no more bytes and waiting for none; the lane is re-read to
///   confirm it, and the result carries that as `hostLaneFree`.
/// - *The guest's half is not.* `file.cancel` has no reply in the contract,
///   on purpose. Each guest does emit a terminal message for the transfer it
///   cancelled — `file.done ok:false code:cancelled` receiving,
///   `file.end ok:false` sending — and this host DISCARDS it
///   (`Session.finishFile` returns early for a transfer it is discarding),
///   because waiting for it is the park that wedged the lane in the first
///   place. So the outcome says `asked`, and never `cancelled`.
///
/// A guest's disposal of a partial file is unreported for the same reason.
/// The host already names that honestly on its own failure path — a
/// cancelled put records `guestCleanup: "unknown-after-cancel"` — and this
/// row does not upgrade the claim.
///
/// **One capability, two guest answers, and no fork.** The PowerPC guest
/// dispatches `file.cancel`; the 68K guest dispatches it too, and its `cancel`
/// VERB is that machine's console face on the same body
/// (`wire68.c :: cancel_in_flight`). The verb exists because a person at a
/// PowerBook whose host has stopped answering is exactly who needs to end a
/// transfer, and the wire is exactly the face not available to them then —
/// which is a reason for the guest to have two faces, not a reason for the
/// host to choose between two mechanisms. It sends the message either way.
@MainActor
final class AgentIntegrationTransferControl {
    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let clock: @MainActor () -> Date

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.clock = clock
    }

    /// Not `async`, and the reason is the point of the operation: a cancel
    /// waits for nothing. There is no reply to await, and the host settles
    /// its own side without the wire precisely because a stalled transfer's
    /// next send is the one that will not complete.
    func cancel() -> AgentIntegrationTransferCancelResult {
        guard currentSessionID() != nil else {
            return .guestUnavailable
        }
        guard let direction = listener.fileTransferInFlight else {
            return .completed(.init(
                outcome: .nothingToCancel,
                hostLaneFree: true,
                note: quietLaneNote(),
                observedAt: clock()))
        }

        /* Read before, because the cancel clears it: `settlePut` and the
           download's failure path both drop the progress this describes. */
        let progress = listener.captureProgress
        listener.cancelFile()
        let released = listener.fileTransferInFlight == nil

        /* Rule 3, and the case that needs it most. The dispatch's own audit
           line says an agent invoked `now_transfer_cancel` and nothing more
           — by design, it carries no arguments — and the person at this Mac
           may have started this transfer at the Files page and be watching
           the bar. So the detail goes where they already read about their
           own transfers: the `files` area, at warn, because something they
           may have started has been stopped by somebody else. */
        listener.note(personVisibleLine(direction: direction,
                                        progress: progress),
                      area: "files", level: .warn)

        return .completed(.init(
            outcome: .asked,
            direction: reported(direction),
            confirmedBytes: progress?.received,
            expectedBytes: progress?.expected,
            hostLaneFree: released,
            note: askedNote(released: released),
            observedAt: clock()))
    }

    // MARK: - The sentences

    /// Why a quiet FILE lane may still not be a quiet machine.
    ///
    /// A capture or a live stream holds the same one-wide lane and neither
    /// is ended by `file.cancel` — so a caller told only "nothing to cancel"
    /// while a stream runs would reasonably conclude the machine was idle
    /// and that its next transfer would be accepted. It is named here
    /// rather than acted on: ending a stream is `stream.stop`, and reaching
    /// for it because the lane looked busy would be this row deciding what
    /// a caller asked for.
    private func quietLaneNote() -> String {
        if listener.activeStreamId != nil {
            return "No file transfer was in flight. A live screen stream is "
                + "holding this connection's one transfer lane, and "
                + "file.cancel does not end one."
        }
        if listener.isCapturePending {
            return "No file transfer was in flight. A capture is holding "
                + "this connection's one transfer lane; abandoning that is "
                + "now_capture_screen's own operation."
        }
        return "No transfer was in flight, so nothing was sent."
    }

    /// Deliberately does NOT assert that a cancel reached the guest.
    ///
    /// It usually did — but `Session.cancelFile()` needs the transfer id off
    /// the guest's own `file.begin` to name one, so a download this host
    /// asked for and the guest has not begun is abandoned HERE with no
    /// message at all. That case leaves the guest holding a lane the host
    /// has let go of, which is a defect of the wire's cancel rather than of
    /// this row; either way the guest's half is unconfirmable, so the
    /// sentence says what is true of both.
    private func askedNote(released: Bool) -> String {
        let asked = "This host has stopped: it is sending no more bytes and "
            + "waiting for none. A cancel goes to the guest for a transfer "
            + "it has begun; one it has not begun yet is abandoned here "
            + "without a message, there being no transfer to name. Either "
            + "way the contract gives a cancel no reply, so whether the "
            + "guest stopped, and what it did with a partial file, are not "
            + "reported."
        guard released else {
            return asked + " This host's own half of the lane did NOT come "
                + "free, which is a defect rather than an expected outcome."
        }
        return asked
    }

    /// One line, in the words `docs/logging.md` asks for, and it says the
    /// thing the audit event cannot: **that the transfer it stopped may not
    /// have been an agent's.** The host does not record who started the
    /// transfer holding the lane — `putFile`/`getFile` take a completion and
    /// no origin — so this claims no owner rather than guessing one.
    private func personVisibleLine(
        direction: GuestListener.FileTransferInFlight,
        progress: GuestListener.CaptureProgress?
    ) -> String {
        var line = "transfer cancel: an agent stopped the "
            + "\(reported(direction).rawValue) transfer"
        if let progress {
            line += " at \(progress.received) of \(progress.expected) bytes"
        }
        return line + " (this host does not record who started it)"
    }

    private func reported(_ direction: GuestListener.FileTransferInFlight)
        -> AgentIntegrationTransferCancelReport.Direction {
        switch direction {
        case .incoming: return .incoming
        case .outgoing: return .outgoing
        }
    }
}
