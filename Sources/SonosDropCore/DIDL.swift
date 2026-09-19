import Foundation

public enum XML {
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Collects the text of every leaf element, keyed by local name (prefix stripped).
final class XMLLeaves: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var current = ""
    private var text = ""

    static func collect(_ data: Data) -> [String: String] {
        let d = XMLLeaves()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.values
    }

    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = local(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        if name == current { values[name] = text }
        current = ""
        text = ""
    }
}

public enum DIDL {
    static let header = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"

    public static func metadata(track: Track, streamURL: URL) -> String {
        let itemID = "t/" + streamURL.lastPathComponent
        return header
            + "<item id=\"\(XML.escape(itemID))\" parentID=\"-1\" restricted=\"true\">"
            + "<dc:title>\(XML.escape(track.title))</dc:title>"
            + "<dc:creator>\(XML.escape(track.artist))</dc:creator>"
            + "<upnp:album>\(XML.escape(track.album))</upnp:album>"
            + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(track.mime):*\" duration=\"\(track.durationString)\">\(XML.escape(streamURL.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }

    public static func titleArtist(from didl: String) -> (title: String, artist: String) {
        guard didl.hasPrefix("<") else { return ("", "") }
        let v = XMLLeaves.collect(Data(didl.utf8))
        return (v["title"] ?? "", v["creator"] ?? "")
    }
}
