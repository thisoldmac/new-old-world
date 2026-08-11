import Darwin
import Foundation
import Network

/// Chooses a useful address for the instruction shown before the browser has
/// connected. Once it does connect, the portal prefers that socket's actual
/// local endpoint for the generated settings file.
enum HostAddressDetector {
    static func primaryIPv4() -> String? {
        candidates().sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.name.localizedStandardCompare(right.name)
                == .orderedAscending
        }.first?.address
    }

    static func text(_ host: NWEndpoint.Host) -> String {
        String(describing: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }
            guard let socket = entry.ifa_addr,
                  socket.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw") else { continue }
            let ipv4 = UnsafeRawPointer(socket)
                .assumingMemoryBound(to: sockaddr_in.self).pointee
            var address = ipv4.sin_addr
            var buffer = [CChar](repeating: 0,
                                 count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer,
                            socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(
                decoding: buffer.prefix { $0 != 0 }.map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self)
            guard !text.hasPrefix("169.254.") else { continue }
            result.append(Candidate(name: name, address: text,
                                    rank: rank(name: name, address: text)))
        }
        return result
    }

    private static func rank(name: String, address: String) -> Int {
        let privateAddress = address.hasPrefix("10.")
            || address.hasPrefix("192.168.")
            || isPrivate172(address)
        if name.hasPrefix("en") && privateAddress { return 0 }
        if privateAddress { return 1 }
        if name.hasPrefix("en") { return 2 }
        return 3
    }

    private static func isPrivate172(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts[0] == "172",
              let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }

    private struct Candidate {
        let name: String
        let address: String
        let rank: Int
    }
}
