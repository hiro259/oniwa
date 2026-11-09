# ONIWA v0.1.3

ONIWA is a free, open-source macOS menu-bar app for finding and switching native Mission Control Spaces by name. This maintenance update improves search reliability, primary Desktop pinning, and Space tag editing.

## What's new

- **Pin the original Desktop (#31).** The built-in primary Desktop can now be pinned even when macOS reports an explicitly empty Space UUID. ONIWA uses a display-scoped identity only when it can identify that desktop unambiguously; it never guesses from a changing Desktop number or numeric Space ID.
- **More reliable shortcut search focus (#32).** When you reopen the search palette with your global keyboard shortcut, ONIWA restores focus to the search field after the palette becomes the active window. Space and pair editors retain their own keyboard focus.
- **Click detected app icons to toggle tags (#35).** In a Space's name/tag editor, click an app icon or its name to add that application's name as a manual search tag. Click it again to remove the tag. Existing tags are preserved, duplicate tags are prevented, and changes are saved only when you choose **Save**.
- **Improved editing layout (#35).** App icons and names remain visible when tags are added. The editor can scroll on smaller displays, while its Save and Cancel buttons stay accessible.

## Install / upgrade

Download **ONIWA-v0.1.3-macos.dmg**, open it, and drag **ONIWA.app** to **Applications**. Quit an already-running ONIWA before upgrading.

Homebrew users can upgrade after the official tap has been updated:

```sh
brew update
brew upgrade --cask hiro259/tap/oniwa
```

ONIWA requires **macOS 13 or later**, macOS's **Control+Left / Control+Right** Mission Control Space shortcuts, and Accessibility / keyboard-event permission for Space switching. Existing names, tags, pinned results, preferences and shortcuts remain in local app storage.

## Known limitations

ONIWA relies on read-only private SkyLight APIs to discover macOS Spaces, so compatibility with future macOS releases cannot be guaranteed. Spaces created or recreated by fullscreen apps may receive new identities; ONIWA does not silently remap saved names or sets to a different Space. A disconnected second display can make its saved two-display set temporarily unavailable.

No launch-at-login option is included in v0.1.3; that work remains separate.

Source changes: [#31](https://github.com/hiro259/oniwa/issues/31), [#32](https://github.com/hiro259/oniwa/issues/32), [#35](https://github.com/hiro259/oniwa/issues/35).
