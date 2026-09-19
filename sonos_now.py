import re, json
from urllib.parse import unquote, urlparse, parse_qs
from soco import SoCo

zp = SoCo("10.20.28.56")
coord = zp.group.coordinator
print(f"queried: {zp.player_name} @ {zp.ip_address}")
print(f"coordinator: {coord.player_name} @ {coord.ip_address}  model={coord.get_speaker_info().get('model_name')}")
print(f"group members: {[m.ip_address for m in zp.group.members]}\n")

t = coord.get_current_track_info()
for k in ("title", "artist", "album", "position", "duration", "uri"):
    print(f"{k:9} {t.get(k)}")

uri = t.get("uri", "")
m = re.search(r"sid=(\d+)", uri)
sid = m.group(1) if m else None
svc = None
if sid:
    from soco.music_services import MusicService
    try:
        svc = next((s["Name"] for s in MusicService._get_music_services_data().values() if str(s.get("Id")) == sid), None)
    except Exception as e:
        svc = f"(lookup failed: {e})"
path = unquote(urlparse(uri).path)
print(f"\nservice   sid={sid} -> {svc}")
print(f"track ref {path}")
codec = path.rsplit('.', 1)[-1] if '.' in path else '?'
print(f"codec     {codec} (from URI extension)")

# Raw DIDL res attributes: this is where bitrate/sampleFrequency/bitsPerSample WOULD appear
md = t.get("metadata", "")
res = re.search(r"<res[^>]*>", md)
print(f"\nres tag   {res.group(0) if res else '(none)'}")
for attr in ("bitrate", "sampleFrequency", "bitsPerSample", "nrAudioChannels"):
    v = re.search(rf'{attr}="([^"]*)"', md)
    print(f"  {attr:16} {v.group(1) if v else 'NOT PROVIDED'}")
