# ONIWA

Free, open-source macOS Spaces switcher with custom names and fuzzy search.
ONIWA uses **native macOS Mission Control Spaces**, not a separate virtual desktop engine.

**Status: working prototype on `main` (Issue #1).** Search, names, shortcut handling, instant Space switching and switching between two displays have been verified on a real Mac. Sidecar, display reconnection and more complex fullscreen cases still need additional checks.

## Default Space switching on the `feat/issue-11-space-pairs` branch

**The standard strategy is now the 50ms rapid `Control+←/→` burst** for both single Spaces and two-monitor Space sets.

- ONIWA reads the current Space order and UUID identities, then sends exactly the adjacent-arrow presses needed, 50ms apart. It does **not** wait for each intermediate Space, nor open Mission Control.
- After the burst it verifies target and unrelated displays' Space IDs and stable UUID/order at 150, 350, 600, 850 and 1200ms. If the destination is wrong, the layout changes, or the state remains uncertain, ONIWA **stops without extra arrows or automatic rollback**.
- Two-monitor switching is sequential: finish and verify display 1, then switch and verify display 2, followed by a final cross-display readback. This is a single *user action*, not simultaneous macOS events.
- Ordinary installations **always select 50ms on startup**, including installations that previously saved a gesture/MC/numbered-Desktop experiment mode. No OS shortcut preferences, SIP settings or display settings are changed.
- The menu shows **切り替え方式：⌃←/→ 高速連打（50ms・標準）**. The earlier Mission Control, synthetic swipe, 100ms burst, numbered Desktop and step-by-step switchers are retained in source for future comparison, but their controls are hidden from normal builds. Developers can compile with the optional Swift define `ONIWA_LEGACY_SWITCHING_UI` to expose the archived menu and saved experimental routing again.
- **Real-Mac evidence (2026-11-01):** all 13 sampled 50ms burst switches and all five sampled paired switches completed and passed the delayed ID checks; jumps up to seven neighboring Spaces were observed. This is promising, **not** a claim of universal reliability.
- Research log: [Issue #15](https://github.com/hiro259/oniwa/issues/15); ongoing pair feature: [Issue #11](https://github.com/hiro259/oniwa/issues/11); code under [Draft PR #14](https://github.com/hiro259/oniwa/pull/14).

## Search palette design presets (Issue #12 — preview)

**macOS Native is currently the only visible palette design.** The design chooser is hidden because it has only one selectable option. The other seven presets remain implemented but temporarily hidden; they can be restored later. This is presentation-only and does not change the 50ms Space switching route, query matching, selection, pinned order or saved Space/pair identities.

| # | Preset | Design focus |
|---|---|---|
| 1 | Native Calm (hidden) | Restrained native macOS style |
| 2 | Frosted Focus (hidden) | Material-backed translucent controls |
| 3 | Command Compact (hidden) | Dense, keyboard-first palette |
| 4 | Studio Cards (hidden) | Larger, spacious workspace cards |
| 5 | Monitor Focus (hidden) | Clearer per-display and pair cues |
| **6** | **Modern Precision (hidden)** | Raycast/Linear-inspired refinement: custom slim search outline, quiet focus glow, subtly graded and translucent row surfaces, smooth hover/selection, restrained indigo accents |
| **7** | **Pure Monochrome (hidden)** | Apple-native minimalism: more whitespace, visual hierarchy through text, no routine row borders or tag pill backgrounds, thin selection marker and selective accent |
| **8** | **macOS Native** | macOS-inspired ultra-thin glass palette; borderless rows and chips, Spotlight-like search, fading hover-only pin/edit buttons, compact sorting Menu |

Previously saved choices remain in `oniwa.paletteDesign` (UserDefaults), but **macOS Native is always displayed** while it is the only visible preset; missing or unknown values also fall back to macOS Native. Historical choices are not erased. For presets 6, 7 and 8, the search field uses a plain input instead of the standard AppKit-blue rounded focus ring. Native semantic colors support light/dark appearances, while old macOS 13 remains supported—no latest-OS-exclusive Liquid Glass APIs are required.

The other seven designs are retained in source but not selectable for now. The UI work is in [Draft PR #16](https://github.com/hiro259/oniwa/pull/16), with detailed criteria and user feedback in [Issue #12](https://github.com/hiro259/oniwa/issues/12). The eighth design also uses a transparent NSPanel backing to reveal genuine ultra-thin material, and exposes row actions through a context menu when they are visually hidden. Its selected row uses a subdued full-width accent fill (without a left accent stripe), drag handles, pin and edit actions appear together on selected **or** hovered rows, and pin symbols stay neutral. Editing sheets use macOS system-adaptive backgrounds, plain fields with restrained focus outlines, and system bordered/primary actions. macOS sheet translucency is not supported by the OS, so the editing sheets intentionally use the native system window background instead of claiming real frosted-glass transparency. **This is a visual prototype** until real-device appearance, accessibility and keyboard/IME behavior have been checked.

### Adjustable background transparency (macOS Native — preview)

Choose **庭 → 背景の透明度** (English: **Background Transparency**) while the **macOS Native** palette preset is active. Adjust the 0–100% slider to reveal more or less of the underlying wallpaper; the open palette updates immediately. **0%** means the semantic system background completely covers the glass material, **100%** means the raw ultra-thin material with no system-color wash. The default **20%** is close to the previously verified legible appearance. Use **標準の透明度に戻す（20%）** to reset. Settings persist across ONIWA restarts through `oniwa.nativeGlassTransparencyPercent`. The other presets are hidden, and their rendering code is unchanged. macOS Increased Contrast always enforces a high-opacity minimum for readability.

### Dark wallpaper contrast (macOS Native — preview)

The transparent NSPanel continues to use `ultraThinMaterial`, but an appearance-aware `windowBackgroundColor` wash prevents a black or highly saturated wallpaper from determining the palette's foreground contrast. The wash opacity is user-adjustable; macOS increased-contrast accessibility settings enforce a higher minimum opacity. The search field also uses a more defined native semantic fill and a subtle 1 pt focus outline; selected and hovered rows have stronger, separate semantic highlights. These changes affect **only macOS Native**, and do not alter search, input routing, saved Space data, or switching.

**Manual visual verification still required:** compare light/dark appearance on black, bright and colorful wallpaper; verify readable secondary text and keyboard hints, selected vs hovered vs current rows, search focus, and increased-contrast appearance. The macOS build in CI cannot assess actual WindowServer blur and wallpaper sampling.

## macOS language auto-detection (separate follow-up PR)

On first launch, ONIWA follows the Mac's highest-priority preferred language: **Japanese** if it starts with `ja`; **English** for English and all other languages (fallback). This is evaluated again when the app starts, so changing the macOS language affects the next launch as long as no manual language has been chosen.

In the menu choose **庭 → 言語 → 自動（macOSの言語） / 日本語 / English** (or **ONIWA → Language → Automatic (macOS language) / 日本語 / English**). Choosing Japanese or English explicitly stores the override in `oniwa.interfaceLanguage`; it always takes precedence over the Mac's preference and survives restarts. Choosing Automatic restores system-following mode. Existing explicit Japanese/English settings are not changed during upgrade.

The setting only localizes the interface. User-authored Space names, tags, pair names and the Space switcher remain untouched. The language UI updates immediately on a menu change. To pick up a language change in macOS System Settings, restart ONIWA. The follow-up is developed on top of PR #16 and is merged separately.

## UI copy and bilingual display (Issue #12 — preview)

The search palette, Space/tag editor, paired-Space editor, main menu, and normal diagnostics now have shorter Japanese wording and an English alternative. Switch via **庭 → 言語 → 日本語 / English** (English: **ONIWA menu → Language → Japanese / English**). The choice is saved to `UserDefaults` at `oniwa.interfaceLanguage`, applied immediately through SwiftUI `@AppStorage`, and kept after restart. The menu updates without restarting the app or re-registering its global hotkey. Existing explicit Japanese/English settings remain authoritative; users without a manual choice follow macOS.

The app does not translate user-authored Space names, tag text, or paired-Space names. It only localizes interface copy. The `macOS Native` theme is the only exposed preset for now; seven older designs remain implemented but hidden. Its selected and hovered row controls, switching engine, search ranking, saved tags, and Space identities are unchanged. New `AppLanguageTests` verify both languages, defaults, and persistence.

Mac manual checks before merge: switch languages with the search palette open and while an editor sheet is visible; check menus, sorting, help, names and tags, font fit, display labels, restart persistence, keyboard/IME, and both visual appearances. Experimental archived switching menus behind `ONIWA_LEGACY_SWITCHING_UI` remain developer-only.

## First prototype

- **New installations:** `⌥ Option + Space` opens the search palette by default. Existing installations retain their previously selected shortcut until changed. The menu-bar **庭** remains the fallback if a combination is intercepted by macOS.
- Finds native desktops and fullscreen Spaces grouped by display.
- The **currently visible Space** on each display has a subtle neutral outline and **✓ current** badge; the accent-colored row background separately indicates the keyboard-selected result.
- Set a display name and search keywords (aliases) by clicking the pencil. Existing saved aliases are preserved; keywords can be separated with spaces, commas or `#` (e.g. `shumi chrome`, `#shumi #chrome`, `shumi,chrome`).
- Partial, prefix and subsequence search. **While typing in the search field**, ↑ / ↓ select results, Enter switches to the highlighted Space, and Esc closes ONIWA. The key event router leaves active IME composition alone.
### Search keywords and ranking (Issue #4, first pass)

- User-defined names and explicit search keywords rank ahead of matches found in app names or monitor names **when match quality is equal**. Exact matches rank ahead of prefix, word-start, substring and subsequence matches.
- Query terms may match **across fields**: a saved keyword `shumi` and running app `Google Chrome` match `shumi chrome` or `#shumi #chrome`. Matching is local; no API calls.
- `shumi` → `趣味`, `kai` → `開発` and `hp` → `ホームページ制作` work **when you manually register** `shumi`, `kai` and `hp` as search keywords on those Spaces. Automatic conversion from kanji to romaji is **not implemented**. This is deliberate until a reliable local conversion approach is chosen.
- In the name editor, type a tag (including spaces such as `web development`) and press **Enter** to add it. Spaces and commas are part of the tag, **not separators**. Click a saved tag to edit it in the same text field and press Enter again; use the separate **×** to delete. Clicking Save also commits unfinished tag text.
- Tags are now stored as an **array**, preserving spaces and original capitalization. Earlier saved space-delimited aliases are automatically shown as individual tags when editing a Space; until then, the original alias data remains intact. No Space identity keys or label-storage key names change.
- Open apps (for example, **Slack** or **Google Chrome**) appear as **automatic app tags** on their Space when an app window can be detected there. They already participate in searches; these tags are refreshed when the search palette opens and **are never saved as manual tags**. App names are marked with a small app icon; manual tags begin with `#`.
- The results list shows a few chips per Space and `+N` if others are hidden, keeping the search palette compact.
- The search UI still selects a **single Space**. Tags are not separate selectable items. A `#` prefix is optional; it is not a tag-only filter.
- On an empty query results retain their existing order; a query containing only tag separators does not accidentally select an arbitrary Space.

- Labels are local UserDefaults data. No analytics or network requests.
- Space discovery uses private **read-only** SkyLight symbols. Switching posts the standard `Ctrl+← / →` shortcut through Core Graphics with a **HID-system-state event source**, explicit Control-key down/up, and the arrow-key Fn/NumericPad flags required on some macOS versions (not AppleScript/System Events). The **legacy step-by-step route** confirms each neighboring Space before continuing, whereas the new standard 50ms burst verifies the **settled final state**. Both stop on unexpected movement, missing/recreated Spaces, or changed monitor identity. The legacy route can replan after a pure UUID-preserving reorder; the rapid burst intentionally stops instead of continuing through a changed order.

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

## Two-monitor Space sets (experimental, Issue #11)

- In the ONIWA search palette, choose **セットを追加** to create a named set such as **ONIWA開発**.
- Select one Space on monitor 1 (e.g. `Chrome Dev ONIWA`) and one Space on a **different** monitor (e.g. `Term ONIWA`), then save. Create as many sets as needed.
- Sets appear alongside individual Space results and can be found by name, their member Space names, or member app names. The **same ↑/↓ → Enter** keyboard flow activates a set. Single-Space switching remains unchanged.
- To change or delete a set, click its pencil button. A pair whose target Space was removed or whose monitor was disconnected remains visible with a warning so you can reconfigure or delete it.
- Set targets use **display ID + Space UUID**, never Space number or window title. A Space without a UUID cannot be saved in a set (it cannot be reliably identified after relaunch). Pair data persists locally in UserDefaults, separate from individual Space labels.
- Switching is **sequential and verified**: first monitor, then second. If a target is already visible it is skipped. The first monitor's target is rechecked before the second transition; final IDs on both monitors and unrelated displays are checked after switching.
- A partially failed set displays the error and which step reached its target. ONIWA does **not** automatically roll back a successful first transition because a rollback could itself select an unintended Space.
- The default pair path uses the 50ms Control+Arrow burst described above. Historical instant, Mission Control and verified one-step keyboard implementations remain in source for investigation; SkyLight is still read-only.

### Switching target diagnostics (2026-10-30)

**Observed user symptom:** Some pair switches reach the requested Spaces, others move an unexpected monitor or fail. The exact affected OS state has not yet been reproduced in a Mac debugger.

**Likely bug in the previous implementation:** `CGWarpMouseCursorPosition` moves the cursor but does not generate a `mouseMoved` event (Apple-documented behavior). Dock and Mission Control can therefore still route a synthetic swipe/Control+Arrow to a previously active display. Previous verification polled only the requested display, missing a wrong-monitor transition until the end of the set.

**Mitigations:** ONIWA now posts a genuine, button-free mouseMoved after repositioning, checks that the pointer is on the requested display, samples all displays **after each gesture/key step** and aborts on any unrelated display change. Never send a fallback key after an unexpected change. A user moving the pointer to another monitor also aborts the pending keyboard fallback.

**Local diagnostic log:** `~/Library/Logs/ONIWA/switch.log` (rotated, capped at 256 KB). Use menu bar **庭 → 切り替え診断ログを開く…**, or in fish:

```fish
tail -n 80 ~/Library/Logs/ONIWA/switch.log
```

Trace lines include Space numeric IDs, shortened display IDs, intended step, actual confirmation, and `WRONG-DISPLAY` / timeout. For mismatch diagnosis they now also include the **selected visible Space name**, its abbreviated UUID and process-level app names; `space-map` lists the display's Space IDs with their saved labels and associated process names after a completed single switch. They do **not** include typed search terms or window/browser-tab titles. These are local files, never uploaded. **Review the log before sharing**, because saved Space names and process names may be personal. For current builds, compare `arrow-burst` and `arrow-burst-pair` trace entries with the final visible Space; old swipe experiments and menu controls are archived behind the optional `ONIWA_LEGACY_SWITCHING_UI` build flag. These traces are diagnostic evidence, not a guarantee that all OS-level routing bugs are fixed.
**Investigating “Trello” (or any other name) opened a different Space:** after a failed single-Space selection, compare the `ui-activate single name=[...]`/space ID to the `single-settled` and `space-map` lines for that display. If the correct numeric Space was reached but Trello is associated with a different ID, the problem is labeling/app-to-Space association rather than a missed swipe. ONIWA stores saved names against Space UUIDs, **not** a dynamically moving app window or browser tab. Recent-use reordering changes display order but should not reassign a UUID-backed label. A stale selected search result now refuses activation rather than silently launching the first unrelated result. Single-Space success also requires a delayed readback of the current Space ID (850 ms).

### macOS automatic Space reordering — Trello regression (2026-10-30)

A real Mac trace from 09:35:31 UTC captured the reproducible cause of an incomplete Trello switch: while navigating to Space `3085`, ONIWA confirmed Space IDs `2986 → 3121 → 3076 → 1`, then macOS reordered `3121` and `3076` in the live Spaces list. The original implementation aborted on **any** reorder, leaving the requested Trello destination unreached.

**Fix:** On each confirmed step, ONIWA now checks that the live layout is exactly a permutation of the original unique Space IDs, with the *same display+Space UUID identity for every member*. If so, it logs `order-replanned` and uses the **current** order to compute the next adjacent step. It aborts on added/removed/recreated Spaces, changed UUIDs, misrouted display events, an unconfirmed expected neighbor or repeated navigation states. A finite step budget also prevents switching loops. The keyboard fallback must still see the **same order as just before that event**; ONIWA never uses a stale direction after a gesture's timeout.

There is a regression test using the user's exact original and reordered ID arrays. The macOS feature **Automatically rearrange Spaces based on most recent use** can stay enabled; ONIWA does not modify it. This change is unverified on the user's screen until a new real-Mac test.

### Pair validation checklist (real Mac)

1. Create **ONIWA開発** pairing `Chrome Dev ONIWA` on the first display and `Term ONIWA` on the second. Search its name and press Enter; confirm both displays arrive at their assigned Spaces.
2. Keep one display on its target and switch again; only the other display should move.
3. Edit a saved pair, change either destination, and verify persistence after quitting/relaunching ONIWA. Delete a pair and confirm normal Space labels are unaffected.
4. Confirm the Space on any *unrelated* display remains unchanged.
5. Rearrange Spaces, then rename individual Space labels; the set should still select the original UUID identities.
6. Remove a target Space or disconnect its monitor; verify the pair reports unavailable and does not choose an arbitrary replacement. Recreate/reconnect and edit it explicitly.
7. Test fullscreen Spaces and the instant-switch ON/OFF setting. Check that failure messages do not claim success after only one display moved.
## Build (macOS)

Requires macOS 13+, Apple developer command line tools or Xcode.

```fish
cd ~/myfile/oniwa
git fetch origin
git switch main
git pull --ff-only origin main
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

## Archived: ONIWA-only synthetic swipe experiments (not the default)

**Historical research only.** The earlier version of ONIWA attempted a near-instant Space transition with a synthetic Dock swipe. The user-facing swipe toggle is hidden in ordinary builds now that 50ms Control+Arrow is standard. For regression testing, compile with `ONIWA_LEGACY_SWITCHING_UI` and select an older experiment mode. See [Issue #15](https://github.com/hiro259/oniwa/issues/15) for the observed delayed Space snap-back.

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

### Archived swipe-mode test checklist (requires the legacy build flag)

1. In an `ONIWA_LEGACY_SWITCHING_UI` build, enable **瞬時切り替え（試験的）** in the menu.
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
