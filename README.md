# ONIWA

Free, open-source macOS Spaces switcher with custom names and fuzzy search.
ONIWA uses **native macOS Mission Control Spaces**, not a separate virtual desktop engine.

**Status: early prototype ([PR #2](https://github.com/hiro259/oniwa/pull/2), related to Issue #1).** The search UI, custom shortcut recorder and at least one Space switch have worked on a real Mac. The revised Core Graphics switch method and multi-monitor behavior still need hands-on verification.

## First prototype

- **New installations:** `⌥ Option + Space` opens the search palette by default. Existing installations retain their previously selected shortcut until changed. The menu-bar **庭** remains the fallback if a combination is intercepted by macOS.
- Finds native desktops and fullscreen Spaces grouped by display.
- Set a display name and search aliases (e.g. `shumi chrome`) by clicking the pencil.
- Partial, prefix and subsequence search. **While typing in the search field**, ↑ / ↓ select results, Enter switches to the highlighted Space, and Esc closes ONIWA. The key event router leaves active IME composition alone.
- Labels are local UserDefaults data. No analytics or network requests.
- Space discovery uses private **read-only** SkyLight symbols. Switching posts the standard `Ctrl+← / →` shortcut through Core Graphics with a **HID-system-state event source**, explicit Control-key down/up, and the arrow-key Fn/NumericPad flags required on some macOS versions (not AppleScript/System Events). It now confirms **each neighboring Space** before continuing; it stops on unexpected movement, disappearing Spaces, or reordering.

## Space naming and persistence (Issue #3)

- Click the pencil on any Space to set a **display name** and **search aliases**; click **名前と別名を削除** to clear both.
- Multiple fullscreen windows of the same app (for example Chrome) are separate Spaces. Results show the monitor and Space number so they are distinguishable even before naming.
- Names update in the search results immediately after saving and survive an ONIWA restart **if that same Space still exposes a UUID**.
- Names are stored by **monitor identifier + Space UUID**, never by Mission Control position. Renaming or reordering a Space does not reassign a name to a different Space.
- If macOS supplies no UUID, ONIWA clearly marks the name as **session-only** and does not write it to disk. This is safer than restoring it onto an unrelated Space after a reorder/relaunch.
- When closing and reopening a fullscreen window, macOS may create a new Space UUID; ONIWA intentionally does **not** guess that this new Space is the old one. Rename it if needed.
- Existing v1 UUID labels are migrated only when their UUID is unique across currently connected monitors. Older position-based labels are **not** imported because their identity cannot be proven. Migrated labels are consumed so deleting a name does not restore its old value.
- The name appears **only inside ONIWA**, not in the standard macOS Mission Control UI.

### Name-management verification (real Mac)

1. Give two fullscreen Chrome Spaces separate names, such as **趣味** and **仕事**. Verify each result, each pencil edit, and each switch points to the right Space.
2. Close/reopen ONIWA without rebuilding; names for existing UUID-backed Spaces should remain.
3. Rearrange Spaces in Mission Control and refresh ONIWA; names should follow the original Space, not its former number.
4. Close and recreate a fullscreen Space; if the UUID changed, its old label must **not** attach to a different Space.
5. Rename a Space and search for the new name immediately; then delete the name and aliases.
6. Repeat with Sidecar connected and disconnected; names on one monitor must not migrate to the other.

Unit tests in `SpaceLabelsTests.swift` cover persistence, safe deletion, multi-monitor isolation, legacy migration, ambiguous UUIDs, and the no-UUID session-only fallback. Real-Mac tests are still needed for actual SkyLight UUID behavior.

## Build (macOS)

Requires macOS 13+, Apple developer command line tools or Xcode.

```fish
cd ~/myfile/oniwa
git fetch origin
git switch feat/spaces-search-foundation
swift test
sh build.sh
open build/ONIWA.app
```

The `build.sh` script is POSIX sh, callable from **fish** with `sh build.sh`. It uses ad-hoc signing if no identity is configured (including in CI), which **may invalidate Accessibility permissions after every rebuild**. No notarized public release exists yet.

### Stable local code signing (recommended for frequent rebuilds)

Because macOS ties accessibility permissions to the app's signing identity, repeatedly signing with `codesign --sign -` may make a newly compiled ONIWA untrusted even when the Settings toggle still appears enabled. Use a **consistent certificate and app path** for local builds:

```fish
security find-identity -v -p codesigning
# Use the SHA-1 identifier of an existing Apple Development or Developer ID Application identity:
set -gx ONIWA_CODESIGN_IDENTITY "YOUR_CERTIFICATE_SHA1"
sh build.sh
codesign -dv --verbose=2 build/ONIWA.app 2>&1
open build/ONIWA.app
```

The identity value must be an actual **40-character hexadecimal SHA-1** from the previous `security find-identity` output, not the literal `YOUR_CERTIFICATE_SHA1` placeholder. `build.sh` now rejects invalid or missing identities with a clear error. Setting the environment variable does not sign an already built app: rerun `sh build.sh`. The identity is a local certificate's public identifier, **not a password or private key**. If a suitable identity is absent, builds still work ad-hoc, but reauthorizing Accessibility may be necessary. Never commit certificates or private keys to this repository. Signing with a development identity is **not** a substitute for Developer ID distribution signing and notarization.



macOS may request **Accessibility / key-event posting** permission on the first Space switch. ONIWA no longer uses Apple Events or System Events to send keys. Enable the default `Control+Left / Control+Right` shortcuts under System Settings → Keyboard → Keyboard Shortcuts → Mission Control. The menu-bar **庭 → ショートカット** allows choosing the recommended `⌥Space`, the previous presets, or **ショートカットを記録…** to capture any combination with ⌘, ⌃ or ⌥ plus another key. Press the combination in the recording field and click **設定する**; cancel or registration failure restores the previous shortcut. **庭 → ショートカット診断…** shows whether Carbon registration succeeded and the number of events ONIWA actually received since launch. Registration success alone does not guarantee delivery: a system or other application shortcut can intercept the keys.

## macOS permission troubleshooting

ONIWA now checks macOS key-event posting permission with `CGPreflightPostEventAccess()` and, when missing, asks the OS via `CGRequestPostEventAccess()`. The old AppleScript error `1002` is avoided by no longer asking **System Events** to send keystrokes. This does **not** bypass macOS permissions: Accessibility permission is still necessary.

- **Permission denied:** System Settings → Privacy & Security → Accessibility → allow the actual `build/ONIWA.app` you run. Restart ONIWA after granting it.
- **Already enabled but still denied:** confirm the app path and signing identity. Quit the running ONIWA, remove the stale entry if necessary, and add the current build again.
- **Shortcut posted but Space did not move:** first try physical `Ctrl+←` and `Ctrl+→` on the target display. If those do not move between Spaces, verify System Settings → Keyboard → Keyboard Shortcuts → Mission Control. If physical keys work but ONIWA times out, inspect the HID simulation and display targeting; changing Accessibility permissions again will not fix that difference.
- **Diagnostic:** `庭 → ショートカット診断…` also shows Core Graphics key-posting permission status.
- Without `ONIWA_CODESIGN_IDENTITY`, development builds use ad-hoc signing; rebuilding can change the code identity macOS uses for authorization. For repeated updates, use a persistent local signing identity and the same app path. Do not run blanket `tccutil reset` commands because they revoke permissions for unrelated apps.
## Manual switching checks (before merging)

1. In **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, enable **Move left/right a space** (`Ctrl+←` and `Ctrl+→`); ONIWA uses those built-in shortcuts.
2. Launch ONIWA and give different names to two regular desktops and one fullscreen window, then search for each name. Check that Enter reaches the **named target**, not merely the next Space.
3. Verify a target on another display (built-in → external / Sidecar) while a different Space stays open on the first display. A target display may receive the pointer: confirm this is acceptable.
4. Try a target already visible, then add/remove/reorder a Space and refresh the search; ensure stale targets do not cause repeated wrong switches.
5. If the first jump requests **Accessibility / key-event posting** access, grant permission and restart ONIWA. If it fails, ONIWA should show a visible error instead of claiming success.
6. Disconnect a display or close a fullscreen Space and confirm ONIWA handles the vanished target without crashing.

**Limitations:** These checks are not fully automated. macOS private SkyLight discovery and Core Graphics event delivery can change in new OS versions. The `Ctrl+arrow` shortcuts must be enabled and may be intercepted by other software. A display-wide switch affects other apps on that same display.
## Known limitations / safety

- GitHub Actions checks macOS compilation and unit tests. The user has confirmed that the search UI, custom shortcut and a selected Space switch work on a real Mac. **New keyboard-only result selection still requires hands-on confirmation.**
- SkyLight is private and can change between macOS releases. ONIWA degrades to an error if enumeration is unavailable; no SIP disablement or direct private Space writes.
- Multi-monitor Space switching uses cursor positioning to target the requested display; must be tested with built-in, external and Sidecar screens, including “Displays have separate Spaces”.
- Mission Control's displayed names are **not** renamed. Custom names exist only in ONIWA.
- Fullscreen Spaces are recreated by macOS and their custom names may not persist after closing/reopening the fullscreen window.
- Spaces can reorder or disappear; ONIWA rechecks IDs before switching, but complex transitions still need real-world testing.
- The recommended hotkey is Option+Space; it may type a nonbreaking space or conflict with macOS/third-party shortcuts on some computers. Use the recorder to select another combination when needed. A successful Carbon registration does not guarantee events are delivered.
- The draft prioritizes the search flow. Visual free-placement maps and managing windows are out of scope for v0.1.

## ONIWA-only instant Space switching (experimental)

By default ONIWA attempts a near-instant Space transition **only when you
select a Space inside ONIWA**. Menu bar **庭 → 瞬時切り替え（試験的）**
turns this feature on or off. The setting is saved across launches.

- Uses the Dock's near-zero-travel synthetic swipe gesture (macOS 26.6+
  and macOS 27 only), keeping focus and normal Mission Control behavior.
- ONIWA checks the destination Space ID after **every single step**.
  If the fast attempt does not move, it checks the current ID again and tries
  the previously tested **Ctrl+←/→ keyboard path**. If a different Space
  appeared, it stops rather than risking a second movement.
- On macOS 26.0–26.5, macOS 15 and untested newer major releases such as
  macOS 28, the fast path is disabled and the normal switch is used.
  The 26.0–26.5 systems have a known blank-window issue with this swipe
  trick; see upstream [noswoosh](https://github.com/mmathys/noswoosh).
- **No** global event tap, LaunchAgent, separate daemon, accessibility setting
  changes, Dock preference changes, suppression of trackpad gestures, changes
  to the physical Ctrl+arrow shortcuts, or SIP changes.
- The private macOS event payload is fragile and may change on OS updates.
  ONIWA falls back when the destination transition isn't observed, but **the
  fast path is experimental until verified on the user's Mac**.
- Gestures are adapted from MIT-licensed
  [noswoosh](https://github.com/mmathys/noswoosh).
  See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Manual test checklist

1. In menu bar **庭**, keep **瞬時切り替え（試験的）** checked.
2. Open ONIWA, jump one Space left and one right; verify a fast transition and
   that each target is correct.
3. Jump across several Spaces and test fullscreen Chrome/Trello, including
   switching *from* a fullscreen Space.
4. Disable the feature in the menu; verify the previous animated Ctrl+arrow
   method still works.
5. Try an unsupported system (if available); switching should remain normal.
6. Test a Sidecar/external display and sleep/wake before treating the instant
   path as stable. If a switch seems wrong, turn instant mode off to keep the
   known-good path.

## macOS 26/27 simulated Space shortcuts

On macOS 27, a Core Graphics event with only `.maskControl` can be ignored by Mission Control even when Accessibility permission is granted and the physical keyboard works. ONIWA reproduces the verified four-event sequence (Control down, Arrow down/up with Control+SecondaryFn+NumericPad, Control up) using `.hidSystemState` and `.cghidEventTap`. Reference: [OpenLogi #1653](https://github.com/AprilNEA/OpenLogi/issues/1653) and [spacekit research](https://github.com/cehbz/spacekit/blob/main/macos-spaces-research.md). This **still requires a real-Mac test** on ONIWA before merging, especially with Sidecar.

## Acknowledgements

Synthetic Dock-swipes adapted from MIT-licensed [noswoosh](https://github.com/mmathys/noswoosh);
copyright and full license in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Space-switching techniques researched with reference to MIT-licensed
[spaceSwitcher](https://github.com/ccarpiog/spaceSwitcher) and
[SpacesManager](https://github.com/michaeltorbert/spaces-manager).
See the source projects for their code and licenses.

## License

MIT. See [LICENSE](LICENSE).
