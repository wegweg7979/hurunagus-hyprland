-- Hurunagus: default every machine to a 1080p logical desktop.
--
-- Omarchy's shipped default is `preferred` with GDK_SCALE=2 and monitor scale
-- "auto". We pin 1920x1080 at 1x instead, so the desktop always starts at
-- 1080p regardless of what the display advertises.

hl.env("GDK_SCALE", "1")
hl.monitor({ output = "", mode = "1920x1080", position = "auto", scale = 1 })

-- Do not pin workspaces to monitors with hl.workspace_rule here. Omarchy 4.5
-- gives every monitor a block of ten workspace ids of its own
-- (default/hypr/monitor-workspaces.lua) and the bar labels each monitor's own
-- block 1-10. A pin fights that numbering: Omarchy renumbers the pinned
-- workspaces into another monitor's block and the bar's workspace list churns.
-- Super + 1-0 already means "that slot on the monitor you are on".

-- Configure a specific monitor (find the name with `hyprctl monitors all`).
-- hl.monitor({ output = "DP-1", mode = "1920x1080", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90 degrees, 3 = 270).
-- hl.monitor({ output = "DP-2", mode = "1920x1080", position = "auto", scale = 1, transform = 1 })
