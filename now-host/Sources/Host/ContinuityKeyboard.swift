import AppKit
import CoreGraphics

struct HostKeySample: Equatable, Sendable {
    let action: ContinuityKey.Action
    let code: UInt16
    let character: UInt8
    let modifiers: UInt16
}

struct ContinuityKeyboardCapturePolicy: Equatable, Sendable {
    let forwardingEnabled: Bool
    let escapeShortcut: ContinuityEscapeShortcut

    func captures(_ sample: HostKeySample) -> Bool {
        forwardingEnabled || escapeShortcut.matches(sample)
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
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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
                guard context.policy.captures(sample) else {
                    return Unmanaged.passUnretained(event)
                }
                /* The tap's watchdog covers this callback, not the later main
                   actor hop. Decide ownership and suppress synchronously, then
                   let the normal controller enqueue the reliable wire event. */
                let deliver = context.handler
                Task { @MainActor in deliver(sample) }
                return nil
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
            modifiers: classicModifiers(appEvent.modifierFlags))
    }

    private static func classicModifiers(_ flags: NSEvent.ModifierFlags)
        -> UInt16 {
        var value: UInt16 = 0
        if flags.contains(.command) { value |= 1 << 8 }
        if flags.contains(.shift) { value |= 1 << 9 }
        if flags.contains(.capsLock) { value |= 1 << 10 }
        if flags.contains(.option) { value |= 1 << 11 }
        if flags.contains(.control) { value |= 1 << 12 }
        return value
    }
}
