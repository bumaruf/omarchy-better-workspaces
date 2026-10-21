-- GNOME / COSMIC style workspaces, see https://github.com/bumaruf/omarchy-better-workspaces
-- Every option is optional; these are the defaults except for `monitors`.
require("hypr.better-workspaces.init").setup({
  -- Primary first. Unlisted monitors are appended left to right.
  monitors = { "HDMI-A-1", "DP-3" },
  -- dynamic = true,              -- drop empty workspaces and renumber
  -- orientation = "vertical",    -- "vertical" (COSMIC) or "horizontal" (GNOME)
  -- animation = true,            -- slide workspaces along the orientation
  -- bindings = true,             -- SUPER+1..0, SUPER+CTRL+arrows, SUPER+TAB, ...
  -- overview_key = "SUPER + code:49",  -- key left of 1 (` ~), any layout
  -- max_workspaces = 30,
})
