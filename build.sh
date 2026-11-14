#!/bin/bash
# Builds build/JustReview.app (release build).
#
#   VERSION=1.2.0 BUILD=57   version and build number (default: 0.0.0, commit count)
#   SIGN_IDENTITY="Developer ID Application: …"
#                            sign for distribution (hardened runtime, secure timestamp);
#                            without it the app is signed ad hoc, for local use
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release --product JustReview
BIN="$(swift build -c release --show-bin-path)/JustReview"

APP=build/JustReview.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JustReview"
cp jrev "$APP/Contents/Resources/jrev"   # shell launcher, linked by "Install Command Line Tool…"
cp -R Resources/queries "$APP/Contents/Resources/queries"   # tree-sitter highlight queries
cp -R Resources/themes "$APP/Contents/Resources/themes"     # Helix syntax themes
# The icon: Assets.car is the Icon Composer file compiled (`just icon`), which macOS 26 and
# later render themselves; the .icns is for macOS 15. (With only an .icns, macOS 26 shrinks the
# icon onto a tile of its own.)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>JustReview</string>
    <key>CFBundleDisplayName</key><string>JustReview</string>
    <key>CFBundleIdentifier</key><string>house.elephant.justreview</string>
    <key>CFBundleExecutable</key><string>JustReview</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Folders can be opened (jrev, drag onto the Dock icon); the app only views them. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP ($VERSION, build $BUILD)"
