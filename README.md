# Pop Mac

Pop Mac brings the [Pop!_OS Shell](https://github.com/pop-os/shell) tiling window manager to macOS.
It ports Pop Shell's tiling tree, keyboard workflow, tile mode, and launcher to a native menu bar app.
Pop Shell's window stacking is not included.

## Features

| Pop Shell | Pop Mac |
| --- | --- |
| Auto-tiling into a tree of forks, per display and workspace | Same. Each display on each macOS Space has its own tree. |
| New windows split the previously focused window | Same |
| Directional focus with Super + arrows / hjkl | Same |
| Tile mode (Super + Return): move, resize, swap, orientation | Same, including the grid overlay for floating windows |
| Drag a tiled window to re-tile it, with a drop preview | Drop on an edge of a window to split its tile. Drop on its center to swap the two windows. |
| Resize a tiled window with the mouse | Same. The neighbors follow. |
| Toggle floating (Super + G) | Same. Every standard window tiles; only windows you float with Super + G float. Floating window exceptions are not included. |
| Toggle auto-tiling (Super + Y) | Same. Windows return to their original frames. |
| Move window to another display | Same |
| Move window to another workspace | Moves the window to the previous or next Space (see limitations) |
| Inner and outer gaps, smart gaps | Same |
| Launcher (Super + /) | Search windows and apps. `=` calculates, `:` runs a command, `/` or `~` opens files. |
| Cursor follows the active window | Same |
| Snap floating windows to the grid | Same |

## Install

You need macOS 13 or later and the Swift toolchain (Xcode or the Command Line Tools).

```sh
make install          # builds build/PopMac.app and copies it to ~/Applications
open ~/Applications/PopMac.app
```

On the first start, macOS asks for Accessibility access.
Grant it in System Settings > Privacy & Security > Accessibility. Pop Mac starts when access is granted.

The build signs the app with the first "Apple Development" certificate in your keychain.
A stable signature keeps the Accessibility access across rebuilds.
To pick another certificate, set `SIGN_IDENTITY` to its name or SHA-1 hash:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make install
```

Without a certificate, the build signs ad-hoc. The ad-hoc signature changes on every build,
so macOS asks for Accessibility access again after each rebuild.

Use **Launch at Login** in the menu bar menu to start Pop Mac automatically.

### Recommended macOS settings

- System Settings > Desktop & Dock: turn off **Drag windows to screen edges to tile** and **Drag windows to menu bar to fill screen**.
  The native tiling fights with Pop Mac.
- System Settings > Desktop & Dock > Mission Control: turn off **Automatically rearrange Spaces based on most recent use**.
- System Settings > Keyboard > Keyboard Shortcuts > Mission Control: keep **Move left a space** (⌃←) and **Move right a space** (⌃→) on.
  Pop Mac uses them to move windows between Spaces.

## Shortcuts

A Mac keyboard has no Super key. By default, `<Super>` is **⌃⌥** (Control + Option), and `<Primary>` is **⌘**.
Both are configurable. The menu bar item **View All Shortcuts…** shows the current bindings.

| Action | Keys |
| --- | --- |
| Focus window left / down / up / right | ⌃⌥ ← ↓ ↑ → or ⌃⌥ H J K L |
| Enter tile mode | ⌃⌥ ↩ |
| Launcher | ⌃⌥ / |
| Toggle orientation | ⌃⌥ O |
| Toggle floating | ⌃⌥ G |
| Toggle auto-tiling | ⌃⌥ Y |
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
| Apply and exit | ↩ |
| Exit | ⎋ |

## Configuration

Settings live in `~/.config/pop-mac/config.json`. Pop Mac reloads the file when it changes.
The menu bar item **Edit Config File…** opens it. Missing keys use their defaults.

```json
{
  "tileByDefault": true,
  "gapInner": 8,
  "gapOuter": 8,
  "smartGaps": false,
  "overlayColor": "#FBB86C",
  "overlayBorderRadius": 10,
  "mouseCursorFollowsActiveWindow": true,
  "mouseCursorFocusLocation": "center",
  "snapToGrid": false,
  "columnSize": 64,
  "rowSize": 64,
  "maxWindowWidth": 0,
  "superModifiers": ["control", "option"],
  "primaryModifiers": ["command"],
  "keybindings": {
    "focus-left": ["<Super>Left", "<Super>h"],
    "tile-move-left-global": ["<Super><Shift>Left"]
  }
}
```

- `keybindings` uses Pop Shell's action names and key syntax.
  Modifiers are `<Super>`, `<Primary>`, `<Shift>`, `<Control>`, `<Alt>` (Option), and `<Cmd>`.
  A binding replaces all default keys of its action. An empty list disables the action.
- `mouseCursorFocusLocation` is one of `center`, `top-left`, `top-right`, `bottom-left`, or `bottom-right`.

## Limitations

macOS restricts what a window manager can do. These parts differ from Pop Shell:

- **Spaces:** Pop Mac cannot create Spaces. To move a window to another Space, it drags the window's title bar and presses ⌃← or ⌃→. This depends on the Mission Control shortcuts, and some apps may not respond to it.
- **Native tabs:** each macOS tab is a window. The selected tab takes the tile of the tab it replaced.
- **Snap back:** a tiled window that something other than a mouse drag moves returns to its tile.
- **Minimum sizes:** Some windows refuse to shrink below a minimum size. They can overlap their neighbors.
- **Animations:** windows move without animation.
- Pop Mac learns about windows on other Spaces when you first visit those Spaces.

## Development

```sh
make test     # unit tests for the tiling engine
make build    # debug build
make run      # build the app bundle and open it
.build/debug/PopMac --diagnose   # print displays, Spaces, and windows, then exit
POP_MAC_DEBUG=1 build/PopMac.app/Contents/MacOS/PopMac   # verbose log on stderr
```

The code has two parts:

- `Sources/PopCore` is the tiling engine without any AppKit code. It ports Pop Shell's `fork.ts`, `forest.ts`, `auto_tiler.ts`, `focus.ts`, and parts of `tiling.ts`. The tests in `Tests/PopCoreTests` cover it.
- `Sources/PopMac` is the macOS app. It reads and moves windows through the Accessibility API, catches key bindings with a keyboard event tap, and draws the overlay and launcher with AppKit.

## License

Pop Mac is a derivative of Pop Shell by System76, and is licensed under the GNU GPL v3. See [LICENSE](LICENSE).
