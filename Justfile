# JustReview — build and release
# Usage: just <command>

default:
    @just --list

# Build build/JustReview.app for local use (ad-hoc signed)
build:
    ./build.sh

# Compile Resources/AppIcon.icon (Icon Composer) into Resources/Assets.car; needs Xcode 26 or later
icon:
    #!/bin/bash
    set -euo pipefail
    xcode="$(ls -d /Applications/Xcode*.app | tail -1)"
    out="$(mktemp -d)"
    DEVELOPER_DIR="$xcode/Contents/Developer" xcrun actool Resources/AppIcon.icon --compile "$out" \
        --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
        --target-device mac --platform macosx --minimum-deployment-target 15.0 \
        --output-partial-info-plist "$out/partial.plist" >/dev/null
    cp "$out/Assets.car" Resources/Assets.car
    rm -rf "$out"
    echo "Wrote Resources/Assets.car"

# Store notarization credentials in the keychain (once)
notary-setup:
    xcrun notarytool store-credentials justreview

# Build, sign, notarize and zip the tagged commit
release tag:
    ./scripts/release.sh {{tag}}

# Create the GitHub release with the notarized zip
publish tag:
    gh release create {{tag}} "build/release/JustReview-$(echo {{tag}} | sed 's/^v//').zip" --title "JustReview {{tag}}" --generate-notes
