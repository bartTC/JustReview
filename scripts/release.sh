#!/bin/bash
# Builds a signed, notarized release zip of the tagged commit.
#
# Usage: scripts/release.sh v1.2.0
#
# Needs the "Developer ID Application" certificate in the keychain, and notarization
# credentials: either a keychain profile (once: `just notary-setup`) or APPLE_ID,
# APPLE_TEAM_ID and APPLE_APP_PASSWORD in .env.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: scripts/release.sh vX.Y.Z}"
[ -f .env ] && { set -a; source .env; set +a; }

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "No tag $tag (git tag $tag)"; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$tag^{commit}")" ] || { echo "HEAD is not at $tag"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree has uncommitted changes"; exit 1; }

version="${tag#v}"
out="build/release"
zip="$out/JustReview-$version.zip"
mkdir -p "$out"

VERSION="$version" SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" ./build.sh

if [ -n "${APPLE_ID:-}" ]; then
    auth=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
    auth=(--keychain-profile "${NOTARY_PROFILE:-justreview}")
fi

echo "Submitting for notarization (usually a few minutes)…"
rm -f "$zip"
ditto -c -k --keepParent build/JustReview.app "$zip"
xcrun notarytool submit "$zip" "${auth[@]}" --wait

xcrun stapler staple build/JustReview.app
spctl --assess --type execute --verbose=2 build/JustReview.app

# The final zip carries the stapled ticket, so it opens without a network check.
rm -f "$zip"
ditto -c -k --keepParent build/JustReview.app "$zip"
echo "Release ready: $zip"
echo "Publish with: just publish $tag"
