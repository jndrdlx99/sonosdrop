import Testing
import Foundation
@testable import SonosDropCore

@Test func servicePathsAndURNs() {
    #expect(SonosService.avTransport.controlPath == "/MediaRenderer/AVTransport/Control")
    #expect(SonosService.zoneGroupTopology.controlPath == "/ZoneGroupTopology/Control")
    #expect(SonosService.groupRenderingControl.urn == "urn:schemas-upnp-org:service:GroupRenderingControl:1")
}

@Test func envelopeEscapesArguments() {
    let xml = SOAP.envelope(service: .avTransport, action: "AddURIToQueue", args: [("InstanceID", "0"), ("EnqueuedURIMetaData", "<a href=\"x\">")])
    #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:AddURIToQueue xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    #expect(xml.contains("<InstanceID>0</InstanceID><EnqueuedURIMetaData>&lt;a href=&quot;x&quot;&gt;</EnqueuedURIMetaData>"))
    #expect(xml.hasSuffix("</u:AddURIToQueue></s:Body></s:Envelope>"))
}

@Test func parsesResponseLeaves() throws {
    let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetPositionInfoResponse xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><Track>5</Track><TrackDuration>0:05:45</TrackDuration><TrackMetaData>&lt;DIDL-Lite&gt;&lt;dc:title&gt;Self Care&lt;/dc:title&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><RelTime>0:01:24</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>"
    let v = try SOAP.parseResponse(Data(body.utf8))
    #expect(v["Track"] == "5")
    #expect(v["RelTime"] == "0:01:24")
    #expect(v["TrackMetaData"] == "<DIDL-Lite><dc:title>Self Care</dc:title></DIDL-Lite>")
}

@Test func upnpFaultBecomesError() {
    let fault = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>714</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
    #expect(throws: SonosError.upnp(714)) { try SOAP.parseResponse(Data(fault.utf8)) }
}
