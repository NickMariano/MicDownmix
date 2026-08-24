#!/bin/bash
#
# Removes MicDownmix completely.
#
# Use the Uninstall item in the app's menu if you still have the app. This script is for the case
# where the app was already dragged to the Trash, which leaves the audio driver installed and still
# publishing a virtual microphone that nothing drives.

set -uo pipefail

DRIVER="/Library/Audio/Plug-Ins/HAL/MicDownmixDriver.driver"
APP="/Applications/MicDownmix.app"
AGENT="$HOME/Library/LaunchAgents/com.stealthpyro.MicDownmix.LoginAgent.plist"
RECEIPT="com.stealthpyro.MicDownmix.installer"

echo "This removes MicDownmix, its audio driver and its login item."
echo "Audio will cut out for about a second while macOS unloads the driver."
echo
if [ "${MICDOWNMIX_ASSUME_YES:-0}" != "1" ]; then
    read -r -p "Continue? [y/N] " REPLY
    case "$REPLY" in [yY]*) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# User-level parts need no password.
pkill -f "$APP/Contents/MacOS/MicDownmix" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.stealthpyro.MicDownmix.LoginAgent" 2>/dev/null
rm -f "$AGENT"
defaults delete com.stealthpyro.MicDownmix 2>/dev/null
echo "Removed login item and settings."

NEEDS_ADMIN=0
[ -d "$DRIVER" ] && NEEDS_ADMIN=1
[ -d "$APP" ] && NEEDS_ADMIN=1

if [ "$NEEDS_ADMIN" -eq 1 ]; then
    echo "Removing the driver and app..."
    PRIVILEGED="rm -rf '$DRIVER' '$APP'; pkgutil --forget $RECEIPT >/dev/null 2>&1; killall coreaudiod 2>/dev/null; true"
    # osascript rather than sudo, so this also works when the script is double-clicked from Finder,
    # where there is no terminal to type a password into.
    if ! osascript -e "do shell script \"$PRIVILEGED\" with prompt \"MicDownmix needs your permission to remove its audio driver.\" with administrator privileges" >/dev/null 2>&1; then
        echo "error: could not remove the driver. Nothing else was changed." >&2
        exit 1
    fi
    echo "Removed driver and app."
else
    pkgutil --forget "$RECEIPT" >/dev/null 2>&1
    echo "Nothing else to remove."
fi

echo
if system_profiler SPAudioDataType 2>/dev/null | grep -q "MicDownmix"; then
    echo "warning: the MicDownmix device is still listed. Log out and back in." >&2
    exit 1
fi
echo "MicDownmix is fully removed."
