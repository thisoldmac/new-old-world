import AppKit
import CoreGraphics

struct HostKeySample: Equatable, Sendable {
    let action: ContinuityKey.Action
    let code: UInt16
    let character: UInt8
    let modifiers: UInt16
}

/// What the host does with one captured sample, named so the decision can be
/// logged rather than inferred. Two of the four leave the event on the host,
/// and they are NOT the same thing: `ignored` means the plane wants nothing,
/// `modifierState` means the plane wants a copy and the host keeps the
/// original.
enum ContinuityKeyDisposition: String, Equatable, Sendable {
    /// The host-owned escape chord. Consumed here; never reaches the guest.
    case chord
    /// A key event: forwarded to the guest and swallowed on this machine.
    case forwarded
    /// A bare modifier change: forwarded to the guest AND left on the host.
    ///
    /// It is copied rather than swallowed because a modifier is state, not an
    /// edge. Suppressing the `flagsChanged` would leave macOS believing the
    /// key never moved, so its own idea of what is held would drift for as
    /// long as the pointer stays on the guest — and would be wrong at the
    /// exact moment control returns. Nothing on the host acts on a modifier
    /// alone, so there is nothing to swallow it for.
    case modifierState
    /// Not this plane's event; the host keeps it untouched.
    case ignored

    var forwards: Bool { self == .forwarded || self == .modifierState }
    /// Whether the tap swallows the original.
    var consumesOnHost: Bool { self == .chord || self == .forwarded }
}

struct ContinuityKeyboardCapturePolicy: Equatable, Sendable {
    let forwardingEnabled: Bool
    let escapeShortcut: ContinuityEscapeShortcut

    /// The chord is tested FIRST and unconditionally, which is the whole
    /// coexistence argument: the way out of the guest cannot depend on a
    /// forwarding switch, and no combination of held modifiers can shadow it.
    /// Everything the chord does not claim passes through by its own kind, so
    /// a Command combination is forwarded exactly like an unmodified key —
    /// this matcher has never had a partial-match rule and must not grow one.
    func disposition(_ sample: HostKeySample) -> ContinuityKeyDisposition {
        if escapeShortcut.matches(sample) { return .chord }
        guard forwardingEnabled else { return .ignored }
        return sample.action == .modifiers ? .modifierState : .forwarded
    }

    func captures(_ sample: HostKeySample) -> Bool {
        disposition(sample) != .ignored
    }
}

enum ContinuityEscapeShortcut: String, CaseIterable, Identifiable, Sendable {
    case controlOptionEscape
    case controlOptionCommandEscape
    case controlOptionReturn
    case controlOptionBackslash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionEscape: return "⌃⌥Esc"
        case .controlOptionCommandEscape: return "⌃⌥⌘Esc"
        case .controlOptionReturn: return "⌃⌥Return"
        case .controlOptionBackslash: return "⌃⌥\\"
        }
    }

    var code: UInt16 {
        switch self {
        case .controlOptionEscape, .controlOptionCommandEscape: return 53
        case .controlOptionReturn: return 36
        case .controlOptionBackslash: return 42
        }
    }

    var modifiers: UInt16 {
        let control: UInt16 = 1 << 12
        let option: UInt16 = 1 << 11
        let command: UInt16 = 1 << 8
        switch self {
        case .controlOptionCommandEscape:
            return control | option | command
        default:
            return control | option
        }
    }

    func matches(_ sample: HostKeySample) -> Bool {
        sample.action == .down && sample.code == code
            && (sample.modifiers & Self.matchingModifierMask) == modifiers
    }

    private static let matchingModifierMask: UInt16 =
        (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
}

/// The classic Mac character byte for the keys AppKit cannot express in one.
///
/// A classic `EventRecord` carries a single-byte `message` low byte, and the
/// Mac OS keyboard drivers give the non-printing keys real byte values (Inside
/// Macintosh: Text, "ASCII character codes"). AppKit instead reports arrows,
/// page keys and home/end as private-use Unicode function-key scalars in the
/// 0xF700 range, which no single-byte encoding holds: converting them lossily
/// to Mac OS Roman yields '?' (0x3F), and that is literally what the guest
/// typed on metal on 2026-08-13. Two more disagree without being lossy —
/// AppKit's Delete key reports DEL (0x7F), which classic Mac reads as FORWARD
/// delete, so backspace silently did nothing.
///
/// The virtual codes themselves need no translation: macOS inherited the ADB
/// codes, so 0x7B is Left on both machines. Only the character byte moves.
enum ClassicKeyByte {
    /// Keyed by virtual code, because that is the layout-independent identity
    /// of a physical key — the same entry must win with Command or Option
    /// held, where AppKit's `characters` changes and the classic byte does not.
    static let byVirtualCode: [UInt16: UInt8] = [
        0x7B: 0x1C,  // left arrow
        0x7C: 0x1D,  // right arrow
        0x7E: 0x1E,  // up arrow
        0x7D: 0x1F,  // down arrow
        0x33: 0x08,  // backspace (AppKit reports DEL here)
        0x75: 0x7F,  // forward delete
        0x24: 0x0D,  // return
        0x30: 0x09,  // tab
        0x35: 0x1B,  // escape
        0x74: 0x0B,  // page up
        0x79: 0x0C,  // page down
        0x73: 0x01,  // home
        0x77: 0x04,  // end
    ]

    /// Unicode's private-use block that AppKit borrows for function keys
    /// (`NSUpArrowFunctionKey` … `NSModeSwitchFunctionKey`).
    private static let functionKeyScalars: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// - Parameter characters: `NSEvent.characters`, already layout-resolved.
    /// - Returns: the byte to put on the wire, or 0 when this key has no
    ///   classic character. Zero is deliberate for the unmapped function keys
    ///   (F1…F15, Help): the classic machine has no byte that means them, and a
    ///   lossy '?' would TYPE a question mark rather than do nothing.
    static func character(forVirtualCode code: UInt16,
                          characters: String?) -> UInt8 {
        if let mapped = byVirtualCode[code] { return mapped }
        guard let characters, let scalar = characters.unicodeScalars.first
        else { return 0 }
        if functionKeyScalars.contains(scalar.value) { return 0 }
        return characters
            .data(using: .macOSRoman, allowLossyConversion: true)?.first ?? 0
    }
}

@MainActor
protocol ContinuityKeyboardEnvironment: AnyObject {
    func start(
        policy: ContinuityKeyboardCapturePolicy,
        handler: @escaping @MainActor (HostKeySample) -> Void,
        tapDisabled: @escaping @MainActor (String) -> Void
    ) -> AnyObject?
    func stop(_ token: AnyObject)
}

@MainActor
final class AppKitContinuityKeyboardEnvironment:
    ContinuityKeyboardEnvironment {
    private final class Context: NSObject {
        let policy: ContinuityKeyboardCapturePolicy
        let handler: @MainActor (HostKeySample) -> Void
        let tapDisabled: @MainActor (String) -> Void
        var port: CFMachPort?
        init(policy: ContinuityKeyboardCapturePolicy,
             handler: @escaping @MainActor (HostKeySample) -> Void,
             tapDisabled: @escaping @MainActor (String) -> Void) {
            self.policy = policy
            self.handler = handler
            self.tapDisabled = tapDisabled
        }
    }

    private final class Token: NSObject {
        let port: CFMachPort
        let source: CFRunLoopSource
        let context: Context
        init(port: CFMachPort, source: CFRunLoopSource, context: Context) {
            self.port = port
            self.source = source
            self.context = context
        }
    }

    func start(
        policy: ContinuityKeyboardCapturePolicy,
        handler: @escaping @MainActor (HostKeySample) -> Void,
        tapDisabled: @escaping @MainActor (String) -> Void
    ) -> AnyObject? {
        let context = Context(policy: policy, handler: handler,
                              tapDisabled: tapDisabled)
        /* flagsChanged is in the mask for the case a key event cannot
           express: a modifier pressed or released while no key moves. The
           classic Event Manager has no such event, so without this the
           guest's modifier word can only advance when some other key happens
           to travel — and a modifier held down mid-drag, which is how the
           Finder is told to copy rather than move, moves nothing. */
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let context = Unmanaged<Context>.fromOpaque(refcon)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout
                    || type == .tapDisabledByUserInput {
                    if let port = context.port {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    let reason = type == .tapDisabledByTimeout
                        ? "timeout" : "user input"
                    let notify = context.tapDisabled
                    Task { @MainActor in notify(reason) }
                    return Unmanaged.passUnretained(event)
                }
                guard let sample = AppKitContinuityKeyboardEnvironment.sample(
                    event, type: type) else {
                    return Unmanaged.passUnretained(event)
                }
                let disposition = context.policy.disposition(sample)
                guard disposition.forwards || disposition == .chord else {
                    return Unmanaged.passUnretained(event)
                }
                /* The tap's watchdog covers this callback, not the later main
                   actor hop. Decide ownership and suppress synchronously, then
                   let the normal controller enqueue the reliable wire event. */
                let deliver = context.handler
                Task { @MainActor in deliver(sample) }
                return disposition.consumesOnHost
                    ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            return nil
        }
        context.port = port
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return Token(port: port, source: source, context: context)
    }

    func stop(_ token: AnyObject) {
        guard let token = token as? Token else { return }
        CGEvent.tapEnable(tap: token.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), token.source, .commonModes)
        CFMachPortInvalidate(token.port)
    }

    private static func sample(_ event: CGEvent,
                               type: CGEventType) -> HostKeySample? {
        /* flagsChanged is answered from the CGEvent's own flags and never
           through NSEvent. `NSEvent.characters` is defined only for key
           events and RAISES on a flagsChanged one, so the shared path below
           cannot simply widen its guard to admit it. */
        if type == .flagsChanged {
            return HostKeySample(action: .modifiers, code: 0, character: 0,
                                 modifiers: classicModifiers(event.flags))
        }
        guard type == .keyDown || type == .keyUp,
              let appEvent = NSEvent(cgEvent: event) else { return nil }
        let action: ContinuityKey.Action
        if type == .keyUp {
            action = .up
        } else if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            action = .repeatKey
        } else {
            action = .down
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return HostKeySample(
            action: action,
            code: code,
            character: ClassicKeyByte.character(forVirtualCode: code,
                                                characters: appEvent.characters),
            modifiers: classicModifiers(event.flags))
    }

    /// The one place the modifier word is built, taken from the CGEvent
    /// rather than the NSEvent so that key events and flagsChanged — which
    /// cannot become an NSEvent safely — answer through the same table.
    private static func classicModifiers(_ flags: CGEventFlags) -> UInt16 {
        var value: UInt16 = 0
        if flags.contains(.maskCommand) { value |= 1 << 8 }
        if flags.contains(.maskShift) { value |= 1 << 9 }
        if flags.contains(.maskAlphaShift) { value |= 1 << 10 }
        if flags.contains(.maskAlternate) { value |= 1 << 11 }
        if flags.contains(.maskControl) { value |= 1 << 12 }
        return value
    }
}

/// The environment a controller gets when nobody names one: it installs
/// nothing at all.
///
/// **The default must never be the real tap.** The AppKit environment builds
/// a CONSUMING session-wide `CGEventTap` for keyDown, keyUp and flagsChanged,
/// so whichever process owns it stands in front of every keystroke on the
/// Mac. That is right for the running app, whose main runloop services the
/// tap's port in milliseconds, and catastrophic for anything else: an
/// `xctest` process is inside a test on its main thread, the port is not
/// serviced, and the window server waits out the tap's timeout for every key
/// the person presses. That is not hypothetical — it shipped. Thirty-two of
/// the thirty-nine `ContinuityEdgeController` constructions in the suite
/// stubbed the POINTER environment and let the keyboard one default, so any
/// test that drove the pointer across the edge froze the human's typing for
/// as long as the suite ran (a live `CGGetEventTapList` caught the tap with
/// 5.6 SECONDS of average latency).
///
/// So production names `AppKitContinuityKeyboardEnvironment` out loud
/// (`MirrorContinuityController`, gated by
/// `ContinuityEventTapOwnershipTests`), and forgetting to name an
/// environment now costs a plane that does nothing rather than a Mac that
/// cannot be typed on.
@MainActor
final class InertContinuityKeyboardEnvironment: ContinuityKeyboardEnvironment {
    func start(
        policy: ContinuityKeyboardCapturePolicy,
        handler: @escaping @MainActor (HostKeySample) -> Void,
        tapDisabled: @escaping @MainActor (String) -> Void
    ) -> AnyObject? { nil }

    func stop(_ token: AnyObject) {}
}
