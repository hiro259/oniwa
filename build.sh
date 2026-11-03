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

# Package the provided icon before signing. Local icon assets can be stored
# as a ready-to-use ICNS, or as the ten-PNG iconset (converted by iconutil).
# Source-only CI builds remain valid until the binary asset is committed.
ICON_OUTPUT=build/ONIWA.app/Contents/Resources/AppIcon.icns
ICON_SOURCE=
for candidate in Resources/AppIcon.icns Resources/ONIWA-AppIcon.icns; do
    if [ -f "$candidate" ]; then
        ICON_SOURCE=$candidate
        break
    fi
done

if [ -n "$ICON_SOURCE" ]; then
    mkdir -p build/ONIWA.app/Contents/Resources
    cp "$ICON_SOURCE" "$ICON_OUTPUT"
    echo "Bundled ONIWA icon from $ICON_SOURCE"
else
    for candidate in Resources/AppIcon.iconset Resources/ONIWA-AppIcon.iconset; do
        if [ -d "$candidate" ]; then
            mkdir -p build/ONIWA.app/Contents/Resources
            iconutil -c icns "$candidate" -o "$ICON_OUTPUT"
            echo "Created ONIWA icon from $candidate"
            break
        fi
    done
fi

if [ -f "$ICON_OUTPUT" ]; then
    # Keep the source Info.plist unchanged when no icon is available in CI.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" \
        build/ONIWA.app/Contents/Info.plist
else
    echo "NOTE: No app icon in Resources; building without a custom icon." >&2
fi

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
