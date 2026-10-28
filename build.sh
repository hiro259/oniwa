#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
mkdir -p build/ONIWA.app/Contents/MacOS
cp .build/release/ONIWA build/ONIWA.app/Contents/MacOS/ONIWA
cp Resources/Info.plist build/ONIWA.app/Contents/Info.plist
# Local testing only. Public releases should use Developer ID + notarization.
codesign --force --sign - build/ONIWA.app
echo "Built build/ONIWA.app"
echo "Launch with: open build/ONIWA.app"
