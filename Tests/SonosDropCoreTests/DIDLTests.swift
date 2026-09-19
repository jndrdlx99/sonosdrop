import Testing
import Foundation
@testable import SonosDropCore

@Test func escapesAllFiveXMLCharacters() {
    #expect(XML.escape("a & b < c > \"d\" 'e'") == "a &amp; b &lt; c &gt; &quot;d&quot; &apos;e&apos;")
}

@Test func buildsSonosCompatibleMetadata() {
    let track = Track(url: URL(fileURLWithPath: "/m/x.flac"), title: "Rock & Roll", artist: "AC/DC",
                      album: "Live <1992>", duration: 245, codec: "FLAC")
    let url = URL(string: "http://10.0.0.5:8080/t/abc")!
    let expected = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        + "<item id=\"t/abc\" parentID=\"-1\" restricted=\"true\">"
        + "<dc:title>Rock &amp; Roll</dc:title><dc:creator>AC/DC</dc:creator><upnp:album>Live &lt;1992&gt;</upnp:album>"
        + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        + "<res protocolInfo=\"http-get:*:audio/flac:*\" duration=\"0:04:05\">http://10.0.0.5:8080/t/abc</res>"
        + "</item></DIDL-Lite>"
    #expect(DIDL.metadata(track: track, streamURL: url) == expected)
}

@Test func readsTitleAndArtistBackFromSonosMetadata() {
    let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"-1\" parentID=\"-1\" restricted=\"true\"><dc:title>Self Care</dc:title><dc:creator>Mac Miller</dc:creator><upnp:album>Swimming</upnp:album></item></DIDL-Lite>"
    let r = DIDL.titleArtist(from: didl)
    #expect(r.title == "Self Care")
    #expect(r.artist == "Mac Miller")
}

@Test func titleArtistOnGarbageIsEmpty() {
    let r = DIDL.titleArtist(from: "NOT_IMPLEMENTED")
    #expect(r.title == "" && r.artist == "")
}
