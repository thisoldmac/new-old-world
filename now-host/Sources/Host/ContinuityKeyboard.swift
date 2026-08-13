import AppKit
import CoreGraphics

struct HostKeySample: Equatable, Sendable {
    let action: ContinuityKey.Action
    let code: UInt16
    let character: UInt8
    let modifiers: UInt16
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

@MainActor
protocol ContinuityKeyboardEnvironment: AnyObject {
    func start(_ handler: @escaping @MainActor (HostKeySample) -> Bool)
        -> AnyObject?
    func stop(_ token: AnyObject)
}

@MainActor
final class AppKitContinuityKeyboardEnvironment:
    ContinuityKeyboardEnvironment {
    private final class Context: NSObject {
        let handler: @MainActor (HostKeySample) -> Bool
        var port: CFMachPort?
        init(handler: @escaping @MainActor (HostKeySample) -> Bool) {
            self.handler = handler
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

    func start(_ handler: @escaping @MainActor (HostKeySample) -> Bool)
        -> AnyObject? {
        let context = Context(handler: handler)
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
                    return Unmanaged.passUnretained(event)
                }
                guard let sample = AppKitContinuityKeyboardEnvironment.sample(
                    event, type: type) else {
                    return Unmanaged.passUnretained(event)
                }
                let consumed = MainActor.assumeIsolated {
                    context.handler(sample)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
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
        let byte = appEvent.characters?
            .data(using: .macOSRoman, allowLossyConversion: true)?.first ?? 0
        return HostKeySample(
            action: action,
            code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            character: byte,
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
