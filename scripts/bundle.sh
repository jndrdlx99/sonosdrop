#!/bin/sh
# Release build -> build/SonosDrop.app -> /Applications. No Xcode, ad-hoc signature.
set -e
cd "$(dirname "$0")/.."
APP=build/SonosDrop.app
swift build -c release 2>&1 | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SonosDrop "$APP/Contents/MacOS/SonosDrop"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SonosDrop</string>
  <key>CFBundleIdentifier</key><string>com.jndrdlx.sonosdrop</string>
  <key>CFBundleName</key><string>SonosDrop</string>
  <key>CFBundleDisplayName</key><string>SonosDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>SonosDrop talks to your Sonos speakers and serves your music files to them.</string>
</dict></plist>
EOF
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
rm -rf /Applications/SonosDrop.app
cp -R "$APP" /Applications/SonosDrop.app
echo "Installed /Applications/SonosDrop.app"
