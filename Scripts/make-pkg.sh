#!/bin/bash
#
# Builds the signed installer package.
#
# A .pkg rather than a bare disk image because it can place the app and the HAL driver in one
# authenticated step. The alternative makes the user drag the app across and then approve a second
# administrator prompt from inside the app for the driver.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MicDownmix.app"
VERSION="$(defaults read "$PWD/Resources/App-Info.plist" CFBundleShortVersionString)"
ROOT="build/pkg-root"
PKG="build/MicDownmix-$VERSION.pkg"
UNSIGNED="build/MicDownmix-$VERSION-unsigned.pkg"
IDENTIFIER="com.stealthpyro.MicDownmix.installer"

[ -d "$APP" ] || { echo "error: $APP not found. Run 'make app' first." >&2; exit 1; }

echo "==> Staging payload"
# Staging has previously ended up root-owned, which makes the next build fail on rm. Clear it with
# whatever rights are needed rather than leaving a trap for the next run.
if [ -d "$ROOT" ] && [ ! -w "$ROOT" ]; then
    osascript -e "do shell script \"rm -rf '$PWD/$ROOT'\" with administrator privileges"
fi
rm -rf "$ROOT" "$PKG" "$UNSIGNED"
mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL"
cp -R "$APP" "$ROOT/Applications/"
# The driver is installed directly, so the app never has to ask for administrator rights itself.
cp -R "$APP/Contents/Resources/MicDownmixDriver.driver" "$ROOT/Library/Audio/Plug-Ins/HAL/"

# pkgbuild marks app bundles relocatable by default, so the installer asks LaunchServices where a
# copy of the bundle already lives and installs THERE instead of the staged location. Any stale copy
# on the machine, including one in a build directory, silently hijacks the install: the app never
# appears in /Applications and the old copy is overwritten as root.
echo "==> Pinning install location"
COMPONENT="build/component.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENT" >/dev/null

# Every bundle in the list, not a fixed index: --analyze orders components by what it finds, so the
# app is not reliably first.
/usr/bin/python3 - "$COMPONENT" <<'PYTHON'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as handle:
    components = plistlib.load(handle)

for component in components:
    # Relocatable bundles let the installer ask LaunchServices where a copy already lives and
    # install there instead, so any stale copy hijacks the install.
    component["BundleIsRelocatable"] = False
    # Version checking makes the installer skip a bundle whose installed version is not older.
    # Reinstalling the same version is how someone repairs a broken install, and silently doing
    # nothing is the worst possible answer to that.
    component["BundleIsVersionChecked"] = False
    component["BundleOverwriteAction"] = "upgrade"

with open(path, "wb") as handle:
    plistlib.dump(components, handle)

unpinned = [c.get("RootRelativeBundlePath") for c in components if c.get("BundleIsRelocatable")]
if unpinned:
    sys.exit("could not pin: %s" % unpinned)
print("   pinned %d bundle(s)" % len(components))
PYTHON

echo "==> Building component package"
pkgbuild \
    --root "$ROOT" \
    --component-plist "$COMPONENT" \
    --scripts Scripts/pkg-scripts \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    "$UNSIGNED" >/dev/null
rm -f "$COMPONENT"

INSTALLER_ID="$(security find-identity -v -p basic 2>/dev/null \
    | grep "Developer ID Installer" | head -1 | sed -E 's/.*"(.*)"/\1/')"

if [ -n "$INSTALLER_ID" ]; then
    echo "==> Signing with: $INSTALLER_ID"
    productsign --sign "$INSTALLER_ID" "$UNSIGNED" "$PKG" >/dev/null
    rm -f "$UNSIGNED"
    pkgutil --check-signature "$PKG" | head -3
else
    echo "==> No Developer ID Installer identity; leaving the package unsigned"
    mv "$UNSIGNED" "$PKG"
fi

rm -rf "$ROOT"
echo "built $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' '))"
