-- Hurunagus: use Hyprland's Niri-like scrolling layout by default.
--
-- Omarchy's shipped default is the dwindle layout. This override is loaded
-- after Omarchy's defaults, so it wins without editing the packaged files.
-- column_width = 0.97 shows a single window per screen instead of two.

hl.config({
  general = {
    layout = "scrolling",
  },

  scrolling = {
    column_width = 0.97,
  },
})
