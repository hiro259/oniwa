#!/bin/sh
set -eu
cd "$(dirname "$0")"

# Development is the default; only the dedicated release script opts into
# Developer ID signing, Hardened Runtime and Apple's timestamp service.
SIGNING_MODE=${ONIWA_SIGNING_MODE:-development}
case "$SIGNING_MODE" in
    development|distribution) ;;
    *) echo "ERROR: Unknown ONIWA_SIGNING_MODE: $SIGNING_MODE" >&2; exit 2 ;;
esac

# Keep the standard local build location unchanged. Release staging is isolated
# in dist/, so producing a distribution build never overwrites build/ONIWA.app.
APP_PATH=${ONIWA_APP_OUTPUT:-build/ONIWA.app}
case "$APP_PATH" in
    build/ONIWA.app|dist/ONIWA.app) ;;
    *) echo "ERROR: Unsupported ONIWA_APP_OUTPUT: $APP_PATH" >&2; exit 2 ;;
esac

# Validate the requested identity before the expensive Swift build.
SIGN_IDENTITY=${ONIWA_CODESIGN_IDENTITY:--}
if [ "$SIGNING_MODE" = distribution ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "ERROR: Distribution requires a Developer ID Application signing identity." >&2
    exit 2
fi
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
    AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning)
    if ! printf '%s\n' "$AVAILABLE_IDENTITIES" | grep -Fqi "$SIGN_IDENTITY"; then
        echo "ERROR: No matching signing identity was found in the Mac keychain." >&2
        echo "Run: security find-identity -v -p codesigning" >&2
        exit 2
    fi
    if [ "$SIGNING_MODE" = distribution ] &&
       ! printf '%s\n' "$AVAILABLE_IDENTITIES" |
            grep -iF "$SIGN_IDENTITY" | grep -Fq "Developer ID Application:"; then
        echo "ERROR: Distribution needs a Developer ID Application identity, not Apple Development." >&2
        exit 2
    fi
fi

swift build -c release
mkdir -p "$APP_PATH/Contents/MacOS"
cp .build/release/ONIWA "$APP_PATH/Contents/MacOS/ONIWA"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"

# Package the provided icon before signing. Local icon assets can be stored
# as a ready-to-use ICNS, or as the ten-PNG iconset (converted by iconutil).
# Source-only CI builds remain valid until the binary asset is committed.
ICON_OUTPUT="$APP_PATH/Contents/Resources/AppIcon.icns"
# Avoid carrying a stale bundled icon across rebuilds when assets are changed.
rm -f "$ICON_OUTPUT"
ICON_SOURCE=
for candidate in Resources/AppIcon.icns Resources/ONIWA-AppIcon.icns; do
    if [ -f "$candidate" ]; then
        ICON_SOURCE=$candidate
        break
    fi
done

if [ -n "$ICON_SOURCE" ]; then
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "$ICON_SOURCE" "$ICON_OUTPUT"
    echo "Bundled ONIWA icon from $ICON_SOURCE"
else
    for candidate in Resources/AppIcon.iconset Resources/ONIWA-AppIcon.iconset; do
        if [ -d "$candidate" ]; then
            mkdir -p "$APP_PATH/Contents/Resources"
            iconutil -c icns "$candidate" -o "$ICON_OUTPUT"
            echo "Created ONIWA icon from $candidate"
            break
        fi
    done
fi

if [ -f "$ICON_OUTPUT" ]; then
    # Keep the source Info.plist unchanged when no icon is available in CI.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" \
        "$APP_PATH/Contents/Info.plist"
else
    echo "NOTE: No app icon in Resources; building without a custom icon." >&2
fi

if [ "$SIGNING_MODE" = distribution ]; then
    if [ ! -f "$ICON_OUTPUT" ]; then
        echo "ERROR: Distribution builds require Resources/AppIcon.icns." >&2
        exit 2
    fi
    echo "Developer ID signing with Hardened Runtime and secure timestamp."
    # No broad runtime exceptions by default. In particular, Apple's own
    # system frameworks do not require disabling library validation.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "WARNING: ONIWA is being signed ad-hoc. Permissions may be lost after rebuilds." >&2
    else
        echo "Signing ONIWA with the selected persistent certificate."
    fi
    # Development behavior stays unchanged.
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_PATH"
    codesign --verify --strict "$APP_PATH"
fi
echo "Built $APP_PATH"
echo "Launch with: open $APP_PATH"
