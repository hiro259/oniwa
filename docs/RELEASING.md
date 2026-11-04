# ONIWA v0.1 — Developer ID signing and notarization

**Current status: release workflow prepared, but not yet verified on the owner's Mac or notarized.** Do not upload or advertise a ZIP from the first build as a public release. The app needs real-hardware validation with Hardened Runtime, Apple's acceptance, stapling, and a fresh install test.

This process runs **locally on the owner's Mac**. No signing certificate or notarization credentials are uploaded to the GitHub repository or stored in GitHub Actions.

## 1. Prepare the Mac

A valid **Developer ID Application** signing identity and its private key must already be installed in the *login* keychain.

```fish
security find-identity -v -p codesigning
```

Find the 40-character SHA-1 identifier on the **Developer ID Application** line. Use that public identifier for the commands below; never paste the .p12 file, its export password, the private key, an API key, or an app-specific Apple Account password into GitHub.

The command-line signing tool uses the installed keychain identity; it does not need the .p12 export password after the certificate and private key have been imported into the keychain.

## 2. Build the Developer ID-signed candidate

From a checkout containing this change:

```fish
cd ~/myfile/oniwa
git fetch origin
git switch feat/distribution-signing-v01
git pull --ff-only origin feat/distribution-signing-v01

# Replace the placeholder with the 40-character SHA-1 on the
# Developer ID Application line from security find-identity.
set -gx ONIWA_DEVELOPER_ID_IDENTITY "YOUR_DEVELOPER_ID_SHA1"
sh scripts/build-release.sh
```

The build script rejects missing/malformed identities and an installed certificate of the wrong type, rather than silently falling back to ad-hoc signing. It creates:

- `dist/ONIWA.app` — signed candidate for local real-Mac testing; **not yet notarized**.
- `dist/ONIWA-v0.1.0-notarization.zip` — archive for **submitting** to Apple; **not** the final distribution file.

The existing `sh build.sh` still produces `build/ONIWA.app` using its unchanged local-development defaults. The release script cleans and rebuilds only `dist/ONIWA.app`; rerunning it will replace the previous distribution **candidate**. Do not rerun after stapling unless beginning a new submission.

The candidate signature uses `codesign --options runtime --timestamp` with the Developer ID Application identity and verifies with `codesign --verify --deep --strict`. **No Hardened Runtime exception entitlements** are granted by default. Private, read-only SkyLight APIs are dynamically loaded from an Apple-signed system framework; real-Mac tests determine whether the hardened app behaves correctly on the target system.

## 3. Real-Mac validation — before notarization

Run the **distribution** candidate, not `build/ONIWA.app`:

```fish
open dist/ONIWA.app

# Display public signing metadata; should show runtime and a Timestamp.
codesign -dv --verbose=4 dist/ONIWA.app 2>&1 | grep -E 'Authority=|TeamIdentifier=|flags=|Timestamp='
```

Confirm:

1. The menu bar ONIWA icon appears, the default/custom shortcut opens search, and Japanese/English UI works.
2. Spaces are enumerated, labels and fuzzy search work, and a normal desktop can be selected.
3. A **Chrome fullscreen Space** can be selected.
4. A **two-display Space set** switches both displays correctly, including Sidecar.
5. Disconnect Sidecar: the search palette falls back to the Mac. Reconnect: the preferred display returns and saved two-display sets work when macOS has restored the same Space identities.
6. If macOS requests Accessibility permission for the newly signed app, grant it in System Settings; check that navigation works without silently switching unrelated displays.

**Do not proceed to Apple notarization if core switching fails with Hardened Runtime enabled.** Check the local switch log and signing details; do not automatically disable library validation or JIT protections to work around an unknown failure.

## 4. Notarize after the candidate passes

Store notarytool credentials in the **local Keychain** using the official `xcrun notarytool store-credentials` flow. Choose a profile name, for example `ONIWA-notary`. Use either Apple Account/app-specific-password authentication or an authorized App Store Connect API key; do not put the secret in the repository, shell history, scripts, or issue comments.

Apple documentation: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

When a local notarytool Keychain profile named `ONIWA-notary` exists:

```fish
xcrun notarytool submit \
  dist/ONIWA-v0.1.0-notarization.zip \
  --keychain-profile "ONIWA-notary" \
  --wait
```

Continue **only** if the submission result is `Accepted`. If the result is `Invalid` or `Rejected`, request its log and fix the cause before rebuilding and resubmitting:

```fish
xcrun notarytool log "SUBMISSION_ID" --keychain-profile "ONIWA-notary"
```

## 5. Staple and verify, then package the public ZIP

An archive submitted to Apple is **not** the finished public ZIP. After `Accepted`:

```fish
xcrun stapler staple dist/ONIWA.app
xcrun stapler validate dist/ONIWA.app
codesign --verify --deep --strict --verbose=2 dist/ONIWA.app
spctl --assess --type execute -vv dist/ONIWA.app

ditto -c -k --sequesterRsrc --keepParent \
  dist/ONIWA.app dist/ONIWA-v0.1.0-macos.zip
```

The public archive is `dist/ONIWA-v0.1.0-macos.zip`, created **after** stapling. A ZIP itself cannot be stapled. Do **not** publish the pre-staple `*-notarization.zip` as the final release.

## 6. Clean-install verification and GitHub Release

Extract the **public** ZIP into a fresh destination, move the app to Applications, and perform normal launch and Accessibility authorization. Confirm the OS accepts the notarization ticket, the app's icon appears, and single/paired Space switching works with its hardened distribution signature.

Only then create the `v0.1.0` tag and GitHub Release with `ONIWA-v0.1.0-macos.zip`, installation instructions, macOS compatibility notes, private SkyLight dependency and known limitations. Homebrew Cask comes after the direct release is stable.

**Note:** Notarization checks signatures and malware, not whether ONIWA's private macOS API integrations will continue working on future operating systems. It is separate from Mac App Store review.
