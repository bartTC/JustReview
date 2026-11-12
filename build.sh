#!/bin/bash
# Builds build/JustReview.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product JustReview
BIN="$(swift build -c release --show-bin-path)/JustReview"

APP=build/JustReview.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JustReview"
cp jrev "$APP/Contents/Resources/jrev"   # shell launcher, linked by "Install Command Line Tool…"
cp -R Resources/queries "$APP/Contents/Resources/queries"   # tree-sitter highlight queries

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>JustReview</string>
    <key>CFBundleDisplayName</key><string>JustReview</string>
    <key>CFBundleIdentifier</key><string>local.justreview</string>
    <key>CFBundleExecutable</key><string>JustReview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
