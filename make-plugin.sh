#!/bin/bash
# Builds the plugin and assembles MHT.tcplugin — the bundle you install with
# Configuration ▸ Plugins ▸ Install… in tc4mac.
#
#   ./make-plugin.sh            release build (what you would ship)
#   ./make-plugin.sh debug      faster build, for iterating
set -euo pipefail
CONFIG="${1:-release}"
BUNDLE="MHT.tcplugin"

swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/MhtPlugin"
[ -x "$BINARY" ] || { echo "no executable at $BINARY"; exit 1; }

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# A minimal Info.plist makes the .tcplugin a REAL macOS bundle, which is what
# lets codesign sign it and seal the manifest (the host reads the manifest
# from Contents/Resources — a signable location — since tc4mac 0.2.0).
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIconFile</key>
	<string>tcplugin</string>
	<key>CFBundleExecutable</key>
	<string>MHT</string>
	<key>CFBundleIdentifier</key>
	<string>com.tc4mac.sample.mht</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
</dict>
</plist>
PLIST
cp "$BINARY" "$BUNDLE/Contents/MacOS/MHT"

# The manifest is read before anything runs: it says what the plugin is and
# what it claims, so the host can refuse it without executing a line of it.
cp "$(dirname "$0")/tcplugin.icns" "$BUNDLE/Contents/Resources/tcplugin.icns"

cat > "$BUNDLE/Contents/Resources/manifest.json" <<JSON
{
  "id": "com.tc4mac.sample.mht",
  "displayName": "MHTML archives (sample)",
  "version": "1.0.0",
  "minHostVersion": "0.1.0",
  "types": ["packer"],
  "extensions": ["mht", "mhtml"]
}
JSON

# Sign when an identity is provided — a Developer-ID-signed bundle loads in
# tc4mac without the per-plugin Trust Anyway… override:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-plugin.sh
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BUNDLE"
  codesign --verify --strict "$BUNDLE"
  echo "signed as: $SIGN_IDENTITY"
fi

echo "built $BUNDLE"
echo "install it with Configuration ▸ Plugins ▸ Install…, then switch it on."
