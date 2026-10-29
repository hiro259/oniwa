# ONIWA

Free, open-source macOS Spaces switcher with custom names and fuzzy search.
ONIWA uses **native macOS Mission Control Spaces**, not a separate virtual desktop engine.

**Status: early prototype ([PR #2](https://github.com/hiro259/oniwa/pull/2), related to Issue #1).** The search UI and custom shortcut recorder have been confirmed on a real Mac. Space switching still needs hands-on verification, especially across monitors.

## First prototype

- **New installations:** `⌥ Option + Space` opens the search palette by default. Existing installations retain their previously selected shortcut until changed. The menu-bar **庭** remains the fallback if a combination is intercepted by macOS.
- Finds native desktops and fullscreen Spaces grouped by display.
- Set a display name and search aliases (e.g. `shumi chrome`) by clicking the pencil.
- Partial, prefix and subsequence search. **While typing in the search field**, ↑ / ↓ select results, Enter switches to the highlighted Space, and Esc closes ONIWA. The key event router leaves active IME composition alone.
- Labels are local UserDefaults data. No analytics or network requests.
- Space discovery uses private **read-only** SkyLight symbols. Switching uses Apple's standard `Ctrl+← / →` behavior through System Events. It now confirms **each neighboring Space** before continuing; it stops on unexpected movement, disappearing Spaces, or reordering.

## Build (macOS)

Requires macOS 13+, Apple developer command line tools or Xcode.

```fish
cd ~/Developer/oniwa
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

The identity value is the local certificate's public identifier, **not a password or private key**. If a suitable identity is absent, builds still work ad-hoc, but reauthorizing Accessibility may be necessary. Never commit certificates or private keys to this repository. Signing with a development identity is **not** a substitute for Developer ID distribution signing and notarization.



macOS may request **Automation** permission for controlling System Events on the first Space switch. Enable the default `Control+Left / Control+Right` shortcuts under System Settings → Keyboard → Keyboard Shortcuts → Mission Control. The menu-bar **庭 → ショートカット** allows choosing the recommended `⌥Space`, the previous presets, or **ショートカットを記録…** to capture any combination with ⌘, ⌃ or ⌥ plus another key. Press the combination in the recording field and click **設定する**; cancel or registration failure restores the previous shortcut. **庭 → ショートカット診断…** shows whether Carbon registration succeeded and the number of events ONIWA actually received since launch. Registration success alone does not guarantee delivery: a system or other application shortcut can intercept the keys.

## macOS permission troubleshooting

If selecting a Space displays a red error, the search and SkyLight enumeration have worked; **the System Events AppleScript step failed**. The updated UI reports the actual AppleScript error code instead of always claiming an Automation denial.

- **-1743:** System Settings → Privacy & Security → Automation → ONIWA → allow **System Events**.
- **-1719 or 1002** (System Events reports 'not allowed to send keystrokes'): System Settings → Privacy & Security → Accessibility → enable **ONIWA**. If it appears enabled after rebuilding ad-hoc, quit ONIWA, toggle it off/on, and relaunch. If necessary, remove/re-add the exact `build/ONIWA.app` path.
- **Other code:** record the numeric code and brief message; the cause may be unrelated to permissions.
- The system may prompt for access only after the first attempted Space switch. Quit/relaunch ONIWA after changing a denied permission, then retry.
- Without `ONIWA_CODESIGN_IDENTITY`, development builds use ad-hoc signing; rebuilding can change the code identity macOS uses for authorization. For repeated updates, use a persistent local signing identity and the same app path. Do not run blanket `tccutil reset` commands because they revoke permissions for unrelated apps.
## Manual switching checks (before merging)

1. In **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, enable **Move left/right a space** (`Ctrl+←` and `Ctrl+→`); ONIWA uses those built-in shortcuts.
2. Launch ONIWA and give different names to two regular desktops and one fullscreen window, then search for each name. Check that Enter reaches the **named target**, not merely the next Space.
3. Verify a target on another display (built-in → external / Sidecar) while a different Space stays open on the first display. A target display may receive the pointer: confirm this is acceptable.
4. Try a target already visible, then add/remove/reorder a Space and refresh the search; ensure stale targets do not cause repeated wrong switches.
5. If the first jump requests macOS **Automation** access to System Events, grant access and retry. If it fails, ONIWA should reopen with a visible error message instead of claiming success.
6. Disconnect a display or close a fullscreen Space and confirm ONIWA handles the vanished target without crashing.

**Limitations:** These checks are not fully automated. macOS private SkyLight discovery and System Events delivery can change in new OS versions. The `Ctrl+arrow` shortcuts must be enabled and may be intercepted by other software. A display-wide switch affects other apps on that same display.
## Known limitations / safety

- GitHub Actions checks macOS compilation and unit tests. The user has confirmed that the search UI, custom shortcut and a selected Space switch work on a real Mac. **New keyboard-only result selection still requires hands-on confirmation.**
- SkyLight is private and can change between macOS releases. ONIWA degrades to an error if enumeration is unavailable; no SIP disablement or direct private Space writes.
- Multi-monitor Space switching uses cursor positioning to target the requested display; must be tested with built-in, external and Sidecar screens, including “Displays have separate Spaces”.
- Mission Control's displayed names are **not** renamed. Custom names exist only in ONIWA.
- Fullscreen Spaces are recreated by macOS and their custom names may not persist after closing/reopening the fullscreen window.
- Spaces can reorder or disappear; ONIWA rechecks IDs before switching, but complex transitions still need real-world testing.
- The recommended hotkey is Option+Space; it may type a nonbreaking space or conflict with macOS/third-party shortcuts on some computers. Use the recorder to select another combination when needed. A successful Carbon registration does not guarantee events are delivered.
- The draft prioritizes the search flow. Visual free-placement maps and managing windows are out of scope for v0.1.

## Acknowledgements

Space-switching techniques researched with reference to MIT-licensed
[spaceSwitcher](https://github.com/ccarpiog/spaceSwitcher) and
[SpacesManager](https://github.com/michaeltorbert/spaces-manager).
See the source projects for their code and licenses.

## License

MIT. See [LICENSE](LICENSE).
