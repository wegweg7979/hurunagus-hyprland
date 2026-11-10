# Power profile (Omarchy bar widget)

A CPU power profile picker for the bar, shipped by Hurunagus.

Omarchy's own `omarchy.power` widget carries the same picker, but it gates its
whole panel on `visible: batteryPresent`. On a machine whose UPower display
device reports no battery — every desktop and VM — that widget renders
zero-width, and the `omarchy.battery` service only restores profiles on
AC/battery transitions. Those sessions had no way to switch the CPU power
profile from the shell at all. This widget is the profile half on its own.

## Interactions

- **Left click** — popup picker: performance / balanced / power saver, with the
  active one highlighted.
- **Right click** — cycle forward; **middle click** — cycle backward.
- **Keyboard** — arrows move the cursor, Return applies, Escape closes. The bar
  focus ring reaches it like any other icon.

## How it works

Reads and writes go through `omarchy-powerprofiles-list` and
`omarchy-powerprofiles-set`, the same helpers Omarchy's first-party tooling
uses, so the choice persists under the same per-power-source state key
(`~/.local/state/omarchy/powerprofiles/{ac,battery}`). Profiles come from
`powerprofilesctl` (power-profiles-daemon or the tuned-ppd PowerProfiles D-Bus
API). The bar glyph follows the profile: a bolt for performance, balance scales
for balanced, a leaf for power saver.

## Setting

`showLabel` in this widget's `shell.json` entry shows the profile name beside
the icon:

```json
{ "id": "thord.powerprofile", "showLabel": true }
```

## Packaging

Part of the Hurunagus look-and-feel payload at
`/usr/share/hurunagus/config`, replayed into `~/.config` by
`omarchy-hurunagus-configs` (and seeded into `/etc/skel` for new users). The id
follows the `thord.*` namespace already used by Workspaces plus.
