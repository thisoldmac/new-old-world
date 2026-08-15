import CoreGraphics
import Foundation

/// One session-level pointer event, with the provenance an end-of-drag
/// question needs and nothing else.
///
/// Every other field this app already logs is derived from something it
/// controls. These two are not: `sourcePID` says which PROCESS put the event
/// into the session stream, and `sourceStateID` says whether it came from the
/// hardware at all. This app posts a synthetic primary down of its own during
/// every handoff, and until this struct existed a posted event and a physical
/// one were identical in every field the log carried.
struct ContinuityWitnessedEvent: Equatable, Sendable {
    /// `CGEventType` raw value.
    var type: UInt32
    var location: CGPoint
    /// `kCGEventSourceUnixProcessID` — the process that posted it. Zero for
    /// events the window server produced from hardware.
    var sourcePID: Int64
    /// `kCGEventSourceStateID`. `1` is `kCGEventSourceStateHIDSystemState`,
    /// the hardware's own stream; anything else is a private source, which
    /// is what `CGEvent.post` from an application produces.
    var sourceStateID: Int64
    var uptime: TimeInterval
    /// The HID's own answer at the instant this event went by — the only
    /// reader that sits beneath this app's own taps.
    var hidPrimaryHeld: Bool
    /// What the SESSION believed at the same instant. An `NSDraggingSession`
    /// is driven by this one, not by the HID's, which is the whole reason the
    /// synthetic down exists.
    var sessionPrimaryHeld: Bool

    var name: String {
        switch type {
        case 1: return "leftMouseDown"
        case 2: return "leftMouseUp"
        case 5: return "mouseMoved"
        case 6: return "leftMouseDragged"
        default: return "type \(type)"
        }
    }

    /// `ownPID` is passed in rather than read here so the sentence can say
    /// "this app" — the single fact that separates "macOS released the
    /// button" from "we manufactured the release ourselves".
    func summary(ownPID: Int64) -> String {
        "\(name) at \(Int(location.x)),\(Int(location.y)), "
            + "pid=\(sourcePID)"
            + (sourcePID == ownPID ? " (this app)" : " (not this app)")
            + ", sourceState=\(sourceStateID)"
            + (sourceStateID == 1 ? " (hardware)" : " (posted)")
            + ", hidPrimaryHeld=\(hidPrimaryHeld ? 1 : 0)"
            + ", sessionPrimaryHeld=\(sessionPrimaryHeld ? 1 : 0)"
    }
}

/// A running tally of the session event stream for the length of ONE drag
/// session this app started.
///
/// It is a plain value with a `record` and no I/O so the sentence it produces
/// can be tested without a mouse, a tap, or a live drag — none of which a
/// test process has. The AppKit side owns only the tap that feeds it.
struct ContinuityDragWitness: Equatable, Sendable {
    /// False when the listen-only tap could not be created. Reported rather
    /// than left to look like a quiet stream: an instrument that never armed
    /// and a stream that carried nothing produce the same empty tally, and
    /// this project has already paid twice for reading those two as one.
    var installed: Bool
    var moves: UInt32 = 0
    var drags: UInt32 = 0
    var downs: UInt32 = 0
    var ups: UInt32 = 0
    var other: UInt32 = 0
    /// The last release the SESSION saw, whoever posted it. The one event
    /// that can legitimately end an `NSDraggingSession`.
    var lastUp: ContinuityWitnessedEvent?
    var lastEvent: ContinuityWitnessedEvent?

    init(installed: Bool) { self.installed = installed }

    mutating func record(_ event: ContinuityWitnessedEvent) {
        switch event.type {
        case 1: downs &+= 1
        case 2:
            ups &+= 1
            lastUp = event
        case 5: moves &+= 1
        case 6: drags &+= 1
        default: other &+= 1
        }
        lastEvent = event
    }

    var counts: String {
        "downs=\(downs), ups=\(ups), drags=\(drags), moves=\(moves)"
            + (other > 0 ? ", other=\(other)" : "")
    }
}

/// What the witness says about one finished drag session, in the words the
/// next metal round has to read.
///
/// The rule it exists to serve: **a session that ended with the button still
/// physically held either saw a release event or it did not, and those are
/// two different defects.** The end line used to name neither — it reported
/// where the session stopped and how many samples this app had stood down
/// for, which is a description of the symptom in the vocabulary of the code
/// that noticed it.
struct ContinuityDragWitnessReport: Equatable, Sendable {
    var witness: ContinuityDragWitness
    var seededAt: TimeInterval
    var endedAt: TimeInterval
    var hidHeldAtEnd: Bool
    var sessionHeldAtEnd: Bool
    /// Whether the catch surface — the drag SOURCE's own window — was still
    /// the window at the seed point when the session ended. A source window
    /// that moved out from under a live drag is the other way a session ends
    /// without anybody releasing anything.
    var catchSurface: ContinuityCatchHitTest?
    var ownPID: Int64

    /// A release this close to the end is the ender; anything older is
    /// history. Deliberately generous — the tap and the session-end callback
    /// reach the main thread by different routes — and stated once here
    /// rather than in the sentence below.
    static let releaseAttributionWindow: TimeInterval = 0.25

    var elapsedMilliseconds: Int { Int((endedAt - seededAt) * 1000) }

    /// The half that decides. Everything else in the line is context.
    var verdict: String {
        guard witness.installed else {
            return "no witness was installed — the listen-only tap was "
                + "refused, so nothing here can name what ended it"
        }
        guard let up = witness.lastUp else {
            return "NO session-level leftMouseUp was seen at all, so a "
                + "release is not what ended this session"
        }
        let age = endedAt - up.uptime
        guard age <= Self.releaseAttributionWindow, age >= -0.01 else {
            return "the last session leftMouseUp was \(Int(age * 1000))ms "
                + "before the end — too far back to be the ender: "
                + up.summary(ownPID: ownPID)
        }
        return "ended by a session leftMouseUp \(Int(age * 1000))ms earlier: "
            + up.summary(ownPID: ownPID)
    }

    var summary: String {
        "host drag session end witness: elapsed=\(elapsedMilliseconds)ms, "
            + "\(witness.counts), hidHeldAtEnd=\(hidHeldAtEnd ? 1 : 0), "
            + "sessionHeldAtEnd=\(sessionHeldAtEnd ? 1 : 0), "
            + "catchSurfaceAtSeed="
            + (catchSurface?.summary ?? "not asked")
            + " — \(verdict)"
    }

    /// Whether this report describes a session that ended for a reason
    /// nobody asked for. Drives the log LEVEL, so a healthy release stays
    /// quiet and the two failure shapes shout.
    var isSuspect: Bool {
        guard witness.installed else { return true }
        guard hidHeldAtEnd else { return false }
        return true
    }
}
