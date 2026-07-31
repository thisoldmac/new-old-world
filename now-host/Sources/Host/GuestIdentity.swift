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

    init(text: String) {
        self.text = text
    }

    init(endpoint: NWEndpoint) {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4):
                self.init(text: Self.strip(String(describing: v4)))
            case .ipv6(let v6):
                self.init(text: Self.strip(String(describing: v6)))
            case .name(let name, _):
                self.init(text: name)
            @unknown default:
                self.init(text: String(describing: host))
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

    /// How this machine is written where a person reads it: the handle
    /// first, because that is what they will have to type, and what the
    /// machine calls itself after it, because that is what changes.
    var label: String { "\(id.slug) — \(name)" }
}
