import Foundation

public enum SonosService: String, Sendable {
    case avTransport = "AVTransport"
    case renderingControl = "RenderingControl"
    case groupRenderingControl = "GroupRenderingControl"
    case zoneGroupTopology = "ZoneGroupTopology"

    public var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        }
    }

    public var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
}

public enum SonosError: Error, Equatable, Sendable {
    case unreachable(String)
    case upnp(Int)
    case http(Int)
    case badResponse(String)
    case noSpeakers

    public var message: String {
        switch self {
        case .unreachable(let ip): return "Speaker at \(ip) is unreachable"
        case .upnp(let code): return "Sonos rejected the request (UPnP \(code))"
        case .http(let status): return "Speaker answered HTTP \(status)"
        case .badResponse(let why): return "Unexpected reply: \(why)"
        case .noSpeakers: return "No Sonos speakers found"
        }
    }
}

public enum SOAP {
    public static func envelope(service: SonosService, action: String, args: [(String, String)]) -> String {
        let body = args.map { "<\($0.0)>\(XML.escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"
    }

    /// Flat map of leaf element name -> text. Throws `SonosError.upnp` on a UPnP fault.
    public static func parseResponse(_ data: Data) throws -> [String: String] {
        let values = XMLLeaves.collect(data)
        if let code = values["errorCode"], let n = Int(code) { throw SonosError.upnp(n) }
        if values.isEmpty { throw SonosError.badResponse("empty or malformed XML") }
        return values
    }
}
