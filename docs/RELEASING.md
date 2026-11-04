# ONIWA v0.1 — Developer ID signing and notarization

**Release history:** ONIWA v0.1.0 was published on 2026-11-04 as an Apple-notarized ZIP after M4 real-Mac testing. This document retains that historical ZIP workflow below. **v0.1.1 is in preparation** and adds a drag-to-Applications DMG workflow (see the new section near the end); it has not yet been packaged, notarized, or published. Never publish the pre-staple notarization-submission ZIP or an unstapled DMG.

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

**Quit the currently running development ONIWA from its menu first.** Both apps have the same bundle identifier, so opening the distribution candidate while the development app is running may activate the old process instead of testing the newly signed app.

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

Extract the **public** ZIP into a fresh destination, then perform a normal launch and Accessibility authorization. Before/around publication, also test moving it to Applications and launching the downloaded archive with macOS quarantine/Gatekeeper behavior. Confirm the OS accepts the notarization ticket, the app's icon appears, and single/paired Space switching works with its hardened distribution signature.

Create the `v0.1.0` tag and GitHub Release with `ONIWA-v0.1.0-macos.zip`, installation instructions, macOS compatibility notes, private SkyLight dependency and known limitations. After uploading, download the published ZIP and repeat the Gatekeeper/first-run check. Homebrew Cask comes after the direct release is stable.


## v0.1.1 — Drag-to-Applications DMG workflow (not yet verified)

For v0.1.1, prefer an Apple-notarized **DMG** with the ONIWA icon on the left and an **Applications** folder shortcut on the right. Users install ONIWA by dragging its icon onto Applications. A DMG is an optional presentation and copy mechanism, **not** a privileged installer. Opening the app inside the mounted DMG is not the recommended install method.

This is a **local developer-only** packaging step that does not affect the publicly available v0.1.0 ZIP. The DMG uses [create-dmg](https://github.com/create-dmg/create-dmg) to arrange Finder icons and generate the Applications symlink. No signing certificate or notary credentials are stored in the repository or CI.

1. Install the DMG helper once:

   ```fish
   brew install create-dmg
   ```

2. From the **v0.1.1 PR/branch**, ensure the Developer ID Application SHA-1 is set in `ONIWA_DEVELOPER_ID_IDENTITY` (see above). Build with `sh scripts/build-release.sh`, and repeat the real-Mac switching tests. The output filename is derived from `Info.plist`, so the new submission archive is `dist/ONIWA-v0.1.1-notarization.zip`.
3. Notarize the **app submission ZIP** first, wait for **Accepted**, and staple the app. The DMG builder deliberately requires the app's stapled ticket:

   ```fish
   xcrun notarytool submit dist/ONIWA-v0.1.1-notarization.zip \
     --keychain-profile "ONIWA-notary" --wait
   # Only after status: Accepted:
   xcrun stapler staple dist/ONIWA.app
   xcrun stapler validate dist/ONIWA.app
   ```

4. Prepare the drag-and-drop disk image:

   ```fish
   sh scripts/build-dmg.sh
   ```

   The script validates the installed Developer ID Application signing identity and the already-stapled `dist/ONIWA.app`. It signs `dist/ONIWA-v0.1.1-macos.dmg` with the same Developer ID identity, then verifies its signature and disk-image integrity. It refuses to overwrite an existing DMG. Finder automation may prompt the developer to allow Terminal to control Finder; that permission is only needed while building the **DMG layout**, not by users installing ONIWA.

5. On the Mac, open the DMG in Finder and visually confirm **ONIWA.app on the left, Applications on the right**, the drag-and-drop target, the icon and window layout. Do not ship if the Finder layout is missing, obscured, or incorrect.
6. **Notarize the DMG as the distributed outer container**, separately from the app. Apple recommends notarizing the outermost distributed container; a stapled app alone is not the full DMG packaging check:

   ```fish
   xcrun notarytool submit dist/ONIWA-v0.1.1-macos.dmg \
     --keychain-profile "ONIWA-notary" --wait
   # Only after status: Accepted:
   xcrun stapler staple dist/ONIWA-v0.1.1-macos.dmg
   xcrun stapler validate dist/ONIWA-v0.1.1-macos.dmg
   hdiutil verify dist/ONIWA-v0.1.1-macos.dmg
   ```

   The DMG must not be modified or rebuilt after the outer-container notarization/stapling. If anything changes, repeat the necessary signing and notarization steps.

7. Test dragging the app from the mounted DMG to **/Applications**, launching the actual installed copy, granting Accessibility as prompted, then checking single-Space, fullscreen and Sidecar two-display switching. Also test the **downloaded GitHub Release DMG** (with quarantine/Gatekeeper) before considering v0.1.1 complete.

The notarization ZIP is for submission only; the final artifact is the **stapled DMG**. Publishing is a separate explicit release action. Do not upload the draft DMG or claim it has passed the steps above until the actual Mac tests succeed.

## Verification record — 2026-11-04

- GitHub Actions (macOS build): Swift unit tests, development build, and release-script safety checks passed on PR #26.
- The Developer ID Application-signed `dist/ONIWA.app` built successfully with Hardened Runtime and a secure timestamp. `codesign --verify --deep --strict` passed.
- On the owner's M4 MacBook Air, the signed candidate launched and the owner confirmed single-Space switching, Chrome fullscreen Space switching, and two-display Space-set switching with Sidecar.
- Apple notarization submission returned **Accepted**. The accepted ticket was stapled to `dist/ONIWA.app`; `xcrun stapler validate` and `spctl --assess --type execute -vv` succeeded (`accepted`, `source=Notarized Developer ID`).
- The final `dist/ONIWA-v0.1.0-macos.zip` was created **after** stapling. It was extracted to a fresh directory under Downloads; `stapler validate` passed; the running process path was confirmed to point to that extracted copy, and the owner confirmed two-display switching worked there.
- Not yet separately verified: installing that fresh copy into `/Applications`, a **browser-downloaded** ZIP with the macOS quarantine attribute, and compatibility on other macOS versions. Do not present those as already tested.

## Permission troubleshooting: development vs distribution copies

`build/ONIWA.app` and `dist/ONIWA.app` use the same bundle identifier (`com.hiro259.oniwa`) but different signatures/locations. macOS privacy approvals may need to be reapplied when switching between them. **Quit all running ONIWA copies first** to ensure the candidate rather than an already-running development process is launched.

During release validation, Space enumeration and mouse positioning worked, but keyboard injection was blocked with `post-event-access-denied` (the `CGPreflightPostEventAccess()` check was false). After reauthorizing the distribution copy and resetting the app-specific privacy approvals, Space switching worked; the exact combination of approvals that resolved it was not isolated.

If this occurs again, inspect System Settings → Privacy & Security → Accessibility and ensure that the **intended distribution copy** is authorized. If toggling permission and restarting ONIWA does not help, the following app-scoped resets can be used before reauthorizing the app. They can also revoke the development copy's approval:

```fish
tccutil reset Accessibility com.hiro259.oniwa
tccutil reset PostEvent com.hiro259.oniwa
```

Launch the distribution copy and verify the actual executable path, not merely the window title:

```fish
open dist/ONIWA.app
ps axww -o command= | grep '[O]NIWA.app/Contents/MacOS/ONIWA'
```

Do not disable Hardened Runtime or add broad exception entitlements to work around an unverified permissions failure.

**Note:** Notarization checks signatures and malware, not whether ONIWA's private macOS API integrations will continue working on future operating systems. It is separate from Mac App Store review.
