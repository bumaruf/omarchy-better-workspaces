# Omarchy Better Workspaces

GNOME / Pop!_OS COSMIC style workspaces for [Omarchy](https://omarchy.org) (Hyprland 0.56+, Lua config).

- **Span displays**: one workspace covers every monitor; switching changes all of them at once.
- **Dynamic**: empty workspaces disappear, the rest renumber without gaps, and there is always
  one empty workspace after the last occupied one.
- **Vertical navigation** (COSMIC), or horizontal (GNOME) via `orientation`.
- **Overview**: thumbnails of every workspace with live window previews, drag and drop.
- **Bar widget**: shows only the workspaces that exist, plus the trailing empty one.

## Install

```bash
./install.sh     # symlinks this checkout into ~/.config, swaps the bar widget
./uninstall.sh   # removes it and restores omarchy.workspaces
```

Then set your monitor order in `~/.config/hypr/workspaces.lua`.

## Keys

| Keys | Action |
|------|--------|
| `SUPER + `` ` ``` (key left of 1) | Overview |
| `SUPER + CTRL + UP / DOWN` | Previous / next workspace |
| `SUPER + CTRL + SHIFT + UP / DOWN` | Move window to previous / next workspace |
| `SUPER + 1..0` | Go to workspace N (clamped to the trailing empty one) |
| `SUPER + SHIFT (+ ALT) + 1..0` | Move window (silently) to workspace N |
| `SUPER + TAB`, `SUPER + scroll` | Next / previous workspace |
| `SUPER + CTRL + TAB` | Former workspace |
| `SUPER + CTRL + ALT + UP / DOWN` | Move the current workspace up / down the list |



In the overview: `UP/DOWN` select, `RETURN` switch, `1..9` jump, `ESC` close; click a thumbnail
to switch, click a window to focus it, middle-click to close it, drag it onto a thumbnail to move it (also across monitors), or hold it between two thumbnails
to open a new workspace there. Drag a thumbnail to reorder workspaces.

## How it works

`hypr/better-workspaces/init.lua` encodes both coordinates in the workspace id:
`id = slot * 100 + n`, where `slot` is the monitor's position in `monitors` and `n` the logical
workspace. Workspace rules pin each id to its monitor. On window and workspace events the module
renumbers with `hl.dsp.workspace.change_id`, so compacting never moves windows, and keeps every
monitor on the same `n`.

Scripts can drive it: `hyprctl eval 'o.better_workspaces.go(3)'`, `.step(1)`, `.move_window(n, follow)`.

## Development

The shell's hot-reload doesn't see edits behind the plugin symlink, so after changing QML run
`omarchy restart shell`. Lua changes apply with `hyprctl reload`; check `hyprctl configerrors`.
