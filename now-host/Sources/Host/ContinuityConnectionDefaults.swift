import Foundation
import SwiftUI

/// **What a Mac that has never connected before starts with.**
///
/// `MirrorContinuityController.loadSettingsForActiveGuest` falls back to
/// these values when a machine has none of its own per-machine keys yet
/// (`rateKey(for:)` and its siblings, all suffixed with the machine's slug).
/// Before this type existed those fallbacks were literal constants inlined
/// in the loader — 30 Hz, a 0.75s reconnect delay, and so on — with no way
/// to change them short of editing source. This is the same values, moved
/// into their own global (not per-machine) `UserDefaults` keys so Settings'
/// "Defaults for New Connections" tab can edit them.
///
/// Editing a value here never touches a machine that already has its own
/// saved settings — those live under the per-machine keys this type does
/// not read or write, and stay in-module on the Continuity page.
struct ContinuityConnectionDefaults {
    let defaults: UserDefaults

    enum Keys {
        static let rate = "mirror.continuity.defaults.rate"
        static let autoReconnect = "mirror.continuity.defaults.autoReconnect"
        static let reconnectDelay = "mirror.continuity.defaults.reconnectDelay"
        static let keyboardForwarding =
            "mirror.continuity.defaults.keyboardForwarding"
        static let escapeShortcut =
            "mirror.continuity.defaults.escapeShortcut"

        static func option(_ id: ContinuityOptionID) -> String {
            "mirror.continuity.defaults.option.\(id.rawValue)"
        }
    }

    init(defaults: UserDefaults = ProductIdentity.defaults) {
        self.defaults = defaults
    }

    /// Matches the loader's own guard: an out-of-range stored value (a
    /// hand-edited default, or none yet) reads back as 30, the same floor
    /// the per-machine loader already enforced.
    var rate: Int {
        get {
            let stored = defaults.integer(forKey: Keys.rate)
            return [15, 30, 60].contains(stored) ? stored : 30
        }
        nonmutating set {
            guard [15, 30, 60].contains(newValue) else { return }
            defaults.set(newValue, forKey: Keys.rate)
        }
    }

    /// Off by default, matching the literal the per-machine loader used to
    /// read every unset key as (`defaults.bool(forKey:)` on a missing key).
    var autoReconnect: Bool {
        get { defaults.bool(forKey: Keys.autoReconnect) }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.autoReconnect)
        }
    }

    var reconnectDelay: Double {
        get {
            defaults.object(forKey: Keys.reconnectDelay) == nil
                ? 0.75
                : Self.clampReconnectDelay(
                    defaults.double(forKey: Keys.reconnectDelay))
        }
        nonmutating set {
            defaults.set(Self.clampReconnectDelay(newValue),
                         forKey: Keys.reconnectDelay)
        }
    }

    var keyboardForwarding: Bool {
        get {
            defaults.object(forKey: Keys.keyboardForwarding) == nil
                ? true : defaults.bool(forKey: Keys.keyboardForwarding)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.keyboardForwarding)
        }
    }

    var escapeShortcut: ContinuityEscapeShortcut {
        get {
            defaults.string(forKey: Keys.escapeShortcut)
                .flatMap(ContinuityEscapeShortcut.init(rawValue:))
                ?? .controlOptionEscape
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Keys.escapeShortcut)
        }
    }

    func optionEnabled(_ option: ContinuityOptionDescriptor) -> Bool {
        let key = Keys.option(option.id)
        return defaults.object(forKey: key) == nil
            ? option.defaultEnabled : defaults.bool(forKey: key)
    }

    func setOptionEnabled(_ enabled: Bool,
                          for option: ContinuityOptionDescriptor) {
        defaults.set(enabled, forKey: Keys.option(option.id))
    }

    /* Same range `MirrorContinuityController.clampReconnectDelay` enforces
       on the per-machine value — kept here too so a hand-edited default
       cannot hand a fresh machine an insane wait, mirroring that guard's
       own comment: too low spins scheduleReconnect, too high reads as a
       hang after the pointer returns to the host. */
    private static func clampReconnectDelay(_ value: Double) -> Double {
        min(max(value, 0.1), 5.0)
    }
}

/// The editable form of `ContinuityConnectionDefaults` Settings' tab binds
/// to, following the same shape as `MCPTransportSettingsModel` beside
/// `MCPTransportPreferences`: a plain `UserDefaults`-backed struct for
/// every other reader, and one `@Published`-carrying class for the one
/// place that needs two-way SwiftUI bindings.
@MainActor
final class ContinuityConnectionDefaultsModel: ObservableObject {
    @Published var rate: Int {
        didSet { store.rate = rate }
    }
    @Published var autoReconnect: Bool {
        didSet { store.autoReconnect = autoReconnect }
    }
    @Published var reconnectDelay: Double {
        didSet { store.reconnectDelay = reconnectDelay }
    }
    @Published var keyboardForwarding: Bool {
        didSet { store.keyboardForwarding = keyboardForwarding }
    }
    @Published var escapeShortcut: ContinuityEscapeShortcut {
        didSet { store.escapeShortcut = escapeShortcut }
    }

    private let store: ContinuityConnectionDefaults
    private var optionValues: [ContinuityOptionID: Bool]

    init(defaults: UserDefaults) {
        let store = ContinuityConnectionDefaults(defaults: defaults)
        self.store = store
        rate = store.rate
        autoReconnect = store.autoReconnect
        reconnectDelay = store.reconnectDelay
        keyboardForwarding = store.keyboardForwarding
        escapeShortcut = store.escapeShortcut
        optionValues = Dictionary(uniqueKeysWithValues:
            ContinuityOptionCatalog.all.map { ($0.id, store.optionEnabled($0)) })
    }

    func optionBinding(_ option: ContinuityOptionDescriptor) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.optionValues[option.id] ?? option.defaultEnabled
            },
            set: { [weak self] enabled in
                guard let self else { return }
                objectWillChange.send()
                optionValues[option.id] = enabled
                store.setOptionEnabled(enabled, for: option)
            })
    }
}
