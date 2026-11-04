#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Local-only release preparation. It never sends credentials to GitHub or
# performs notarization. Normal development builds need no distribution cert.
IDENTITY=${ONIWA_DEVELOPER_ID_IDENTITY:-}
if [ -z "$IDENTITY" ]; then
    echo "ERROR: Set ONIWA_DEVELOPER_ID_IDENTITY to your Developer ID Application SHA-1." >&2
    echo "Check installed identities: security find-identity -v -p codesigning" >&2
    exit 2
fi

# Restrict cleanup to generated distribution artifacts; development's
# build/ONIWA.app is never deleted or re-signed by this script.
mkdir -p dist
rm -rf dist/ONIWA.app

ONIWA_SIGNING_MODE=distribution \
ONIWA_CODESIGN_IDENTITY="$IDENTITY" \
ONIWA_APP_OUTPUT=dist/ONIWA.app \
sh ./build.sh

APP=dist/ONIWA.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="dist/ONIWA-v${VERSION}-notarization.zip"

# Confirm the app was actually signed for distribution, not accidentally
# signed ad-hoc/development or without a timestamp.
SIGN_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
if ! printf '%s\n' "$SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
    echo "ERROR: Hardened Runtime flag is missing." >&2
    exit 1
fi
if ! printf '%s\n' "$SIGN_INFO" | grep -E '^Timestamp=' | grep -Eq '^Timestamp=.+$'; then
    echo "ERROR: Secure code-signing timestamp is missing." >&2
    exit 1
fi
if printf '%s\n' "$SIGN_INFO" | grep -q '^Timestamp=none'; then
    echo "ERROR: Distribution signature contains no secure timestamp." >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# Use the ZIP only to SUBMIT for notarization. A release ZIP must be created
# after stapling the accepted ticket to ONIWA.app.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo ""
echo "Developer ID-signed candidate: $APP"
echo "Notarization submission archive: $ZIP"
echo "NOT notarized yet. Test ONIWA.app on the real Mac before submission."
echo "Never publish the submission ZIP as a finished public release."
