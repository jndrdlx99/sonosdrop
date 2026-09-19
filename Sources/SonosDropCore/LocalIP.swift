import Foundation
import Darwin

public enum LocalIP {
    /// First IPv4 on a running "en*" interface (Wi-Fi/Ethernet), else any running, non-loopback,
    /// non-link-local IPv4. Link-local (169.254.x.x) addresses are self-assigned when DHCP fails
    /// and are not reachable from another device on the LAN, so they are never usable as the
    /// media server's advertised address.
    public static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: ifa.ifa_name), ip))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }
}
