# ONIWA

Free, open-source macOS Spaces switcher with custom names and fuzzy search.
ONIWA uses **native macOS Mission Control Spaces**, not a separate virtual desktop engine.

**Status: early prototype (PR for #1).** macOS runtime behavior is not verified yet.

## First prototype

- **New installations:** `⌥ Option + Space` opens the search palette by default. Existing installations retain their previously selected shortcut until changed. The menu-bar **庭** remains the fallback if a combination is intercepted by macOS.
- Finds native desktops and fullscreen Spaces grouped by display.
- Set a display name and search aliases (e.g. `shumi chrome`) by clicking the pencil.
- Partial, prefix and subsequence search; arrows to select, Enter to switch, Esc to dismiss.
- Labels are local UserDefaults data. No analytics or network requests.
- Space discovery uses private **read-only** SkyLight symbols. Switching tries Apple's standard `Ctrl+← / →` behavior through System Events.

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

The `build.sh` script is POSIX sh, callable from **fish** with `sh build.sh`. The built app is ad-hoc signed **for local testing only**. No notarized public release exists yet.

macOS may request **Automation** permission for controlling System Events on the first Space switch. Enable the default `Control+Left / Control+Right` shortcuts under System Settings → Keyboard → Keyboard Shortcuts → Mission Control. The menu-bar **庭 → ショートカット** allows choosing the recommended `⌥Space`, the previous presets, or **ショートカットを記録…** to capture any combination with ⌘, ⌃ or ⌥ plus another key. Press the combination in the recording field and click **設定する**; cancel or registration failure restores the previous shortcut. **庭 → ショートカット診断…** shows whether Carbon registration succeeded and the number of events ONIWA actually received since launch. Registration success alone does not guarantee delivery: a system or other application shortcut can intercept the keys.

## Known limitations / safety

- GitHub Actions checks macOS compilation and unit tests. The user has successfully launched the UI and received a previously registered shortcut on a real Mac, but this new recording UI and Option+Space still require real-Mac verification before merging.
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
