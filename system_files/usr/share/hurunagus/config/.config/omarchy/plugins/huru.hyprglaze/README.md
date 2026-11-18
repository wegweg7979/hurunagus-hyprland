# huru.hyprglaze — shader wallpaper on the bar

A bar widget for [hyprglaze](https://github.com/slastra/hyprglaze), the Wayland
shader-wallpaper daemon Hurunagus ships. It shows whether the wallpaper is
running and opens a popup with the switches and pickers.

```
 ▍  Shader wallpaper                    [ ●]      <- click the glyph, or right-click to toggle
   2 MONITORS · FLUID
   ─────────────────────────────────
   MONITORS
   HDMI-A-1                          [ ●]
   DP-1                              [ ○]
   ─────────────────────────────────
   EFFECT
   Effect            [ fluid        ▾]
   THEME
   Theme             [ Rosé Pine    ▾]
   ─────────────────────────────────
   AUDIO
   Music reactivity                  [ ●]
   Turn it off for every audio effect too   [⟳]
   ─────────────────────────────────
   ~/.config/hypr/hyprglaze.toml
```

## What it drives

Nothing here reimplements hyprglaze. Every control is a call to the
`omarchy-hyprglaze` command shipped in the image, so the panel and a terminal
do exactly the same thing:

| Control | Command |
| --- | --- |
| master switch, right-click the glyph | `omarchy-hyprglaze on` / `off` |
| a monitor's switch | `omarchy-hyprglaze toggle <monitor>` |
| effect picker | `omarchy-hyprglaze set effect <name>` |
| theme picker | `omarchy-hyprglaze set theme <name>` |
| music switch | `omarchy-hyprglaze set music on\|off` |
| the ⟳ button | `omarchy-hyprglaze set music on\|off --all` |

State comes from `omarchy-hyprglaze status --json`, polled every 20 s when the
popup is closed and every 4 s while it is open. The effect and theme lists come
from `hyprglaze --list-effects` / `--list-themes`, so the pickers are never
stale relative to the binary in the image.

hyprglaze hot-reloads its config, so changing an effect or a theme lands on
every running instance at once without restarting anything. Switching a monitor
on or off starts/stops that monitor's `hyprglaze@<monitor>.service` and takes
the wallpaper back to Omarchy's own background when the last one stops.

## Interactions

- **Left-click** the glyph: open the popup.
- **Right-click** the glyph: turn the wallpaper on/off — the shortcut worth
  knowing, since the daemon costs GPU time and is the thing people forget is running.
- **Scroll** over the glyph: step to the next/previous effect.
- The glyph dims when nothing is running.

`showLabel` (widget settings) puts the current effect's name beside the glyph
instead of just the brush icon.

## Files

- `manifest.json` — the bar-widget declaration, `defaultSection: "right"`.
- `Hyprglaze.qml` — the widget and its popup.

The widget also carries an `IpcHandler` (from `Panel`), so
`omarchy-shell huru.hyprglaze open|close|toggle` works from a keybinding or script.

## Notes for whoever edits this

- `Panel` (in `qs.Ui`) is the base item: the bar draws `visible` BarIconButton
  children and the same item owns the `KeyboardPanel` popup, which is why the
  glyph and the popup live in one file. The audio and monitor panels in
  `/usr/share/omarchy/shell/plugins/panels/` are the reference for the
  vocabulary (`ToggleSwitch`, `SearchableDropdown`, `PanelSectionHeader`,
  `PanelSeparator`, `PanelActionButton`, `PanelToolTip`).
- Trailing controls (a switch, a button) cannot be anchored inside a `Row` —
  QtQuick refuses it and the row silently lays out wrong. Use an `Item` with
  `anchors.right` children, as the hero does.
- Inside a `ScrollView`, a child's `parent.width` is the flickable's *content*
  width, not the viewport. Use `scrollArea.availableWidth` or the column
  collapses to its own implicit width and every label truncates.
- Glyphs must be `\uXXXX` escapes with `textFormat: Text.PlainText`; literal
  characters get mangled through the payload.
- Test without an image build: the shell's PATH has `~/.local/bin` ahead of
  `/usr/bin`, so `scp` this directory to `~/.config/omarchy/plugins/huru.hyprglaze/`
  and a current `omarchy-hyprglaze` to `~/.local/bin/`, then
  `omarchy plugin enable huru.hyprglaze && omarchy-restart-shell`. Remove the
  `~/.local/bin` copies afterwards — they shadow the image's own command.
