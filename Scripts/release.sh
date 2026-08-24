#!/bin/bash
#
# Builds, packages and publishes a release.
#
# Notarization is opt-in: set NOTARY_PROFILE to a `notarytool store-credentials` profile name and
# the disk image is submitted and stapled, so it opens with no warnings. Without it the build is
# ad-hoc signed and the release notes carry the Gatekeeper instructions instead.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(defaults read "$PWD/Resources/App-Info.plist" CFBundleShortVersionString)"
TAG="v$VERSION"
PKG="build/MicDownmix-$VERSION.pkg"

echo "==> Building $TAG"
make clean >/dev/null
make app
./Scripts/make-pkg.sh

NOTARY_PROFILE="${NOTARY_PROFILE:-MicDownmix}"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing with profile $NOTARY_PROFILE"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    GATEKEEPER_NOTE=""
else
    echo "==> No notary credentials for profile '$NOTARY_PROFILE'; shipping un-notarized" >&2
    GATEKEEPER_NOTE=$'\n### First launch\n\nThis build is not notarized, so macOS will warn that it is from an unidentified developer.\nRight-click MicDownmix in Applications and choose **Open**, then confirm. This is needed once.\n'
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists. Bump CFBundleShortVersionString first." >&2
    exit 1
fi

git tag -a "$TAG" -m "MicDownmix $VERSION"
git push origin main --tags

gh release create "$TAG" "$PKG" \
    --title "MicDownmix $VERSION" \
    --notes "$(cat <<NOTES
Turns one or more channels of a multi-channel audio interface into a standard mono microphone that
any app can select, including Discord.

## Install

1. Download and open \`MicDownmix-$VERSION.pkg\`
2. Click through the installer and enter your password once
3. MicDownmix opens by itself. Allow microphone access, pick your interface and channel

The installer places the app and its audio driver together, so there is no dragging, no second
password prompt, and nothing to run in Terminal.

Installing restarts the system audio service, which interrupts all audio for about a second.
$GATEKEEPER_NOTE
## Requirements

macOS 15 or later. The source interface must be at 48 kHz.
NOTES
)"

echo "==> Published $TAG"
