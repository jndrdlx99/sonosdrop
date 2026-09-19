import Testing
import Foundation
@testable import SonosDropCore

// Captured from the user's network (trimmed) plus a synthetic 2-room group and an invisible bridge.
let topologyXML = """
<ZoneGroupState><ZoneGroups>\
<ZoneGroup Coordinator="RINCON_347E5CDB811801400" ID="RINCON_347E5CDB811801400:123">\
<ZoneGroupMember UUID="RINCON_C43875F099E001400" Location="http://10.20.28.56:1400/xml/device_description.xml" ZoneName="Studio" Icon="x-rincon-roomicon:office" SWGen="2"/>\
<ZoneGroupMember UUID="RINCON_347E5CDB811801400" Location="http://10.20.28.52:1400/xml/device_description.xml" ZoneName="Studio" Icon="x-rincon-roomicon:office" SWGen="2"/>\
</ZoneGroup>\
<ZoneGroup Coordinator="RINCON_AAA" ID="RINCON_AAA:5">\
<ZoneGroupMember UUID="RINCON_AAA" Location="http://10.20.28.60:1400/xml/device_description.xml" ZoneName="Kitchen"/>\
<ZoneGroupMember UUID="RINCON_BBB" Location="http://10.20.28.61:1400/xml/device_description.xml" ZoneName="Patio"/>\
</ZoneGroup>\
<ZoneGroup Coordinator="RINCON_BOOST" ID="RINCON_BOOST:1">\
<ZoneGroupMember UUID="RINCON_BOOST" Location="http://10.20.28.70:1400/xml/device_description.xml" ZoneName="BOOST" Invisible="1"/>\
</ZoneGroup>\
</ZoneGroups><VanishedDevices/></ZoneGroupState>
"""

@Test func stereoPairCollapsesToCoordinator() {
    let groups = TopologyParser.parse(topologyXML)
    let studio = groups.first { $0.name == "Studio" }
    #expect(studio?.coordinatorIP == "10.20.28.52")
    #expect(studio?.coordinatorUUID == "RINCON_347E5CDB811801400")
    #expect(studio?.memberIPs.sorted() == ["10.20.28.52", "10.20.28.56"])
}

@Test func multiRoomGroupJoinsNamesAndInvisibleGroupsAreDropped() {
    let groups = TopologyParser.parse(topologyXML)
    #expect(groups.count == 2)
    #expect(groups.map(\.name).sorted() == ["Kitchen + Patio", "Studio"])
}

@Test func garbageYieldsNoGroups() {
    #expect(TopologyParser.parse("nope").isEmpty)
}

@Test func ssdpSearchMessageTargetsZonePlayers() {
    let m = SSDP.searchMessage()
    #expect(m.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
    #expect(m.contains("HOST: 239.255.255.250:1900\r\n"))
    #expect(m.contains("MAN: \"ssdp:discover\"\r\n"))
    #expect(m.contains("ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n"))
    #expect(m.hasSuffix("\r\n\r\n"))
}

@Test func ssdpReplyLocationHost() {
    let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nEXT:\r\nLOCATION: http://10.20.28.52:1400/xml/device_description.xml\r\nSERVER: Linux UPnP/1.0 Sonos/97.1-80312 (ZPS24)\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
    #expect(SSDP.locationHost(inReply: reply) == "10.20.28.52")
    #expect(SSDP.locationHost(inReply: "HTTP/1.1 200 OK\r\n\r\n") == nil)
}

@Test(.disabled("manual: needs LAN")) func ssdpFindsRealSpeakers() async {
    let hosts = await SSDP.discoverHosts(timeout: 3)
    print("SSDP hosts:", hosts)
    #expect(hosts.contains("10.20.28.52"))
}

final class TopologyOnlyClient: SonosControlling, @unchecked Sendable {
    var askedIPs: [String] = []
    let xml: String
    init(xml: String) { self.xml = xml }
    func zoneGroupStateXML(ip: String) async throws -> String { askedIPs.append(ip); return xml }
    func clearQueue(_ g: SpeakerGroup) async throws {}
    func addToQueue(_ g: SpeakerGroup, uri: String, metadata: String) async throws -> Int { 0 }
    func playQueue(_ g: SpeakerGroup) async throws {}
    func play(_ g: SpeakerGroup) async throws {}
    func pause(_ g: SpeakerGroup) async throws {}
    func next(_ g: SpeakerGroup) async throws {}
    func previous(_ g: SpeakerGroup) async throws {}
    func positionInfo(_ g: SpeakerGroup) async throws -> NowPlaying { .idle }
    func volume(_ g: SpeakerGroup) async throws -> Int { 0 }
    func setVolume(_ g: SpeakerGroup, _ value: Int) async throws {}
}

@Test func discoveryUsesFirstSSDPHostAndParsesGroups() async throws {
    let client = TopologyOnlyClient(xml: topologyXML)
    let discovery = Discovery(client: client, ssdp: { _ in ["10.20.28.52", "10.20.28.56"] })
    let groups = try await discovery.groups(manualIP: nil)
    #expect(client.askedIPs == ["10.20.28.52"])
    #expect(groups.map(\.name).sorted() == ["Kitchen + Patio", "Studio"])
}

@Test func discoveryFallsBackToManualIP() async throws {
    let client = TopologyOnlyClient(xml: topologyXML)
    let discovery = Discovery(client: client, ssdp: { _ in [] })
    _ = try await discovery.groups(manualIP: "10.20.28.52")
    #expect(client.askedIPs == ["10.20.28.52"])
}

@Test func discoveryWithNothingThrowsNoSpeakers() async {
    let discovery = Discovery(client: TopologyOnlyClient(xml: topologyXML), ssdp: { _ in [] })
    await #expect(throws: SonosError.noSpeakers) { try await discovery.groups(manualIP: nil) }
}
