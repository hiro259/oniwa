#!/bin/sh
set -eu
cd "$(dirname "$0")"

# Validate the requested identity before the expensive Swift build.
SIGN_IDENTITY=${ONIWA_CODESIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" != "-" ]; then
    case "$SIGN_IDENTITY" in
        *[!0-9a-fA-F]*)
            echo "ERROR: ONIWA_CODESIGN_IDENTITY must contain hexadecimal SHA-1 digits." >&2
            exit 2
            ;;
    esac
    if [ "${#SIGN_IDENTITY}" -ne 40 ]; then
        echo "ERROR: Set ONIWA_CODESIGN_IDENTITY to an actual 40-character SHA-1 from security find-identity." >&2
        echo "Do not use the literal placeholder shown in the setup guide." >&2
        exit 2
    fi
    if ! security find-identity -v -p codesigning | grep -Fqi "$SIGN_IDENTITY"; then
        echo "ERROR: No matching signing identity was found in the Mac keychain." >&2
        echo "Run: security find-identity -v -p codesigning" >&2
        exit 2
    fi
fi

swift build -c release
mkdir -p build/ONIWA.app/Contents/MacOS
cp .build/release/ONIWA build/ONIWA.app/Contents/MacOS/ONIWA
cp Resources/Info.plist build/ONIWA.app/Contents/Info.plist

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "WARNING: ONIWA is being signed ad-hoc. Permissions may be lost after rebuilds." >&2
else
    echo "Signing ONIWA with the selected persistent certificate."
fi

# Suitable for local testing. Public releases need distribution signing/notarization.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none build/ONIWA.app
codesign --verify --strict build/ONIWA.app
echo "Built build/ONIWA.app"
echo "Launch with: open build/ONIWA.app"
