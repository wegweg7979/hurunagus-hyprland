# Workspaces plus (Omarchy bar widget)

A replacement for Omarchy's workspaces widget (Hyprland + Quickshell) that
puts five things in one row, each of which can be turned off:

- **Workspaces per monitor.** Each monitor's bar highlights the workspace that
  monitor is showing, not the globally focused one. It lists the workspaces
  open on that monitor plus those a Hyprland workspace rule assigns to it (as
  hyprmoncfg writes them). Without rules it shows 1-5 plus every open
  workspace, like the stock widget.
- **Layout.** A small label with the workspace's layout (Dwindle, Scrolling,
  Master, ...), optionally clickable to run a command of yours.
- **Window state.** An accent-coloured word for the focused window: `Max`,
  `Tiled FS`, `Float`, `Pop out` (floating and pinned), `Group i/n`, and
  `Square` while Omarchy's single-window square aspect toggle applies.
- **Open windows.** Icons for the windows open on the workspace that monitor
  is showing, in on-screen order (left to right, then top to bottom). The
  focused one is underlined. Click a window to focus it; click the focused
  one to minimize it.
- **Minimized windows.** Dimmed icons, after a thin divider, for the windows
  minimized from the workspace that monitor is showing. Hover for the title,
  click to restore.

It is a clone of `omarchy.workspaces` (`clonedFrom` in the manifest), so it
takes that widget's place and calls aimed at the stock widget reach it.

## Install

```bash
omarchy plugin add https://github.com/McNutty/omarchy-workspaces.git --enable
```

Then take `omarchy.workspaces` out of the bar if it is still there. For
development, symlink a checkout instead and run `omarchy restart shell` after
editing (a plugin hot-reload can keep running the old code):

```bash
ln -s ~/Code/personal/omarchy-workspaces ~/.config/omarchy/plugins/thord.workspaces
```

## Settings

Fields on the widget's entry in `~/.config/omarchy/shell.json`. A missing flag
counts as on:

```json
{ "id": "thord.workspaces", "layoutCycleCommand": "$HOME/.local/bin/workspace-layout-cycle" }
```

| Field | Default | Effect |
| --- | --- | --- |
| `perMonitor` | `true` | `false`: every bar lists 1-5 plus every open workspace. The highlight stays per monitor. |
| `showLayout` | `true` | `false`: no layout label. |
| `layoutCycleCommand` | `""` | Shell command run with the workspace id appended when the layout label is clicked. Empty: the label is display-only. |
| `showWindowState` | `true` | `false`: no window state label. |
| `showWindows` | `true` | `false`: no icons for the open windows. |
| `showMinimized` | `true` | `false`: no minimized icons, and `restoreLast` does nothing. |

Hyprland sends no event when a layout rule changes, so the label re-reads the
layout on workspace and monitor switches and reloads. A layout command can
update it at once with `hyprctl dispatch event thord.layout:changed`. Likewise
a binding that changes client-only fullscreen can send
`thord.window:changed`.

## Minimizing

Minimizing moves the window to the hidden workspace `special:min-<workspace id>`
without following it; the widget lists the windows on the one matching the
workspace its monitor shows. Hyprland holds all state, so a shell restart
loses nothing, and the icons take no space when there are none.

Bind keys in `~/.config/hypr/bindings.lua`: one to minimize, and optionally one
to restore the most recently minimized window of the focused workspace:

```lua
o.bind("SUPER + M", "Minimize window", function()
  local win = hl.get_active_window()
  if not (win and win.workspace) or win.workspace.special then return end
  hl.dispatch(hl.dsp.window.move({ workspace = "special:min-" .. win.workspace.id, follow = false }))
end)
o.bind("SUPER + ALT + M", "Restore last minimized window", "omarchy-shell -q thord.workspaces restoreLast")
```

## IPC

| Command | Effect |
| --- | --- |
| `omarchy-shell thord.workspaces restoreLast` | Restore the window most recently minimized from the focused workspace (newest first, so repeated calls work like a stack). |

If `omarchy-shell` reports "Target not found" right after installing or
updating, run `omarchy restart shell`.

## Credits

The window-to-app matching behind the icons (app id candidates, web apps by
host, windows the shell hosts told apart by title) and the on-screen window
order are adapted from [Spaces](https://github.com/tornikegomareli/omarchy-spaces)
by Tornike Gomareli, MIT licensed.

## Upgrading from omarchy-minimized

This repo was `omarchy-minimized` (plugin `thord.minimized`) up to 0.2.0.
Remove that plugin from the bar, change the restore binding from
`thord.minimized` to `thord.workspaces`, and install this one. Windows already
on `special:min-<id>` show up again as before.
