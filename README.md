# Pop Mac

Pop Mac brings the [Pop!_OS Shell](https://github.com/pop-os/shell) tiling window manager to macOS.
It ports Pop Shell's tiling tree, keyboard workflow, tile mode, stacking, and launcher to a native menu bar app.

## Features

| Pop Shell | Pop Mac |
| --- | --- |
| Auto-tiling into a tree of forks, per display and workspace | Same. Each display on each macOS Space has its own tree. |
| New windows split the previously focused window | Same |
| Directional focus with Super + arrows / hjkl | Same. Left and right also cycle through stack tabs. |
| Tile mode (Super + Return): move, resize, swap, orientation, stacking | Same, including the grid overlay for floating windows |
| Stacking (Super + S) with a tab bar | Same. Click a tab to focus its window. |
| Drag a tiled window to re-tile it, with a drop preview | Same. Drop on an edge to split, or on the center to stack. |
| Resize a tiled window with the mouse | Same. The neighbors follow. |
| Toggle floating (Super + G), floating exceptions | Same. Rules match the app name, bundle id, and window title. |
| Toggle auto-tiling (Super + Y) | Same. Windows return to their original frames. |
| Move window to another display | Same |
| Move window to another workspace | Moves the window to the previous or next Space (see limitations) |
| Active hint around the focused window | Same |
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

The default build uses an ad-hoc signature, which changes on every build.
After a rebuild, macOS asks for Accessibility access again.
To keep access, sign with your own certificate:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make install
```

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
| Toggle stacking | ⌃⌥ S |
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
| Toggle stacking | S |
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
  "activeHint": true,
  "activeHintWidth": 3,
  "activeHintBorderRadius": 10,
  "hintColor": "#FBB86C",
  "stackingWithMouse": true,
  "showStackTabs": true,
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
  },
  "floatRules": [
    { "app": "^com\\.apple\\.finder$" },
    { "app": "Slack", "title": "Huddle" },
    { "app": "com.apple.calculator", "disabled": true }
  ]
}
```

- `keybindings` uses Pop Shell's action names and key syntax.
  Modifiers are `<Super>`, `<Primary>`, `<Shift>`, `<Control>`, `<Alt>` (Option), and `<Cmd>`.
  A binding replaces all default keys of its action. An empty list disables the action.
- `floatRules` are case-insensitive regular expressions.
  `app` matches the app name or the bundle id. `title` matches the window title.
  A rule with `"disabled": true` makes matching windows tile, even if a built-in rule floats them.
- `mouseCursorFocusLocation` is one of `center`, `top-left`, `top-right`, `bottom-left`, or `bottom-right`.

## Limitations

macOS restricts what a window manager can do. These parts differ from Pop Shell:

- **Stacks:** macOS cannot hide a single window of another app. Stacked windows overlap in one tile, and the active window is raised above the others.
- **Spaces:** Pop Mac cannot create Spaces. To move a window to another Space, it drags the window's title bar and presses ⌃← or ⌃→. This depends on the Mission Control shortcuts, and some apps may not respond to it.
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
- `Sources/PopMac` is the macOS app. It reads and moves windows through the Accessibility API, registers hot keys through Carbon, and draws the overlay, active hint, stack tabs, and launcher with AppKit.

## License

Pop Mac is a derivative of Pop Shell by System76, and is licensed under the GNU GPL v3. See [LICENSE](LICENSE).
