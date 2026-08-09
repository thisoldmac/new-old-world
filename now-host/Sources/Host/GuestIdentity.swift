import Foundation
import Network
import NOWAgentIntegration

/// Which machine is on the other end — in three parts, because there are
/// three different questions and one string used to answer all of them.
///
/// - **`GuestID`** is the MACHINE: `pb1400c`. Stable, host-assigned,
///   persisted. What a person or an agent types to address a Mac.
/// - **`GuestKey`** is the SESSION: `pb1400c-<uuid>`. Minted per
///   connection. Two successive dials from one Mac are two sessions, and a
///   caller holding one can be told its session ended instead of being
///   silently retargeted at its successor.
/// - **`GuestAddress`** is the SOCKET: the peer address the host observed.
///   Authoritative for which connection, useless as a durable name.
///
/// And a fourth thing that is deliberately NOT an identity: `hello.name`.
/// It is guest-asserted, it is what the machine calls itself, and on this
/// project it CARRIES THE VERSION — a deployed guest runs under its
/// MacBinary name, so the same Mac answers as one string today and another
/// after the next deploy. Keying on it (which this file used to do) meant
/// two Macs with one name were one guest and the second was refused busy,
/// and it meant every redeploy minted a phantom machine. It is a label
/// now, shown to humans, never compared.
enum GuestIdentity {}

/// The peer address, as the host observed it off the `NWConnection`.
///
/// Host-observed, so a guest cannot misreport it — which is why the
/// machine registry anchors on this rather than on anything in the hello.
/// It is not, however, always able to tell two machines apart: every QEMU
/// guest under user-mode networking reaches this host from the loopback
/// address, and so does every test. `distinguishesMachines` is that fact
/// made explicit rather than assumed away, because a rule that silently
/// merged two emulated Macs into one row would be the same defect this
/// type exists to remove.
struct GuestAddress: Hashable, Sendable, CustomStringConvertible {
    /// Address only — never the ephemeral port. The port names a socket,
    /// not a machine, and would make every reconnection look like a new
    /// Mac.
    let text: String
    /// The remote TCP port for this exact connection. It is display-only:
    /// the registry deliberately anchors on `text`, never this ephemeral
    /// socket number.
    let port: UInt16?

    init(text: String, port: UInt16? = nil) {
        self.text = text
        self.port = port
    }

    init(endpoint: NWEndpoint) {
        switch endpoint {
        case .hostPort(let host, let port):
            let rawPort = port.rawValue
            switch host {
            case .ipv4(let v4):
                self.init(text: Self.strip(String(describing: v4)),
                          port: rawPort)
            case .ipv6(let v6):
                self.init(text: Self.strip(String(describing: v6)),
                          port: rawPort)
            case .name(let name, _):
                self.init(text: name, port: rawPort)
            @unknown default:
                self.init(text: String(describing: host), port: rawPort)
            }
        default:
            self.init(text: String(describing: endpoint))
        }
    }

    /// `IPv4Address` prints a scope suffix (`127.0.0.1%lo0`) for some
    /// interfaces; the scope is about the route, not the machine.
    private static func strip(_ raw: String) -> String {
        raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
    }

    var isLoopback: Bool {
        text == "127.0.0.1" || text == "::1" || text.hasPrefix("127.")
    }

    /// False when two different Macs can arrive here wearing this same
    /// address. Loopback is the case that actually happens on this desk.
    var distinguishesMachines: Bool { !isLoopback }

    var endpointText: String {
        guard let port else { return text }
        let host = text.contains(":") ? "[\(text)]" : text
        return "\(host):\(port)"
    }

    var description: String { text }
}

/// The stable handle for one physical Mac: `pb1400c`, `pb180c`.
///
/// A slug rather than free text because it is typed — by a person at the
/// picker and by an agent in a tool call — and because it goes in a
/// session id, where an embedded space or hyphen run would make the two
/// halves ambiguous to read back.
struct GuestID: Hashable, Sendable, Codable, CustomStringConvertible {
    let slug: String

    /// Fails rather than coercing: an id a caller cannot type back
    /// verbatim is not a handle. Callers that want coercion ask for
    /// `slugify` and see what they got.
    init?(_ raw: String) {
        let lowered = raw.lowercased()
        guard !lowered.isEmpty, lowered.count <= 40 else { return nil }
        guard lowered.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }) else { return nil }
        guard let first = lowered.first, first.isLetter || first.isNumber,
              let last = lowered.last, last.isLetter || last.isNumber
        else { return nil }
        slug = lowered
    }

    /// Best effort, for turning a human's typing into a candidate id.
    static func slugify(_ raw: String) -> GuestID? {
        var out = ""
        var lastWasDash = false
        for character in raw.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                out.append(character)
                lastWasDash = false
            } else if !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return GuestID(out)
    }

    var description: String { slug }
}

/// One connection's identity — the session id, `<machine>-<uuid>`.
///
/// This is what the listener files sessions under, and it is per
/// CONNECTION on purpose. Nothing weaker can be authoritative: two Macs
/// may share a hello name, and behind an emulator or a NAT they may share
/// an address too, so the only thing that separates them without fail is
/// the socket they arrived on.
///
/// Equality is the session UUID alone. `machine` is a snapshot of what the
/// Mac was called when the session opened, carried so a log line or a
/// dictionary key reads as something — renaming a machine mid-session does
/// NOT retitle its live session, because a caller holding
/// `guest-2-<uuid>` must keep being able to present it.
struct GuestKey: Hashable, Sendable, CustomStringConvertible {
    /// The machine id at the moment this session opened.
    let machine: GuestID
    let session: UUID

    var text: String { "\(machine.slug)-\(session.uuidString.lowercased())" }
    var description: String { text }

    static func == (lhs: GuestKey, rhs: GuestKey) -> Bool {
        lhs.session == rhs.session
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(session)
    }

    /// Parses a session id back into its parts, so a caller's string can
    /// be compared to a live session without string-matching at the call
    /// site. Returns nil for anything that is not this shape — an agent
    /// that passes a machine id where a session id belongs gets told so
    /// rather than silently matching nothing.
    static func parse(_ text: String) -> GuestKey? {
        // The UUID is the last five hyphen-separated groups; the machine
        // id is everything before it and may itself contain hyphens.
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 6 else { return nil }
        let uuidText = parts.suffix(5).joined(separator: "-")
        guard let uuid = UUID(uuidString: uuidText) else { return nil }
        let machineText = parts.dropLast(5).joined(separator: "-")
        guard let machine = GuestID(machineText) else { return nil }
        return GuestKey(machine: machine, session: uuid)
    }

    /// A key with no connection behind it, for tests and previews.
    ///
    /// Deterministic in the label, so two calls with "A" are the same
    /// machine and "A" and "B" are not. The live path never uses this: a
    /// real key is minted at hello, by the listener, from the registry's
    /// answer.
    static func synthetic(_ label: String) -> GuestKey {
        var digest = UInt64(14695981039346656037)
        for byte in label.utf8 {
            digest = (digest ^ UInt64(byte)) &* 1099511628211
        }
        let high = String(format: "%016llx", digest)
        let low = String(format: "%016llx", digest &* 31 &+ 7)
        let hex = high + low
        let uuidText = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return GuestKey(
            machine: GuestID.slugify(label) ?? GuestID("guest")!,
            session: UUID(uuidString: uuidText) ?? UUID())
    }
}

/// One connected guest, in the shape a list of them wants: enough to
/// name it, address it and choose it, and nothing that would go stale.
///
/// Both halves of the pairing are here — `id` (what you type) and
/// `address` (what the host saw) — because the requirement is that a Mac
/// is exposed BY NAME with the name mapped to its address, and a roster
/// that carried only one of them would push the other back into somebody's
/// head. `name` is beside them and is neither: it is what the machine
/// calls itself today.
struct ConnectedGuest: Identifiable, Equatable, Sendable {
    var key: GuestKey
    /// The stable machine handle. Equals `key.machine` unless the machine
    /// was renamed after this session opened.
    var id: GuestID
    /// True while the id is the host's own auto-assigned ordinal — nobody
    /// has named this Mac yet. It still addresses the machine; it just
    /// says nothing about it.
    var idIsAutoAssigned: Bool
    /// False when the host cannot tell two machines apart at this address
    /// (loopback, and therefore every emulated guest), so the id's
    /// stability across reconnection is a guess rather than a fact.
    var idIsAnchored: Bool
    /// What the guest calls itself. Version-bearing, guest-asserted, for
    /// humans only.
    var name: String
    /// Host-owned title, defaulted from `name` and independently editable.
    /// Nil only in fixtures or while reading a pre-display-name record.
    var displayName: String? = nil
    /// Host port this machine's connection was accepted on. Unlike the
    /// remote source port in `address`, this is stable and useful to a person.
    var listenPort: UInt16? = nil
    var address: GuestAddress
    var version: String?
    /// The build this machine reported at `hello`, when it reported one.
    /// Nil is "did not say", not "same as the last one".
    var build: String? = nil
    /// This machine's answer at `hello` about being driven by an agent.
    /// Nil is "did not say", which is not the same as a yes.
    var agentAccess: AgentIntegrationGuestAccess? = nil
    var operatingSystem: String?
    var connectedAt: Date
    /// True for the one the single-guest API — the console, the modules,
    /// the agent projection — is currently driving.
    var isActive: Bool

    /// The session id a caller holds to mean "this connection, not its
    /// successor".
    var sessionID: String { key.text }

    /// The host-owned title shown to a person, falling back to the name
    /// reported at hello while legacy records acquire a display name.
    var label: String { displayName ?? name }
}

/// **Which machine's art belongs to this guest** — the asset-pack key,
/// derived in exactly one place.
///
/// A fifth thing this file names, and the one that is deliberately NOT a
/// machine identity. `GuestID` answers "which Mac"; this answers "which
/// KIND of Mac, running which System", and it is meant to collide: two
/// PowerBook 1400cs running 9.1 have the same key, and should, because a
/// pack extracted from one is the right pack for the other. That is what
/// makes a pack shareable at all (plan 021 §1).
///
/// **Everything it reads is typed.** The facts arrive as `hello.machine`
/// and `hello.os` rather than being parsed out of the census's display
/// strings — which the two guests spell differently (`Mac OS` against
/// `System`, and `Model`'s raw column a name on one guest and a decimal
/// on the other). A per-guest label map would be a third place to keep in
/// agreement by hand, with nothing failing the build when a guest changed
/// a word.
struct AssetPackKey: Hashable, Sendable, CustomStringConvertible {
    /// `gestaltMachineType`, where the guest could establish it.
    let machineID: Int?
    /// The machine's own name for itself. Kept even when `machineID` is
    /// present: it is what a person reads in the pack list, and a key
    /// nobody can recognise is a key nobody will choose correctly.
    let machineModel: String?
    /// `major.minor.bugfix`, from the shared decode both guests use.
    let systemVersion: String?

    /// **False when this guest did not tell us enough to key anything.**
    ///
    /// The case that matters is a guest built before 2026-08-07: it sends
    /// no `machine` at all and an `os` that is a compiled-in literal, so
    /// there is nothing here to trust. A pack must NOT be auto-selected
    /// from a key like that — it would silently dress one machine in
    /// another's art, which is the exact failure the provenance rules
    /// exist to prevent. Selection stays manual, and the UI says why.
    var isComplete: Bool {
        guard let systemVersion, systemVersion != Self.unknown,
              !systemVersion.isEmpty else { return false }
        if let machineID, machineID != 0 { return true }
        guard let machineModel, machineModel != Self.unknown,
              !machineModel.isEmpty else { return false }
        return true
    }

    /// The guest-side word for "we looked and could not establish it",
    /// spelled once here to match `contract/guest_identity.h`. Distinct
    /// from nil, which means the guest never said.
    static let unknown = "unknown"

    init(hello: Hello) {
        self.machineID = hello.machine?.id
        self.machineModel = hello.machine?.model
        self.systemVersion = hello.os
    }

    init(machineID: Int?, machineModel: String?, systemVersion: String?) {
        self.machineID = machineID
        self.machineModel = machineModel
        self.systemVersion = systemVersion
    }

    /// The stable comparison key: the machine id where there is one, the
    /// model name where there is not.
    ///
    /// The id LEADS because a model name is localised and a Sharing-name
    /// fallback can change under a person's hands, while the number is
    /// the same on every System. The model is the fallback rather than
    /// the primary for that reason, not because it is less readable.
    var identity: String {
        let machine: String
        if let machineID, machineID != 0 {
            machine = "m\(machineID)"
        } else if let machineModel, !machineModel.isEmpty,
                  machineModel != Self.unknown {
            machine = Self.slug(machineModel)
        } else {
            machine = Self.unknown
        }
        let system = (systemVersion.map(Self.slug) ?? Self.unknown)
        return "\(machine)-os\(system.isEmpty ? Self.unknown : system)"
    }

    /// What a person reads in the pack list. Names what is missing rather
    /// than eliding it: "PowerBook 1400c — System unknown" is a usable
    /// sentence and "PowerBook 1400c" alone is a claim.
    var description: String {
        let machine = (machineModel?.isEmpty == false ? machineModel! : nil)
            ?? machineID.flatMap { $0 == 0 ? nil : "machine type \($0)" }
            ?? "unknown machine"
        let system = (systemVersion?.isEmpty == false ? systemVersion! : nil)
            ?? Self.unknown
        return "\(machine) — System \(system)"
    }

    /// Lowercase, ASCII alphanumerics and dots kept, everything else a
    /// hyphen. A directory name a person can read and a shell will not
    /// fight; the authoritative key lives in the pack's manifest, so this
    /// never has to be parsed back.
    private static func slug(_ raw: String) -> String {
        var out = ""
        var lastWasSeparator = false
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == ".") {
                out.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator && !out.isEmpty {
                out.append("-")
                lastWasSeparator = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
