# Configuration

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
  "columnSize": 64,
  "rowSize": 64,
  "maxWindowWidth": 0,
  "superModifiers": ["control", "option"],
  "primaryModifiers": ["command"],
  "keybindings": {
    "focus-left": ["<Super>Left", "<Super>h"],
    "toggle-maximize": ["<Super>f"]
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
- `activeHint` draws an outline around the focused window. `activeHintWidth` is its width in points.
- `animations` makes windows glide into their tiles, and the outline, drop previews, and tab bars glide and fade.
  Animations stay off while Reduce Motion is on in System Settings > Accessibility > Display.
- `mouseCursorFocusLocation` is one of `center`, `top-left`, `top-right`, `bottom-left`, or `bottom-right`.
