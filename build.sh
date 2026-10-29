#!/bin/sh
set -eu
cd "$(dirname "$0")"

swift build -c release
mkdir -p build/ONIWA.app/Contents/MacOS
cp .build/release/ONIWA build/ONIWA.app/Contents/MacOS/ONIWA
cp Resources/Info.plist build/ONIWA.app/Contents/Info.plist

# A stable Apple Development / Developer ID signing identity helps macOS keep
# Accessibility (TCC) authorization across rebuilt development versions.
#
# In fish, identify a local certificate with:
#   security find-identity -v -p codesigning
#   set -gx ONIWA_CODESIGN_IDENTITY <SHA-1-of-identity>
#
# If no identity is supplied, keep ad-hoc signing available for CI and quick
# prototyping, but explicitly warn that permissions may be invalidated.
SIGN_IDENTITY=${ONIWA_CODESIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "WARNING: Signing ONIWA ad-hoc for local testing." >&2
    echo "Accessibility permissions may need to be re-granted after each rebuild." >&2
else
    echo "Signing ONIWA using a persistent development certificate."
fi

# --timestamp=none avoids relying on external timestamp service for local
# development; this is not a notarized distribution package.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none build/ONIWA.app
codesign --verify --strict build/ONIWA.app

echo "Built build/ONIWA.app"
echo "Launch with: open build/ONIWA.app"
