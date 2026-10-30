# Using Pop Mac

## Features

| Pop Shell | Pop Mac |
| --- | --- |
| Auto-tiling into a tree of forks, per display and workspace | Same. Each display on each macOS Space has its own tree. |
| New windows split the previously focused window | Same |
| Directional focus with Super + arrows / hjkl | Same |
| Tile mode (Super + Return): move, resize, swap, orientation, stacking | Same, including the grid overlay for floating windows |
| Stacking (Super + S) with a tab bar | Same. Click a tab, or press Super + Tab and Super + Shift + Tab, to switch tabs. Drag a tab to change the order of the tabs. Drag the handle at the right end of the bar to move the whole stack. |
| Drag a tiled window to re-tile it, with a drop preview | Drop on an edge of a window to split its tile. Drop on its center to swap the two windows, or hold Super at the drop to stack them. The preview says "Switch windows" or "Stack window". |
| Resize a tiled window with the mouse | Same. The neighbors follow. |
| Toggle floating (Super + G), floating window exceptions | Same. Every standard window tiles, unless you float it with Super + G or a rule in `floatRules` matches it. |
| Toggle auto-tiling (Super + Y) | Same. Windows stay where they are when tiling turns off. |
| Tiling survives a restart of the shell | Pop Mac saves the layout in `~/.config/pop-mac/layout.json` and rebuilds it, with its stacks, when it starts or when you turn tiling on again. Windows of apps that restarted meanwhile tile as new windows. |
| Move window to another display | Same |
| Move window to another workspace | Moves the window to the previous or next Space (see limitations) |
| Active hint around the focused window | Same. Turn it off in **Settings > Appearance**. |
| Inner and outer gaps, smart gaps | Same |
| Launcher (Super + /) | Search windows and apps. `=` calculates, `:` runs a command, `/` or `~` opens files. |
| Cursor follows the active window | Same |
| Snap floating windows to the grid | Same |

## Settings

Pop Mac runs in the menu bar. On the first start, a window asks for Accessibility access and then shows the main shortcuts.

The menu bar item turns tiling on or off, floats the focused window, opens the launcher, and opens **Settings**:

| Tab | Settings |
| --- | --- |
| General | Tile automatically, launch at login, move the cursor with keyboard focus |
| Layout | Gaps between windows and at the screen edges, smart gaps, maximum window width |
| Appearance | The outline around the focused window, and how much to darken the wallpaper behind a single window |
| Shortcuts | The keys that Super and Primary stand for, and every shortcut |
| Floating | Rules for windows that float instead of tile |

Hold ⌥ while the menu is open to show **Copy Tiling Tree**, which copies the layout for bug reports.

## Starting and updating

To start Pop Mac at login, turn on **Launch at login** in its settings.

To update, run `brew upgrade --cask pop-mac`. To run the latest commit instead of the latest release,
build it from source, as [DEVELOPMENT.md](DEVELOPMENT.md) describes.

If you installed Pop Mac with the `pop-mac` formula before, switch to the cask once:

```sh
brew uninstall pop-mac && brew install --cask krystxf/tap/pop-mac
```

## Accessibility access

On the first start, macOS asks for Accessibility access.
Grant it in System Settings > Privacy & Security > Accessibility. Pop Mac starts when access is granted.

Releases are signed with a Developer ID and notarized by Apple, so the access stays across updates.
A build from source without a certificate is signed ad-hoc, and that signature changes with every build.
macOS then asks for access again: remove the old "PopMac" entry from the Accessibility list, and allow the new one.

## Recommended macOS settings

- System Settings > Desktop & Dock: turn off **Drag windows to screen edges to tile** and **Drag windows to menu bar to fill screen**.
  The native tiling fights with Pop Mac.
- System Settings > Desktop & Dock > Mission Control: turn off **Automatically rearrange Spaces based on most recent use**.
- System Settings > Keyboard > Keyboard Shortcuts > Mission Control: keep **Move left a space** (⌃←) and **Move right a space** (⌃→) on.
  Pop Mac uses them to move windows between Spaces.

## Limitations

macOS restricts what a window manager can do. These parts differ from Pop Shell:

- **Spaces:** Pop Mac cannot create Spaces. To move a window to another Space, it drags the window's title bar and presses ⌃← or ⌃→. This depends on the Mission Control shortcuts, and some apps may not respond to it.
- **Stacks:** macOS cannot hide a single window of another app. Stacked windows overlap in one tile, and the selected tab's window is raised above the others.
- **Native tabs:** each macOS tab is a window. The selected tab takes the tile of the tab it replaced.
- **Snap back:** a tiled window that something other than a mouse drag moves returns to its tile.
- **Minimum sizes:** macOS does not tell other apps a window's minimum size, so Pop Mac learns it the first time a window refuses a smaller tile. Its neighbors then make room. If the minimums on a display add up to more than it has, windows still overlap.
- **Animations:** Pop Mac moves another app's window one step at a time through Accessibility. A slow app takes fewer steps, so its windows glide less smoothly, and some apps redraw their content a moment after each resize.
- Pop Mac learns about windows on other Spaces when you first visit those Spaces.
