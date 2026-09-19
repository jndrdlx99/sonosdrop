#!/bin/sh
# Generates 1-second stereo 440 Hz tones as Sonos-relevant fixtures.
set -e
OUT="$(dirname "$0")/../Tests/SonosDropCoreTests/Fixtures"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
python3 - "$TMP" <<'EOF'
import sys, math, wave
out = sys.argv[1]
def make(name, rate, bits):
    w = wave.open(f"{out}/{name}", 'wb'); w.setnchannels(2); w.setsampwidth(bits//8); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate):
        v = int(math.sin(2*math.pi*440*i/rate) * (2**(bits-1)-1) * 0.3)
        b = v.to_bytes(bits//8, 'little', signed=True); frames += b + b
    w.writeframes(bytes(frames)); w.close()
make('tone_16_44100.wav', 44100, 16)
make('tone_24_96000.wav', 96000, 24)
EOF
afconvert -f flac -d flac "$TMP/tone_16_44100.wav" "$OUT/tone_16_44100.flac"
afconvert -f flac -d flac "$TMP/tone_24_96000.wav" "$OUT/tone_24_96000.flac"
afconvert -f m4af -d aac  "$TMP/tone_16_44100.wav" "$OUT/tone_aac.m4a"
rm -rf "$TMP"
ls -la "$OUT"
