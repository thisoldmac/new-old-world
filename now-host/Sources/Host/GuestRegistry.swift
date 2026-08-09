import Foundation

/// Who a machine is, and what it may be called — the host's own book.
///
/// **Where the id comes from, and why here.** Nothing on the wire carries a
/// stable machine identity, and nothing on these machines can be made to.
/// Gestalt has no serial number: `gestaltMachineType` is the MODEL (two
/// PowerBook 1400cs answer the same thing), and `gestaltSerialAttr` — which
/// is what a search for "serial" finds — describes the machine's serial
/// PORTS, not a serial number. Do not go looking again. The remaining
/// candidates each fail on this desk: the boot volume's creation date is
/// duplicated by a cloned disk; a self-assigned id in the guest's own
/// preferences is minted afresh whenever a side build deploys under another
/// name, because preferences key off the binary's name (AGENTS.md,
/// "Deploying to the PowerBook"); PRAM is wiped every power cycle on the
/// 180c, whose battery is dead; and the Ethernet address belongs to a
/// SCSI-Ethernet dongle that moves between machines.
///
/// So the id is assigned HERE, by the host, and persisted here. That is a
/// deliberate smaller shape than the real fix, which is a new optional
/// `hello` field carrying a guest-minted stable id — a contract change and
/// both guests, written up as the next slice in docs/open-issues.md and
/// NOT half-implemented here.
///
/// **The anchor is the observed address plus a fingerprint.** The address
/// is the one fact a guest cannot misreport. The fingerprint is the hello's
/// os and its name WITH THE VERSION STRIPPED, so a redeploy does not look
/// like a new machine, and so a stranger that inherits an old DHCP lease
/// does not silently inherit the name of the Mac that used to hold it.
///
/// **The rules, in one place because they must not drift apart:**
///
/// 1. A first-sight machine is addressable with zero configuration: it is
///    assigned the next ordinal, `guest-1`, `guest-2`. Auto-assigned, and
///    the roster says so.
/// 2. Two machines never collapse onto one id. Ordinals are unique by
///    construction, and a rename onto an id another machine holds is
///    REFUSED with a reason rather than unbinding the other silently.
/// 3. An id never silently rebinds. Adoption requires the address AND the
///    fingerprint to match. A machine that redials from a new address is a
///    new record and costs the human one rename; that is the deliberate
///    trade, because the alternative — adopting on address alone — hands
///    `pb1400c` to whoever picks up the lease next.
/// 4. Where the address cannot tell machines apart (loopback, and so every
///    emulated guest and every test), the anchor is completed by a SLOT:
///    the first live connection with that anchor takes slot 0, a
///    concurrent second takes slot 1. Reconnection into a free slot
///    re-adopts its id. This is a guess and is labelled one —
///    `idIsAnchored` is false for the whole life of such a session.
@MainActor
final class GuestRegistry {
    /// One machine, as the host remembers it.
    struct Record: Codable, Equatable {
        var id: GuestID
        var address: String
        var fingerprint: String
        var slot: Int
        /// True until a human names the machine.
        var autoAssigned: Bool
        var lastSeen: Date
        var lastName: String
    }

    /// What a rename could not do, in the caller's words.
    enum RenameFailure: Error, Equatable {
        case notFound
        case malformed
        /// Another machine already holds it. Named, so the human can go
        /// and free it rather than guess.
        case taken(by: String)
    }

    /// Where the book lives between launches. `UserDefaults` because the
    /// host already keeps its preferences there and a second store would
    /// be a second thing to lose.
    ///
    /// **Nil means memory-only, and that is the DEFAULT.** Persistence is
    /// something the app asks for once, where it builds its listener; a
    /// registry that persisted by default would have every test run and
    /// every fake guest writing machine records into the developer's own
    /// preferences, which is both noise and a way for one test to change
    /// what the next one sees.
    private let defaults: UserDefaults?
    private let storageKey: String
    private var records: [Record] = []

    init(defaults: UserDefaults? = nil,
         storageKey: String = "guestRegistry.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    /// Every machine the host has ever seen, newest first. The roster of
    /// CONNECTED guests is a different list and is built from live
    /// sessions — a record here can never put a row on screen, which is
    /// how a machine that left cannot shadow one that is here.
    var known: [Record] {
        records.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// The id for an arriving connection.
    ///
    /// `occupiedSlots` is the set of slots the caller already has live for
    /// this same anchor, so a concurrent second machine at a
    /// non-distinguishing address does not take the first one's id.
    func identify(address: GuestAddress,
                  name: String?,
                  operatingSystem: String?,
                  occupiedSlots: Set<Int>,
                  now: Date = Date()) -> Record {
        let print = Self.fingerprint(name: name, operatingSystem: operatingSystem)
        var slot = 0
        while occupiedSlots.contains(slot) { slot += 1 }

        if let index = records.firstIndex(where: {
            $0.address == address.text && $0.fingerprint == print
                && $0.slot == slot
        }) {
            records[index].lastSeen = now
            records[index].lastName = name ?? Session.unnamedGuest
            save()
            return records[index]
        }

        let record = Record(
            id: nextOrdinal(), address: address.text, fingerprint: print,
            slot: slot, autoAssigned: true, lastSeen: now,
            lastName: name ?? Session.unnamedGuest)
        records.append(record)
        save()
        return record
    }

    /// Names a machine. The one operation that makes an id durable.
    @discardableResult
    func rename(_ current: GuestID, to proposed: String)
        -> Result<GuestID, RenameFailure> {
        guard let wanted = GuestID.slugify(proposed) else {
            return .failure(.malformed)
        }
        guard let index = records.firstIndex(where: { $0.id == current })
        else { return .failure(.notFound) }
        if let clash = records.first(where: {
            $0.id == wanted && $0.address != records[index].address
        }) {
            return .failure(.taken(by: clash.lastName))
        }
        records[index].id = wanted
        records[index].autoAssigned = false
        save()
        return .success(wanted)
    }

    /// The record currently holding an id, if any.
    func record(for id: GuestID) -> Record? {
        records.first { $0.id == id }
    }

    /// Removes one remembered machine. A live socket is owned by the
    /// listener and must be closed there first; this only edits the book the
    /// host will consult if that machine appears again.
    @discardableResult
    func forget(_ id: GuestID) -> Bool {
        let before = records.count
        records.removeAll { $0.id == id }
        guard records.count != before else { return false }
        save()
        return true
    }

    /// Strips the version off a guest-asserted name.
    ///
    /// `hello.name` is the deployed binary's name and the version rides in
    /// it, so "NOW-68K 0.14" and "NOW-68K 0.15" are the same product on the
    /// same Mac. What is left is a PRODUCT fingerprint, not an identity —
    /// it is only ever used to notice that the thing at a remembered
    /// address is not the thing that used to be there.
    static func fingerprint(name: String?, operatingSystem: String?) -> String {
        let raw = (name ?? Session.unnamedGuest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var words = raw.split(separator: " ").map(String.init)
        while let last = words.last, Self.looksLikeVersion(last) {
            words.removeLast()
        }
        let product = words.isEmpty ? raw : words.joined(separator: " ")
        return "\(product.lowercased())|"
            + "\(operatingSystem?.lowercased() ?? "")"
    }

    /// A trailing "0.14", "v1.2.3", "1400c" is not a version — the last is
    /// a model number and part of the name — so the test is digits and dots
    /// with at least one dot, optionally prefixed by `v`.
    private static func looksLikeVersion(_ word: String) -> Bool {
        var text = word
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard text.contains("."), !text.isEmpty else { return false }
        return text.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func nextOrdinal() -> GuestID {
        var n = 1
        while records.contains(where: { $0.id.slug == "guest-\(n)" }) { n += 1 }
        return GuestID("guest-\(n)")!
    }

    private func load() {
        guard let data = defaults?.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let defaults,
              let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
