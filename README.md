# Pop Mac

Pop Mac brings the [Pop!_OS Shell](https://github.com/pop-os/shell) tiling window manager to macOS.
It ports Pop Shell's tiling tree, keyboard workflow, tile mode, stacking, and launcher to a native menu bar app.

## Features

| Pop Shell | Pop Mac |
| --- | --- |
| Auto-tiling into a tree of forks, per display and workspace | Same. Each display on each macOS Space has its own tree. |
| New windows split the previously focused window | Same |
| Directional focus with Super + arrows / hjkl | Same |
| Tile mode (Super + Return): move, resize, swap, orientation, stacking | Same, including the grid overlay for floating windows |
| Stacking (Super + S) with a tab bar | Same. Click a tab, or press Super + Tab and Super + Shift + Tab, to switch tabs. |
| Drag a tiled window to re-tile it, with a drop preview | Drop on an edge of a window to split its tile. Drop on its center to swap the two windows, or hold Super at the drop to stack them. The preview says "Switch windows" or "Stack window". |
| Resize a tiled window with the mouse | Same. The neighbors follow. |
| Super + drag moves a window | Same. Hold Super (⌃⌥ by default) and drag anywhere in a window. |
| Toggle floating (Super + G), floating window exceptions | Same. Every standard window tiles, unless you float it with Super + G or a rule in `floatRules` matches it. |
| Toggle auto-tiling (Super + Y) | Same. Windows stay where they are when tiling turns off. |
| Tiling survives a restart of the shell | Pop Mac saves the layout in `~/.config/pop-mac/layout.json` and rebuilds it when it starts. Windows of apps that restarted meanwhile tile as new windows. |
| Move window to another display | Same |
| Move window to another workspace | Moves the window to the previous or next Space (see limitations) |
| Active hint around the focused window | Same. Turn it off in **Settings > Appearance**. |
| Inner and outer gaps, smart gaps | Same |
| Launcher (Super + /) | Search windows and apps. `=` calculates, `:` runs a command, `/` or `~` opens files. |
| Cursor follows the active window | Same |
| Snap floating windows to the grid | Same |

## Using Pop Mac

Pop Mac runs in the menu bar. On the first start, a window asks for Accessibility access and then shows the main shortcuts.

The menu bar item turns tiling on or off, floats the focused window, opens the launcher, and opens **Settings**:

| Tab | Settings |
| --- | --- |
| General | Tile automatically, launch at login, move the cursor with keyboard focus, snap floating windows to the grid |
| Layout | Gaps between windows and at the screen edges, smart gaps, maximum window width |
| Appearance | A preview of the highlights, and the outline around the focused window |
| Shortcuts | The keys that Super and Primary stand for, and every shortcut |
| Floating | Rules for windows that float instead of tile |

Hold ⌥ while the menu is open to show **Copy Tiling Tree**, which copies the layout for bug reports.

## Install

Pop Mac needs macOS 13 or later.

### Homebrew

```sh
brew install krystxf/tap/pop-mac
open "$(brew --prefix)/opt/pop-mac/PopMac.app"
```

Homebrew builds Pop Mac from source, so it needs Xcode 16 or later.
To start Pop Mac at login, turn on **Launch at login** in its settings, or run `brew services start pop-mac`.

To update, run `brew upgrade pop-mac`. To install the latest commit instead of the latest release, run
`brew install --HEAD krystxf/tap/pop-mac`.

### From source

You need the Swift toolchain (Xcode or the Command Line Tools).

```sh
make install          # builds build/PopMac.app and copies it to ~/Applications
open ~/Applications/PopMac.app
```

The build signs the app with the first "Apple Development" certificate in your keychain.
A stable signature keeps the Accessibility access across rebuilds.
To pick another certificate, set `SIGN_IDENTITY` to its name or SHA-1 hash:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make install
```

Without a certificate, the build signs ad-hoc.

### Accessibility access

On the first start, macOS asks for Accessibility access.
Grant it in System Settings > Privacy & Security > Accessibility. Pop Mac starts when access is granted.

An ad-hoc signature changes with every build, including every Homebrew upgrade.
macOS then asks for access again: remove the old "PopMac" entry from the Accessibility list, and allow the new one.

### Recommended macOS settings

- System Settings > Desktop & Dock: turn off **Drag windows to screen edges to tile** and **Drag windows to menu bar to fill screen**.
  The native tiling fights with Pop Mac.
- System Settings > Desktop & Dock > Mission Control: turn off **Automatically rearrange Spaces based on most recent use**.
- System Settings > Keyboard > Keyboard Shortcuts > Mission Control: keep **Move left a space** (⌃←) and **Move right a space** (⌃→) on.
  Pop Mac uses them to move windows between Spaces.

## Shortcuts

A Mac keyboard has no Super key. By default, `<Super>` is **⌃⌥** (Control + Option), and `<Primary>` is **⌘**.
Both are configurable in **Settings > Shortcuts**, which also lists the current bindings.

| Action | Keys |
| --- | --- |
| Focus window left / down / up / right | ⌃⌥ ← ↓ ↑ → or ⌃⌥ H J K L |
| Enter tile mode | ⌃⌥ ↩ |
| Launcher | ⌃⌥ / |
| Toggle orientation | ⌃⌥ O |
| Toggle floating | ⌃⌥ G |
| Toggle auto-tiling | ⌃⌥ Y |
| Toggle stacking | ⌃⌥ S |
| Next / previous tab of a stack | ⌃⌥ ⇥ / ⌃⌥⇧ ⇥ |
| Move window to display | ⌃⌥⇧⌘ ← ↓ ↑ → |
| Move window to previous / next Space | ⌃⌥⇧ ↑ / ⌃⌥⇧ ↓ |
| Toggle maximize | ⌃⌥ M |
| Close window | ⌃⌥ Q |
| Minimize window | ⌃⌥ , |

In tile mode:

| Action | Keys |
| --- | --- |
| Move window | ← ↓ ↑ → or H J K L |
| Resize (→ ↓ grow, ← ↑ shrink) | ⇧ + arrows |
| Select a window to swap with | ⌘ + arrows |
| Toggle orientation | O |
| Toggle stacking | S |
| Apply and exit | ↩ |
| Exit | ⎋ |

## Configuration

Most settings are in the **Settings** window, which you open from the menu bar item.
Everything is stored in `~/.config/pop-mac/config.json`, and you can also edit that file directly.
Pop Mac reloads it when it changes. Missing keys use their defaults.
If the file has an error, the menu bar icon shows a warning, and Pop Mac keeps the last good settings.

```json
{
  "tileByDefault": true,
  "gapInner": 8,
  "gapOuter": 8,
  "smartGaps": false,
  "overlayBorderRadius": 10,
  "activeHint": true,
  "activeHintWidth": 3,
  "animations": true,
  "mouseCursorFollowsActiveWindow": true,
  "mouseCursorFocusLocation": "center",
  "snapToGrid": false,
  "superDragMovesWindows": true,
  "columnSize": 64,
  "rowSize": 64,
  "maxWindowWidth": 0,
  "superModifiers": ["control", "option"],
  "primaryModifiers": ["command"],
  "keybindings": {
    "focus-left": ["<Super>Left", "<Super>h"],
    "tile-move-left-global": ["<Super><Shift>Left"]
  },
  "floatRules": [
    { "app": "^com\\.apple\\.calculator$" },
    { "app": "Slack", "title": "Huddle" },
    { "app": "Finder", "title": "^Applications$", "disabled": true },
    { "app": "Finder" }
  ]
}
```

- `keybindings` uses Pop Shell's action names and key syntax.
  Modifiers are `<Super>`, `<Primary>`, `<Shift>`, `<Control>`, `<Alt>` (Option), and `<Cmd>`.
  A binding replaces all default keys of its action. An empty list disables the action.
- `floatRules` make matching windows float instead of tile. The first matching rule wins.
  - `app` matches the app name (`Calculator`) or the bundle id (`com.apple.calculator`).
  - `title` matches the window title.
  - Both are case-insensitive regular expressions, so `Slack` also matches `Slack Beta`. Use `^…$` for an exact match.
  - A rule with both `app` and `title` needs both to match.
  - `"disabled": true` makes matching windows tile. Put it before a broader rule to make an exception to it.
  - ⌃⌥G on a window that a rule floats makes it tile anyway, until Pop Mac restarts.
  - Pop Mac applies rule changes as soon as you save the file.
  - Built-in rules float the Google Meet web app and Keka, whose window has a fixed size.
    They come after your rules, so `{ "app": "Keka", "disabled": true }` makes Keka tile.
  - A browser window on a Meet call tiles. Meet's picture-in-picture window always floats.
  - Rules follow window titles: a window floats when its title starts to match a rule, and tiles again when it stops matching.
- The selected stack tab uses the system accent color. Before macOS 26, so do tile mode, drop previews, and the active hint.
- `overlayBorderRadius` rounds the highlights of windows whose own corner radius Pop Mac cannot read.
- `superDragMovesWindows` lets you hold the Super modifiers and drag anywhere in a window to move it.
  Pop Mac consumes that click, so the app under the cursor does not see it.
- `activeHint` draws an outline around the focused window. `activeHintWidth` is its width in points.
- `animations` makes windows glide into their tiles, and the outline, drop previews, and tab bars glide and fade.
  Animations stay off while Reduce Motion is on in System Settings > Accessibility > Display.
- `mouseCursorFocusLocation` is one of `center`, `top-left`, `top-right`, `bottom-left`, or `bottom-right`.

## Limitations

macOS restricts what a window manager can do. These parts differ from Pop Shell:

- **Spaces:** Pop Mac cannot create Spaces. To move a window to another Space, it drags the window's title bar and presses ⌃← or ⌃→. This depends on the Mission Control shortcuts, and some apps may not respond to it.
- **Stacks:** macOS cannot hide a single window of another app. Stacked windows overlap in one tile, and the selected tab's window is raised above the others.
- **Native tabs:** each macOS tab is a window. The selected tab takes the tile of the tab it replaced.
- **Snap back:** a tiled window that something other than a mouse drag moves returns to its tile.
- **Minimum sizes:** macOS does not tell other apps a window's minimum size, so Pop Mac learns it the first time a window refuses a smaller tile. Its neighbors then make room. If the minimums on a display add up to more than it has, windows still overlap.
- **Animations:** Pop Mac moves another app's window one step at a time through Accessibility. A slow app takes fewer steps, so its windows glide less smoothly, and some apps redraw their content a moment after each resize.
- Pop Mac learns about windows on other Spaces when you first visit those Spaces.

## Development

```sh
make lint     # SwiftFormat in lint mode
make format   # apply SwiftFormat
make test     # unit tests for the tiling engine
make build    # debug build
make run      # build the app bundle and open it
.build/debug/PopMac --diagnose   # print displays, Spaces, and windows, then exit
POP_MAC_DEBUG=1 build/PopMac.app/Contents/MacOS/PopMac   # verbose log on stderr
POP_MAC_SHOW_WELCOME=1 build/PopMac.app/Contents/MacOS/PopMac   # show the first-run window
kill -USR1 "$(pgrep -f PopMac.app/Contents/MacOS/PopMac)"   # write the tiling tree to the log
swift scripts/make-icon.swift   # redraw Resources/AppIcon.icns
POP_MAC_SNAPSHOT_DIR=/tmp/shots build/PopMac.app/Contents/MacOS/PopMac   # save images of the settings pages
```

`make prod` installs the Homebrew release as **Pop Mac Prod** in `~/Applications`, next to your development build.
Only one copy can manage windows, so starting a build quits the other one. Pop Mac Prod needs its own Accessibility access.

CI runs on every push and pull request. It checks the formatting with SwiftFormat, lints the
shell script and the workflow, builds with warnings as errors, runs the tests, and builds the app
bundle. The bundle is attached to each run as the `PopMac` artifact.

The code has two parts:

- `Sources/PopCore` is the tiling engine without any AppKit code. It ports Pop Shell's `fork.ts`, `forest.ts`, `auto_tiler.ts`, `focus.ts`, and parts of `tiling.ts`. The tests in `Tests/PopCoreTests` cover it.
- `Sources/PopMac` is the macOS app. It reads and moves windows through the Accessibility API, catches key bindings with a keyboard event tap, and draws the overlay, active hint, stack tabs, and launcher with AppKit.

## License

Pop Mac is a derivative of Pop Shell by System76, and is licensed under the GNU GPL v3. See [LICENSE](LICENSE).
