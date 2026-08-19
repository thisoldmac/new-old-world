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
///    emulated guest and every test), the anchor is completed by the
///    machine's own PORT, and then by a SLOT. A person who gives each Mac
///    its own port has stated the distinction the address cannot carry, and
///    it holds whatever order they dial in. Without one, the first live
///    connection with that anchor takes slot 0 and a concurrent second
///    takes slot 1 — a guess, labelled one: `idIsAnchored` stays false for
///    the whole life of such a session either way, because the host is
///    trusting configuration rather than observing a difference.
@MainActor
final class GuestRegistry {
    /// One machine, as the host remembers it.
    struct Record: Codable, Equatable {
        /// The registry's exact identity for one record. Machine ids are
        /// human-editable and legacy data may contain duplicates; the anchor
        /// tuple is what `identify` already uses to distinguish records.
        struct Key: Hashable, Sendable {
            let address: String
            let fingerprint: String
            /// The host port this machine dials — **and only where the
            /// address cannot tell machines apart.**
            ///
            /// This is rule 4 again, with a better instrument. Behind an
            /// emulator every guest arrives from the loopback address
            /// wearing the same fingerprint, and the anchor was completed
            /// by `slot` alone: assigned in the order they dialled, so the
            /// machines swapped identities whenever they came up in the
            /// other order. A port a person configured is a fact about the
            /// machine, and it does not reorder itself.
            ///
            /// At a routable address it is deliberately NOT part of the
            /// anchor. There, address and fingerprint already identify one
            /// Mac; folding the port in would mean a machine repointed at a
            /// new port arrived as a stranger and lost its name, which is a
            /// person's ordinary reconfiguration turned into data loss.
            ///
            /// Nil therefore means either "this address distinguishes" or
            /// "written before ports scoped a profile" — the second is
            /// adopted rather than duplicated, see `identify`.
            let listenPort: UInt16?
            let slot: Int
        }

        /// The port as the ANCHOR sees it: nil wherever the address is
        /// enough on its own. One place, because `identify` and `key` must
        /// agree or a record would be findable by one and not the other.
        static func anchorPort(address: String,
                               listenPort: UInt16?) -> UInt16? {
            GuestAddress(text: address).distinguishesMachines
                ? nil : listenPort
        }

        var id: GuestID
        var address: String
        var fingerprint: String
        var slot: Int
        /// True until a human names the machine.
        var autoAssigned: Bool
        var lastSeen: Date
        var lastName: String
        /// Host-owned title. Nil only for records written before display
        /// names existed; those are upgraded on their next connection.
        var displayName: String? = nil
        /// **This profile's own host port** — the one the host binds for
        /// this machine and the one its generated settings tell it to dial.
        ///
        /// It began as a record of where a guest happened to arrive, which
        /// was enough to print an address and nothing more. It is now the
        /// profile's port: host-observed on first sight, thereafter editable
        /// by a person, and bound by the listener whether or not the machine
        /// is here. That promotion is what lets one desk serve several Macs
        /// that cannot otherwise be told apart.
        ///
        /// Nil is a record written before this existed, or a machine that
        /// has never connected. Both mean "the host's default port", which
        /// is why an existing single-guest desk needs no migration.
        var listenPort: UInt16? = nil

        var key: Key {
            Key(address: address, fingerprint: fingerprint,
                listenPort: Self.anchorPort(address: address,
                                            listenPort: listenPort),
                slot: slot)
        }
    }

    /// What a rename could not do, in the caller's words.
    enum RenameFailure: Error, Equatable {
        case notFound
        case malformed
        /// Another machine already holds it. Named, so the human can go
        /// and free it rather than guess.
        case taken(by: String)
    }

    enum DisplayNameFailure: Error, Equatable {
        case notFound
        case empty
        case tooLong
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
    private let ordinalKey: String
    private var records: [Record] = []
    private var nextOrdinalNumber = 1

    init(defaults: UserDefaults? = nil,
         storageKey: String = "guestRegistry.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        ordinalKey = storageKey + ".nextOrdinal"
        load()
        let stored = defaults?.integer(forKey: ordinalKey) ?? 0
        let afterExisting = records.compactMap { Self.ordinal($0.id) }
            .max().map { $0 + 1 } ?? 1
        nextOrdinalNumber = max(max(1, stored), afterExisting)
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
    /// non-distinguishing address does not take the first one's id. The
    /// anchor now includes `listenPort`, so the caller must count slots per
    /// PORT: two Macs that dial their own ports are both slot 0, and
    /// counting them together would hand the second one the first's slot
    /// and undo the very distinction the port was configured to make.
    func identify(address: GuestAddress,
                  name: String?,
                  operatingSystem: String?,
                  occupiedSlots: Set<Int>,
                  listenPort: UInt16? = nil,
                  now: Date = Date()) -> Record {
        let print = Self.fingerprint(name: name, operatingSystem: operatingSystem)
        var slot = 0
        while occupiedSlots.contains(slot) { slot += 1 }

        /* The port is part of the anchor now, so the match is exact first.
           The fallback is the upgrade path and nothing else: a record
           written before profiles had ports carries no port at all, and
           re-matching it here — rather than letting the exact test miss and
           mint a second row — is what keeps a desk's machine ids, display
           names and rename history across the version that adds this. It
           adopts the port it arrived on, so it upgrades once and is exact
           from then on. */
        /* The port completes the anchor only where the address cannot.
           At a routable address a Mac that moves ports is the same Mac. */
        let anchored = !address.distinguishesMachines
        let exact = records.firstIndex {
            $0.address == address.text && $0.fingerprint == print
                && $0.slot == slot
                && (!anchored || $0.listenPort == listenPort)
        }
        let legacy = (exact == nil && anchored) ? records.firstIndex {
            $0.address == address.text && $0.fingerprint == print
                && $0.listenPort == nil && $0.slot == slot
        } : nil

        if let index = exact ?? legacy {
            if records[index].displayName == nil {
                records[index].displayName = nextDisplayName(
                    basedOn: name, excluding: index)
            }
            records[index].lastSeen = now
            records[index].lastName = name ?? Session.unnamedGuest
            if let listenPort { records[index].listenPort = listenPort }
            save()
            return records[index]
        }

        let displayName = nextDisplayName(basedOn: name)
        let record = Record(
            id: nextOrdinal(), address: address.text, fingerprint: print,
            slot: slot, autoAssigned: true, lastSeen: now,
            lastName: name ?? Session.unnamedGuest,
            displayName: displayName, listenPort: listenPort)
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
        if let clash = records.enumerated().first(where: {
            $0.offset != index && $0.element.id == wanted
        })?.element {
            return .failure(.taken(by: clash.lastName))
        }
        records[index].id = wanted
        records[index].autoAssigned = false
        save()
        return .success(wanted)
    }

    /// Changes only the human-facing title. Stable addressing remains on
    /// `GuestID`, so spaces and punctuation here never enter a session id.
    @discardableResult
    func renameDisplayName(_ key: Record.Key, to proposed: String)
        -> Result<String, DisplayNameFailure> {
        let wanted = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .failure(.empty) }
        guard wanted.count <= 80 else { return .failure(.tooLong) }
        guard let index = records.firstIndex(where: { $0.key == key })
        else { return .failure(.notFound) }
        records[index].displayName = wanted
        save()
        return .success(wanted)
    }

    /// The record currently holding an id, if any.
    func record(for id: GuestID) -> Record? {
        records.first { $0.id == id }
    }

    /// **Gives one machine its own port.**
    ///
    /// The port is part of the record's key, so this moves the record to a
    /// new key — which is exactly what it means: the same Mac, expected
    /// somewhere else. The id, the display name and the rename history ride
    /// along, because they belong to the machine and not to the socket.
    ///
    /// Refuses a port another profile already claims. Two profiles on one
    /// port is not an error the listener could report — it binds once and
    /// serves both — it is a person believing they have separated two Macs
    /// when they have not, which is the failure this whole seam exists to
    /// remove. `nil` returns the machine to the host's default port.
    @discardableResult
    func setListenPort(_ key: Record.Key, to port: UInt16?)
        -> Result<UInt16?, PortFailure> {
        if let port, port == 0 { return .failure(.reserved) }
        guard let index = records.firstIndex(where: { $0.key == key })
        else { return .failure(.notFound) }
        guard records[index].listenPort != port else { return .success(port) }
        if let port, let clash = records.enumerated().first(where: {
            $0.offset != index && $0.element.listenPort == port
        })?.element {
            return .failure(.taken(by: clash.displayName ?? clash.lastName))
        }
        records[index].listenPort = port
        save()
        return .success(port)
    }

    /// **Every port this host must bind to serve the machines it remembers.**
    ///
    /// Derived rather than stored, and derived HERE rather than at the
    /// listener, because the book is the only thing that knows what a
    /// profile expects. `base` is the host's default and is always included:
    /// a machine with no port of its own dials it, and so does a Mac nobody
    /// has met yet — which is every Mac, once.
    func portsToBind(base: UInt16) -> [UInt16] {
        var ports = [base]
        for record in records {
            guard let port = record.listenPort, port != 0,
                  !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    enum PortFailure: Error, Equatable {
        case notFound
        /// Port 0 asks the OS for an ephemeral port, which is meaningless
        /// as a profile's port: nothing could be told to dial it.
        case reserved
        /// Another profile already expects this port, named so the human
        /// can go and free it rather than guess.
        case taken(by: String)
    }

    /// Removes one remembered machine. A live socket is owned by the
    /// listener and must be closed there first; this only edits the book the
    /// host will consult if that machine appears again.
    @discardableResult
    func forget(_ key: Record.Key) -> Bool {
        guard let index = records.firstIndex(where: { $0.key == key })
        else { return false }
        records.remove(at: index)
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
        while records.contains(where: {
            $0.id.slug == "guest-\(nextOrdinalNumber)"
        }) {
            nextOrdinalNumber += 1
        }
        let id = GuestID("guest-\(nextOrdinalNumber)")!
        nextOrdinalNumber += 1
        defaults?.set(nextOrdinalNumber, forKey: ordinalKey)
        return id
    }

    private static func ordinal(_ id: GuestID) -> Int? {
        guard id.slug.hasPrefix("guest-") else { return nil }
        return Int(id.slug.dropFirst("guest-".count))
    }

    private func nextDisplayName(basedOn proposed: String?,
                                 excluding excludedIndex: Int? = nil) -> String {
        let trimmed = proposed?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? Session.unnamedGuest : trimmed
        let taken: Set<String> = Set(records.enumerated().compactMap {
            index, record in
            guard index != excludedIndex else { return nil }
            return (record.displayName ?? record.lastName).lowercased()
        })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)-\(suffix)"
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
