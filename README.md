# CloseQuits

A tiny macOS menu-bar utility that makes an app's red close (×) button **quit the app** instead of
just closing its window — because the minimize (yellow) button already exists for hiding windows.

![CloseQuits menu bar](docs/screenshots/closequits-menu.webp)

## Features

- **Quit on close** — clicking the red × on an app's last window quits the app (`terminate()`), so
  unsaved-changes prompts still appear as usual.
- **Only when the window really closed** — the app is quit only after the click finishes and its
  last window is actually gone. Dragging off the button, cancelling a "Save?" sheet, or closing one
  of several windows leaves the app running.
- **Auxiliary windows close normally** — Quick Look previews, panels and other non-main windows are
  never treated as a quit.
- **Spaces-aware** — windows open on other desktops count, so an app is not quit while it still has
  a window on another Space.
- **System-wide, zero input lag** — a listen-only event tap feeds a background Accessibility check,
  so clicks are never delayed, even when the app under the cursor is hung.
- **Menu-bar only** — runs as an `LSUIElement` with no Dock icon and a negligible footprint.
- **Enable/disable** — toggle the behavior from the menu bar icon at any time.
- **Finder-safe** — Finder is excluded so the desktop/icons are never killed.
- **QuickShare-Mac-safe** — QuickShare-Mac (`tools.macexplorer.quickshare`) is excluded so its Send
  window (transfers, PIN confirmation, QR wake) always closes normally instead of quitting the app.
- **Universal binary** — Apple Silicon and Intel, macOS 13 or later.
- **No third-party dependencies** — pure AppKit/ApplicationServices, ad-hoc signed.

## Requirements

- macOS 13 or later
- Accessibility permission (see [Permissions](#permissions))
- To build from source: Xcode Command Line Tools (`xcode-select --install`); Xcode 16+ also works

## Install

### Option 1: DMG (easiest)

1. Open `release/CloseQuits-1.1.0.dmg`
2. Drag **CloseQuits.app** into **Applications**
3. Open it from Applications (right-click → **Open** the first time, since the build is ad-hoc signed)

### Option 2: Build from source

```bash
./build.sh release
cp -R "$HOME/Library/Caches/CloseQuitsBuild/CloseQuits.app" /Applications/
open "/Applications/CloseQuits.app"
```

### Option 3: Build and package a DMG

```bash
./package.sh          # builds universal app, writes release/CloseQuits-<version>.dmg
```

## Permissions

CloseQuits needs **Accessibility** access to read the UI element under the cursor and create the
event tap:

1. Open the menu-bar icon → **Grant Accessibility Access…** (shows the system prompt with an
   **Open System Settings** button), or go to **System Settings → Privacy & Security →
   Accessibility**.
2. Enable **CloseQuits**.
3. Within ~2 seconds the menu shows *Accessibility: Granted* and the tap starts — no relaunch
   needed. Revoking access stops the tap the same way.

> **After updating or rebuilding:** the app is ad-hoc signed, so every new build has a different
> signature and macOS silently stops trusting it, even though the switch in Settings still looks
> on. Remove CloseQuits from the Accessibility list (−) and add it again.

## Usage

| Action | How |
| --- | --- |
| Quit an app by closing it | Click the red × on any window |
| Enable / disable | Menu bar icon → **Quit on Close** (checkmark = on; greyed out until Accessibility is granted) |
| Check permission status | Menu bar icon shows *Accessibility: Granted* or *Grant Accessibility Access…* |
| Quit CloseQuits | Menu bar icon → **Quit CloseQuits** (or `⌘Q` with menu open) |

Minimize (yellow) and zoom (green) keep their normal behavior. The menu-bar icon is dimmed whenever
quit-on-close is not active (disabled or no Accessibility access).

## How it works

- A listen-only `CGEvent` tap observes left mouse down/up and hands the location to a background
  queue, so the tap never blocks input. Accessibility calls have a 0.25 s timeout.
- On mouse-down, `AXUIElementCopyElementAtPosition` finds the element under the cursor. It is a
  candidate only if it has the `AXCloseButton` subrole (or is a button equal to its window's
  `kAXCloseButtonAttribute`), belongs to the app's main window, the app isn't excluded (Finder,
  QuickShare-Mac), and that is the app's only window.
- On mouse-up, the app's windows are polled for up to 1.5 s. Once it has no windows left — counted
  via the Accessibility windows list plus `CGWindowListCopyWindowInfo` for windows on other Spaces
  (using private SkyLight calls to skip hidden, ordered-out windows; AX only if unavailable) —
  the app is sent `terminate()`. If the window is still there, nothing happens.
- Accessibility trust is re-checked every 2 s; the tap starts/stops accordingly and is recreated if
  macOS invalidates it.

### Known limitations

- A close that completes later than 1.5 s after the click (e.g. after answering a "Save?" sheet)
  leaves the app running.
- Minimized windows on another Space may not be counted.

## Project layout

```
close-quits/
├── Sources/
│   └── main.swift        # AppDelegate, CloseQuitManager, event tap, AX detection
├── Resources/
│   └── Info.plist        # LSUIElement menu-bar app
├── docs/
│   └── screenshots/      # README images
├── build.sh              # universal (arm64 + x86_64) build
├── package.sh            # release build + DMG
└── README.md
```

Not affiliated with Apple. macOS is a trademark of Apple Inc.

## Provenance

CloseQuits is an **original project, not a fork**. Its source was written from scratch for this
repository. The close-to-quit behavior is inspired by the Windows title-bar convention (the × quits
the app) and by macOS utilities that remap the red close button; no upstream source code, assets, or
licenses were copied.

## License

MIT — see [LICENSE](./LICENSE).