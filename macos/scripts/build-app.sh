#!/bin/sh
# Builds build/Almanac.app (release) and signs it.
# Signs with "Almanac Local Signing" when that certificate exists (scripts/make-signing-cert.sh),
# otherwise ad-hoc. Ad-hoc signatures change on every build, so the Keychain asks again each time.
set -eu
cd "$(dirname "$0")/.."

NAME="Almanac Local Signing"
BUNDLE_ID="com.kjastram.almanac"
SCRATCH=.build-app
APP=build/Almanac.app
VERSION=${ALMANAC_VERSION:-0.1.0}
BUILD_NUMBER=$(date +%Y%m%d%H%M)

swift build -c release --product Almanac --scratch-path "$SCRATCH"
BIN=$(swift build -c release --product Almanac --scratch-path "$SCRATCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Almanac" "$APP/Contents/MacOS/Almanac"
# App icon (Dock, Finder). Regenerate with: swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles, if any target has resources. Bundle.module looks in Contents/Resources.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Almanac</string>
    <key>CFBundleDisplayName</key><string>Almanac</string>
    <key>CFBundleExecutable</key><string>Almanac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Signing with \"$NAME\"…"
    codesign --force --sign "$NAME" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "warning: no \"$NAME\" certificate; signing ad-hoc." >&2
    echo "warning: the Keychain will ask for access again after every rebuild. Run scripts/make-signing-cert.sh once to fix that." >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP"
echo "Run it:  open $APP     (or $APP/Contents/MacOS/Almanac --preview-data to try the UI without Google)"
