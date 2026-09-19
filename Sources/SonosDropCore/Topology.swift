import Foundation
import Darwin

public enum TopologyParser {
    public static func parse(_ xml: String) -> [SpeakerGroup] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.groups
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var groups: [SpeakerGroup] = []
        private var coordinator = ""
        private var members: [(uuid: String, ip: String, name: String, invisible: Bool)] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            switch elementName {
            case "ZoneGroup":
                coordinator = a["Coordinator"] ?? ""
                members = []
            case "ZoneGroupMember", "Satellite":
                guard let uuid = a["UUID"], let loc = a["Location"], let host = URL(string: loc)?.host else { return }
                members.append((uuid, host, a["ZoneName"] ?? "", a["Invisible"] == "1"))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard elementName == "ZoneGroup", let coord = members.first(where: { $0.uuid == coordinator }) else { return }
            let visible = members.filter { !$0.invisible }
            guard !visible.isEmpty else { return }
            var names: [String] = []
            for m in visible where !names.contains(m.name) { names.append(m.name) }
            groups.append(SpeakerGroup(coordinatorUUID: coordinator, coordinatorIP: coord.ip,
                                       name: names.joined(separator: " + "), memberIPs: members.map(\.ip)))
        }
    }
}

public enum SSDP {
    public static func searchMessage() -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
    }

    public static func locationHost(inReply reply: String) -> String? {
        for line in reply.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            return URL(string: value)?.host
        }
        return nil
    }

    /// Multicast M-SEARCH twice, collect unique reply hosts until the timeout. Blocking work runs off the caller's thread.
    public static func discoverHosts(timeout: TimeInterval = 3) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: blockingSearch(timeout: timeout)) }
        }
    }

    static func blockingSearch(timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = Array(searchMessage().utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, msg, msg.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var hosts = Set<String>()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if let s = String(bytes: buf[0..<Int(n)], encoding: .utf8), let host = locationHost(inReply: s) { hosts.insert(host) }
        }
        return hosts.sorted()
    }
}
