#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Run only AFTER the Developer ID-signed app has been notarized and stapled.
# This prepares a signed drag-to-Applications DMG for a SEPARATE notarization
# submission. It does not submit to Apple or publish a GitHub release.
APP="dist/ONIWA.app"
IDENTITY=${ONIWA_DEVELOPER_ID_IDENTITY:-}

if [ -z "$IDENTITY" ]; then
    echo "ERROR: Set ONIWA_DEVELOPER_ID_IDENTITY to the Developer ID Application SHA-1." >&2
    exit 2
fi
case "$IDENTITY" in
    *[!0-9A-Fa-f]*) echo "ERROR: Developer ID SHA-1 must be hexadecimal." >&2; exit 2 ;;
esac
if [ "${#IDENTITY}" -ne 40 ]; then
    echo "ERROR: Developer ID SHA-1 must contain 40 characters." >&2
    exit 2
fi

if [ ! -d "$APP" ]; then
    echo "ERROR: Missing $APP; first run sh scripts/build-release.sh." >&2
    exit 2
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg is needed. Install it with: brew install create-dmg" >&2
    exit 2
fi

# Never sign the disk image with a development certificate or different team.
AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning)
if ! printf '%s\n' "$AVAILABLE_IDENTITIES" |
    grep -iF "$IDENTITY" | grep -Fq "Developer ID Application:"; then
    echo "ERROR: Developer ID Application identity not found in Keychain." >&2
    exit 2
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
case "$VERSION" in
    ""|*[!0-9A-Za-z._-]*)
        echo "ERROR: Unexpected ONIWA version in Info.plist." >&2
        exit 2
        ;;
esac
DMG="dist/ONIWA-v${VERSION}-macos.dmg"
if [ -e "$DMG" ]; then
    echo "ERROR: $DMG already exists; refusing to replace a possible signed release." >&2
    exit 2
fi

# Fail closed on an unsigned or unstapled app. Signing the DMG cannot repair
# a missing/invalid signature or notarization ticket inside the app bundle.
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"

ICON="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "ERROR: ONIWA AppIcon.icns is required for the DMG volume icon." >&2
    exit 2
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/oniwa-dmg.XXXXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
ditto "$APP" "$STAGING/ONIWA.app"

# create-dmg lays out the icons in Finder and embeds a /Applications symlink.
# Finder automation can ask for permission when run on the developer's Mac.
create-dmg \
    --volname "ONIWA ${VERSION}" \
    --volicon "$ICON" \
    --window-pos 180 120 \
    --window-size 620 380 \
    --icon-size 112 \
    --text-size 14 \
    --icon "ONIWA.app" 155 190 \
    --hide-extension "ONIWA.app" \
    --app-drop-link 465 190 \
    --format UDZO \
    --no-internet-enable \
    --codesign "$IDENTITY" \
    "$DMG" "$STAGING"

codesign --verify --verbose=2 "$DMG"
hdiutil verify "$DMG"

echo ""
echo "Signed drag-to-Applications candidate: $DMG"
echo "NOT notarized as a DMG yet."
echo "Open the DMG to inspect the icon positions, but do NOT publish until"
echo "Apple has accepted a separate DMG submission and its ticket is stapled."
