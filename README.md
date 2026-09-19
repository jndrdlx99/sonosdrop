# SonosDrop

Native macOS menu bar app that plays local audio files on a Sonos group. Drop files or a folder
on the popover; the app serves them over HTTP from your Mac and queues them on the speaker.

## Build (no Xcode needed)

    make test      # unit tests
    make app       # release build, bundle, ad-hoc sign, install to /Applications

Requires Command Line Tools with Swift 6.4 or newer on macOS 15 or newer.

## Notes

- Formats: MP3, AAC, FLAC, ALAC, WAV, AIFF, OGG, up to 24-bit/48 kHz stereo (Sonos limits).
  Anything above is listed with a reason and skipped.
- macOS asks once to allow incoming connections; the speaker pulls the files from this Mac.
- Commands always target the group coordinator, so stereo pairs appear once.
- If discovery finds nothing, use the network icon to enter a speaker IP by hand.

## Building without Xcode

The SwiftUI property-wrapper macros (`@State`, `@Bindable`) ship only with Xcode, so the views use
plain stored properties, an `@Observable` UI-state class and manual `Binding(get:set:)` instead.
`swift test` occasionally fails on a cold `.build` with a `TestingMacros` plugin-load error; run
`rm -rf .build && swift test` when that happens.
