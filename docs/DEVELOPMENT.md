# ONIWA — Development and verification notes

This document keeps implementation details, troubleshooting and historical experiments out of the user-facing [README](../README.md). The source code is authoritative. Dated sections describe what was observed **at that time**; they are not promises of current behavior.

## Source layout and build

- `Sources/ONIWA/`: macOS menu-bar app, keyboard shortcuts, native Space discovery and switching, panels and diagnostics.
- `Sources/ONIWACore/`: search, Space/monitor identity, persistent labels and pair data, selection and switching policies.
- `Tests/ONIWACoreTests/`: Swift unit tests. GitHub Actions runs `swift test` and `sh build.sh` on macOS.
- `Resources/AppIcon.icns`: bundled app icon; `Resources/Info.plist`: app metadata.
- `build.sh`: creates `build/ONIWA.app`. Local builds use ad-hoc signing unless a signing identity is provided.

### Stable local signing

An ad-hoc signature can change between rebuilds and cause macOS to request Accessibility authorization again. For repeated local development, use the **same app path** and a consistent *locally installed* code-signing identity:

```fish
security find-identity -v -p codesigning
# Use an actual 40-character SHA-1 identifier from the output.
set -gx ONIWA_CODESIGN_IDENTITY "YOUR_CERTIFICATE_SHA1"
sh build.sh
codesign -dv --verbose=2 build/ONIWA.app 2>&1
open build/ONIWA.app
```

The placeholder is not a valid identity; `build.sh` rejects missing and malformed certificate identifiers. The value identifies an installed signing certificate, not its private key. Never commit a certificate, private key or notarization credential. Apple Development signing is **not** equivalent to a Developer ID distribution signature. The current script signs with `--timestamp=none` and is for **local testing**, not a notarized public release. See [release preparation, Issue #6](https://github.com/hiro259/oniwa/issues/6) and the separate [distribution build / notarization guide](RELEASING.md).

To verify the bundled icon in a local build:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' build/ONIWA.app/Contents/Info.plist
ls -lh build/ONIWA.app/Contents/Resources/AppIcon.icns
```

## Current Space switching

ONIWA **discovers** native Spaces through private, read-only SkyLight calls and performs ordinary movement through simulated macOS `Control+←/→` keyboard shortcuts. It does **not** create separate virtual desktops, write to SkyLight, change SIP, or modify system Mission Control preferences.

- The normal path is a **50 ms adjacent-arrow burst**. It computes the necessary direction and number of steps from the live Space order rather than opening Mission Control.
- After the burst, the app checks the destination and layout stability at 150, 350, 600, 850 and 1200 ms. If it cannot confirm the destination, or the layout changes unexpectedly, it stops without blindly sending more keys or attempting a rollback.
- A two-display set is a **single requested action but sequential execution**, not a simultaneous system operation. The first display is switched and verified before the second; unrelated display identities are checked.
- macOS may reorder Spaces automatically. The historical step-by-step implementation can re-plan on a UUID-preserving permutation; the current 50 ms burst conservatively stops when layout changes during the operation.
- To target another display, switching may temporarily reposition the mouse pointer. This is separate from the user's **search palette display** preference.

Earlier Mission Control, Dock-swipe, numbered-desktop, 100 ms burst and step-by-step experiments are retained in source, but normal builds hide these controls. The optional compilation flag `ONIWA_LEGACY_SWITCHING_UI` exposes historical experiment menus for developers. Do not present them as supported user settings.

Related investigations: [Issue #15](https://github.com/hiro259/oniwa/issues/15) and [Issue #11](https://github.com/hiro259/oniwa/issues/11). The November 1, 2026 real-Mac sample in the historical notes recorded 13/13 successful single burst and 5/5 paired switches; this is a small sample, **not** a general reliability guarantee.

## Space identities, labels and pairs

- A Space's position or numeric Space ID is **not** its stable identity. Saved labels use **display identity + Space UUID**. Reordering does not cause the label to jump to a different Space.
- A Space without a stable UUID can have a **session-only** name, but that name is not persisted.
- Closing and recreating a fullscreen window can create a **new UUID**. Its previous label is intentionally **not** attached to a possibly unrelated Space.
- User-provided names and manual search tags are saved locally. Tags support spaces (`web development` can be one tag). Automatic app-name tags are separate from user-authored tags. Romanized aliases like `shumi` or `kai` work when explicitly entered; automatic kana/kanji transliteration is not implemented.
- Two-display sets reference one Space UUID on each of **two distinct displays**. Unavailable targets remain marked unavailable; the app does **not** guess a replacement from Space number, app name or position.
- Search palette display selection is a separate preference, using macOS display UUIDs. If the chosen monitor is disconnected, the palette falls back to the built-in/primary display, retaining the preference for reconnection.

Core implementations: `SpaceLabels.swift`, `SpacePairs.swift`, `FuzzySearch.swift` and `PaletteDisplaySelection.swift` in [ONIWACore](../Sources/ONIWACore/).

## Visual design, language and keyboard behavior

- **macOS Native** is the sole selectable design. Seven older palettes remain in source but are hidden; they are not features users can choose in the standard build. See [Issue #12](https://github.com/hiro259/oniwa/issues/12).
- The native palette uses the system appearance, an ultra-thin material background and an adjustable transparency wash (0–100%, default 20%). macOS Increased Contrast applies a more opaque minimum for legibility.
- The interface follows macOS language automatically (Japanese when the primary preference is Japanese, English otherwise), or a saved explicit Japanese/English choice. User-supplied Space names and tags are never translated.
- `↑/↓` choose search results; `Enter` activates; `Esc` closes. In the tag field, `Enter` adds/commits a tag. Editor sheets offer `⌘S` to save and `Esc` to cancel without requiring macOS's full keyboard navigation setting.
- The menu bar uses the four-stone template symbol rather than the full-color app icon.

## Diagnostic log and privacy

Local log: `~/Library/Logs/ONIWA/switch.log` (rotated and size-limited). In the ONIWA menu choose **診断 → 切り替え診断ログを開く… / Diagnostics → Open switching log…**, or:

```sh
tail -n 80 ~/Library/Logs/ONIWA/switch.log
```

Traces include abbreviated identifiers, current Space names, process-level app names and switch outcomes (`WRONG-DISPLAY`, timeouts, `arrow-burst`, `arrow-burst-pair`, `space-map`). They are stored locally and not automatically uploaded, but **review and redact before sharing**: custom names and process names may reveal personal work.

If a named Space appears to switch to the wrong place, compare the requested `ui-activate` target with `single-settled` and `space-map`. A correct numerical Space transition with an incorrect app association is a different problem from an incorrect switch event.

## Manual regression checklist

1. **Search and names:** name two desktops and one Chrome fullscreen Space; search and switch to each; verify arrow-key selection and manual aliases. Confirm names persist across ONIWA restart when UUID identities remain.
2. **Space reorder/recreation:** reorder in Mission Control, refresh ONIWA, and verify a name stays with its original UUID. Recreate a fullscreen Space and confirm an old label is not attached to a different Space.
3. **Two-display set:** assign a named set across two displays; switch both. Repeat when one target is already visible. Verify unrelated displays remain unchanged.
4. **Sidecar hotplug:** disconnect the iPad and confirm the missing set cannot silently target another Space. Reconnect and retest. Separately verify the palette display setting falls back to Mac and returns to iPad when its UUID is restored.
5. **Sleep/wake:** close and reopen the Mac; if macOS has disconnected Sidecar, reconnect the iPad using **macOS's display settings** before assessing ONIWA's set. No ONIWA set re-registration should be required when the same Space identities remain.
6. **Keyboard and language:** test shortcut registration, `⌘S` and `Esc` in editor sheets, Japanese IME, menu language changes and text contrast on light/dark wallpaper.
7. **Permissions and failures:** check the Accessibility prompt and ensure errors do not falsely report success. Keep macOS's `Control+←/→` Mission Control shortcuts enabled.

Real-Mac observations as of November 4, 2026: single-Space switching, named two-display sets, Chrome fullscreen switching, Sidecar reconnect, palette pinning and Mac sleep/wake **after macOS Sidecar reconnection** were reported working. A separate observation—YouTube video fullscreen after Chrome fullscreen caused a previously named Space to disappear—has **not** been diagnosed and should not be represented as a general passing case.

## Historical investigations (not the default behavior)

### Monitor targeting and wrong-display events (October 30, 2026)

The older route sometimes sent a transition to an unexpected monitor. `CGWarpMouseCursorPosition` moves the cursor without producing a corresponding `mouseMoved` event; synthetic keyboard/gesture targeting could still go to a previously active display. The investigation added explicit mouse-move delivery and checks for unrelated display movement. Current release-path validation differs from these old intermediate-step logs. See [Issue #15](https://github.com/hiro259/oniwa/issues/15).

### Automatic Space reordering / Trello (October 30, 2026)

A logged trace showed macOS reordering live Spaces during a multi-step move. The old step-by-step strategy began re-planning only when it could prove an unchanged set of UUID identities. The production 50 ms burst validates the final layout rather than assuming a stable step-by-step path. This remains sensitive to OS behavior and requires regression tests across macOS versions.

### Dock synthetic-swipe research (archived)

The old fast-path prototype used a synthetic Dock swipe and conditional keyboard fallback. It was found fragile under macOS version changes, with observed snap-back behavior. **It is not enabled in normal builds.** Source references: [noswoosh](https://github.com/mmathys/noswoosh), [Issue #15](https://github.com/hiro259/oniwa/issues/15), [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). The former user-facing “instant switch” experiment and its checklists should not be confused with ONIWA's normal 50 ms keyboard burst.

### Simulated key details on macOS 26/27

Earlier investigation found that posting only the Control modifier could be insufficient on some versions. ONIWA sends a Core Graphics HID-system-state key event sequence including Control down/up and the arrow Fn/NumericPad flags. Reference discussions: [OpenLogi #1653](https://github.com/AprilNEA/OpenLogi/issues/1653) and [spacekit research](https://github.com/cehbz/spacekit/blob/main/macos-spaces-research.md).

## Credits and license

Synthetic-swiping research draws on MIT-licensed [noswoosh](https://github.com/mmathys/noswoosh); full notices in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Space-switching research referenced [spaceSwitcher](https://github.com/ccarpiog/spaceSwitcher) and [SpacesManager](https://github.com/michaeltorbert/spaces-manager). ONIWA itself is MIT licensed; see [LICENSE](../LICENSE).
