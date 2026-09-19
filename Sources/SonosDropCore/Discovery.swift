import Foundation

public protocol GroupDiscovering: Sendable {
    func groups(manualIP: String?) async throws -> [SpeakerGroup]
}

public final class Discovery: GroupDiscovering, @unchecked Sendable {
    private let client: SonosControlling
    private let ssdp: @Sendable (TimeInterval) async -> [String]

    public init(client: SonosControlling, ssdp: @escaping @Sendable (TimeInterval) async -> [String] = { await SSDP.discoverHosts(timeout: $0) }) {
        self.client = client
        self.ssdp = ssdp
    }

    /// Manual IP wins when given; otherwise the first SSDP responder is asked for the whole household.
    public func groups(manualIP: String?) async throws -> [SpeakerGroup] {
        var hosts: [String] = []
        if let manualIP, !manualIP.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = manualIP.trimmingCharacters(in: .whitespaces)
            let forbidden = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/<>|:"))
            guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
                throw SonosError.badResponse("Not a valid speaker address: \(trimmed)")
            }
            hosts = [trimmed]
        } else {
            hosts = await ssdp(3)
        }
        guard let first = hosts.first else { throw SonosError.noSpeakers }
        let xml = try await client.zoneGroupStateXML(ip: first)
        let groups = TopologyParser.parse(xml)
        guard !groups.isEmpty else { throw SonosError.badResponse("topology had no visible groups") }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
