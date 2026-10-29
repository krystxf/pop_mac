# Pop Mac

Pop Mac brings the [Pop!_OS Shell](https://github.com/pop-os/shell) tiling window manager to macOS.
It runs in the menu bar and tiles the windows of each display and Space in a tree: a new window splits the focused one,
and you move focus and windows with the keyboard. Like Pop Shell, Pop Mac is licensed under the GNU GPL v3.

[![Pop Mac demo: tiling, swapping windows by dragging, and stacking them](docs/pop-mac-drag-demo.gif)](docs/pop-mac-drag-demo.mp4)

The demo shows tiling. Dragging a window onto another one swaps them, and holding Super at the drop stacks them.

## Contents

- [Shortcuts](SHORTCUTS.md)
- [Usage](USAGE.md)
- [Configuration](CONFIGURATION.md)
- [Development](DEVELOPMENT.md)

## Install

Pop Mac needs macOS 13 or later. Homebrew builds it from source, so it also needs Xcode 16 or later.

```sh
brew install krystxf/tap/pop-mac
open "$(brew --prefix)/opt/pop-mac/PopMac.app"
```

On the first start, allow Pop Mac in System Settings > Privacy & Security > Accessibility.
To update, run `brew upgrade pop-mac`.
