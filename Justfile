# JustReview — build and release
# Usage: just <command>

default:
    @just --list

# Build build/JustReview.app for local use (ad-hoc signed)
build:
    ./build.sh

# Store notarization credentials in the keychain (once)
notary-setup:
    xcrun notarytool store-credentials justreview

# Build, sign, notarize and zip the tagged commit
release tag:
    ./scripts/release.sh {{tag}}

# Create the GitHub release with the notarized zip
publish tag:
    gh release create {{tag}} "build/release/JustReview-$(echo {{tag}} | sed 's/^v//').zip" --title "JustReview {{tag}}" --generate-notes
