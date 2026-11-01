# CloseQuits

A tiny macOS menu-bar utility that makes an app's red close (×) button **quit the app** instead of
just closing its window — because the minimize (yellow) button already exists for hiding windows.

![CloseQuits menu bar](docs/screenshots/closequits-menu.webp)

## Features

- **Quit on close** — clicking any app's red × sends `terminate()` to that app, so it actually quits.
- **System-wide** — works across all apps via a low-level event tap + Accessibility, including apps
  with custom title bars (falls back to a "close" title/description match).
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

1. Open `release/CloseQuits-1.0.0.dmg`
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

1. Open the menu-bar icon → **Grant Accessibility Access…** (jumps straight to the right pane), or
   go to **System Settings → Privacy & Security → Accessibility**.
2. Enable **CloseQuits**.
3. The menu-bar icon updates to *Accessibility: Granted* and the tap starts automatically — no
   relaunch needed.

## Usage

| Action | How |
| --- | --- |
| Quit an app by closing it | Click the red × on any window |
| Enable / disable | Menu bar icon → **Enable/Disable Quit-on-Close** |
| Check permission status | Menu bar icon shows *Accessibility: Granted* or *Grant Accessibility Access…* |
| Quit CloseQuits | Menu bar icon → **Quit CloseQuits** (or `⌘Q` with menu open) |

Minimize (yellow) and zoom (green) keep their normal behavior.

## How it works

- A `CGEvent` tap on left-mouse-down reads the element under the cursor via
  `AXUIElementCopyElementAtPosition`.
- If that element is a close button (`kAXCloseButtonSubrole`, with a title/description fallback),
  the owning process (from `AXUIElementGetPid`) is terminated after a short delay.
- The tap re-enables itself if macOS disables it on timeout, and only starts when Accessibility
  is granted.

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