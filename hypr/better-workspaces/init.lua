-- Better workspaces: GNOME / COSMIC style workspaces for Omarchy (Hyprland).
--
--   * Workspaces span all displays: switching changes every monitor at once.
--   * Dynamic: empty workspaces disappear, the rest renumber without gaps,
--     and there is always one empty workspace after the last occupied one.
--   * Linear (vertical) navigation with SUPER+CTRL+UP/DOWN.
--   * Overview overlay (Quickshell plugin bumaruf.better-workspaces).
--
-- Workspace ids encode both coordinates: id = slot * stride + n, where slot is
-- the monitor's position in `monitors` (0 = primary) and n is the logical
-- workspace number. Logical workspace 3 is therefore id 3 on the primary
-- monitor, 103 on the second one, 203 on the third, and so on.

local M = {}

local defaults = {
  -- Monitor order; the first is the primary. Unlisted monitors are appended
  -- left to right. Empty means "every monitor, left to right".
  monitors = {},
  stride = 100,
  -- Highest logical workspace (workspace rules are generated up to here).
  max_workspaces = 30,
  -- Remove empty workspaces and renumber the rest (GNOME "dynamic workspaces").
  dynamic = true,
  -- "vertical" (COSMIC) or "horizontal" (GNOME): arrow keys and animation.
  orientation = "vertical",
  animation = true,
  bindings = true,
  overview_key = "SUPER + code:49",
  plugin_id = "bumaruf.better-workspaces",
}

local cfg = {}
local slots = {} -- monitor name -> slot
local syncing = false
local reconcile_pending = false
local last_logical = 1

local function logical_of(id)
  local n = id % cfg.stride
  return n
end

local function slot_of(id)
  return math.floor(id / cfg.stride)
end

local function id_for(slot, n)
  return slot * cfg.stride + n
end

local function is_normal(ws)
  return ws ~= nil and not ws.special and ws.id > 0
end

-- Connected monitors in slot order.
local function ordered_monitors()
  local connected = hl.get_monitors() or {}
  local by_name = {}
  for _, monitor in ipairs(connected) do
    by_name[monitor.name] = monitor
  end

  local ordered, seen = {}, {}
  for _, name in ipairs(cfg.monitors) do
    if by_name[name] then
      table.insert(ordered, name)
      seen[name] = true
    end
  end

  local rest = {}
  for _, monitor in ipairs(connected) do
    if not seen[monitor.name] then
      table.insert(rest, monitor)
    end
  end
  table.sort(rest, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.y < b.y
  end)
  for _, monitor in ipairs(rest) do
    table.insert(ordered, monitor.name)
  end

  return ordered
end

local function refresh_slots()
  slots = {}
  local ordered = ordered_monitors()
  for index, name in ipairs(ordered) do
    slots[name] = index - 1
  end
  return ordered
end

local function apply_rules()
  local ordered = refresh_slots()
  for slot, name in ipairs(ordered) do
    for n = 1, cfg.max_workspaces do
      hl.workspace_rule({ workspace = tostring(id_for(slot - 1, n)), monitor = name, default = n == 1 })
    end
  end
end

local function active_logical()
  local workspace = hl.get_active_workspace()
  if not is_normal(workspace) then
    return 1
  end
  return logical_of(workspace.id)
end

-- Logical workspaces that exist, with their window counts.
local function snapshot()
  local logicals = {}
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if is_normal(ws) then
      local n = logical_of(ws.id)
      local entry = logicals[n] or { windows = 0, ids = {} }
      entry.windows = entry.windows + (ws.windows or 0)
      table.insert(entry.ids, ws.id)
      logicals[n] = entry
    end
  end
  return logicals
end

-- Number of workspaces the user can reach: every occupied one, the active one,
-- and one empty workspace after the last occupied one.
function M.count()
  local highest = 0
  for n, entry in pairs(snapshot()) do
    if entry.windows > 0 and n > highest then
      highest = n
    end
  end
  return math.min(math.max(highest + 1, active_logical()), cfg.max_workspaces)
end

local function with_quiet_cursor(fn)
  local no_warps = hl.get_config("cursor.no_warps")
  hl.config({ cursor = { no_warps = true } })
  syncing = true
  local ok, err = pcall(fn)
  syncing = false
  hl.config({ cursor = { no_warps = no_warps } })
  if not ok then
    error(err)
  end
end

-- Show logical workspace n on every monitor, keeping focus where it was.
local function show(n)
  local ordered = refresh_slots()
  local focused = hl.get_active_monitor()
  local focused_name = focused and focused.name

  with_quiet_cursor(function()
    for _, name in ipairs(ordered) do
      if name ~= focused_name then
        hl.dispatch(hl.dsp.focus({ workspace = tostring(id_for(slots[name], n)) }))
      end
    end
    if focused_name and slots[focused_name] then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(id_for(slots[focused_name], n)) }))
    end
  end)
end

function M.go(n)
  n = math.max(1, math.min(n, M.count()))
  local current = active_logical()
  if current ~= n then
    last_logical = current
  end
  show(n)
  -- show() mutes the workspace.active handler, so reconcile explicitly.
  M.schedule_reconcile()
end

function M.step(direction)
  M.go(active_logical() + direction)
end

function M.former()
  M.go(last_logical)
end

-- The workspace id a window on `monitor_name` should go to for logical n.
local function target_on(monitor_name, n)
  return tostring(id_for(slots[monitor_name] or 0, n))
end

local function window_monitor_name(window)
  local monitor = (window and window.monitor) or hl.get_active_monitor()
  return monitor and monitor.name
end

-- Move a window (the active one by default) to logical workspace n, on
-- `monitor_name` or else its own monitor. `follow` switches to n afterwards.
function M.move_window(n, follow, address, monitor_name)
  refresh_slots()
  local window = hl.get_active_window()
  if address then
    for _, candidate in ipairs(hl.get_windows() or {}) do
      if candidate.address == address then
        window = candidate
      end
    end
  end
  if window == nil then
    return
  end

  n = math.max(1, math.min(n, M.count()))
  local monitor = slots[monitor_name] ~= nil and monitor_name or window_monitor_name(window)
  local move = { workspace = target_on(monitor, n), follow = false }
  if address then
    move.window = "address:" .. address
  end
  hl.dispatch(hl.dsp.window.move(move))

  if follow then
    M.go(n)
  else
    M.schedule_reconcile()
  end
end

-- Open a new workspace at position n (shifting n and everything after it down
-- by one) and move a window into it, like dropping a window between two
-- workspaces in the GNOME / COSMIC overview.
function M.insert_window(n, address, monitor_name)
  refresh_slots()
  local logicals = snapshot()
  local highest = 0
  for logical in pairs(logicals) do
    highest = math.max(highest, logical)
  end
  if highest >= cfg.max_workspaces then
    return
  end

  syncing = true
  local ok, err = pcall(function()
    -- From the top down, so every target id is free.
    for logical = highest, n, -1 do
      local entry = logicals[logical]
      if entry then
        for _, id in ipairs(entry.ids) do
          hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(id), id = id + 1 }))
        end
      end
      if last_logical == logical then
        last_logical = logical + 1
      end
    end
  end)
  syncing = false
  if not ok then
    error(err)
  end

  M.move_window(n, false, address, monitor_name)
end

-- Cross-monitor drags in the overview. Every monitor has its own overlay
-- surface and Hyprland ends the pointer grab at the monitor edge, so once a
-- drag leaves its surface the overview asks Hyprland to report the cursor
-- ("better-workspaces-drag>>x,y" custom events) until the left button is
-- released ("better-workspaces-drop>>x,y"). The release bind lives as long as
-- the overview is open: Hyprland ignores the release of a press it saw before
-- the bind existed.
local drag_timer = nil
local release_bind = nil

local function emit_cursor(name)
  local pos = hl.get_cursor_pos()
  hl.dispatch(hl.dsp.event(name .. ">>" .. math.floor(pos.x) .. "," .. math.floor(pos.y)))
end

function M.stop_drag()
  if drag_timer ~= nil then
    drag_timer:set_enabled(false)
    drag_timer = nil
  end
end

function M.track_drag()
  if drag_timer ~= nil then
    return
  end
  drag_timer = hl.timer(function()
    emit_cursor("better-workspaces-drag")
  end, { timeout = 16, type = "repeat" })
end

function M.overview_opened()
  if release_bind ~= nil then
    return
  end
  release_bind = hl.bind("mouse:272", function()
    if drag_timer ~= nil then
      M.stop_drag()
      emit_cursor("better-workspaces-drop")
    end
  end, { release = true, non_consuming = true, ignore_mods = true })
end

function M.overview_closed()
  M.stop_drag()
  if release_bind ~= nil then
    release_bind:remove()
    release_bind = nil
  end
end

-- Move logical workspace `from` to position `to` on every monitor, shifting the
-- ones in between, like dragging a workspace in the COSMIC overview.
function M.move_workspace_to(from, to)
  local logicals = snapshot()
  local highest = 0
  for n, entry in pairs(logicals) do
    if entry.windows > 0 then
      highest = math.max(highest, n)
    end
  end
  to = math.max(1, math.min(to, highest))
  if logicals[from] == nil or from == to then
    return
  end

  local function shift(n, delta)
    local entry = logicals[n]
    if entry then
      for _, id in ipairs(entry.ids) do
        hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(id), id = id + delta }))
      end
    end
  end

  syncing = true
  local ok, err = pcall(function()
    -- Park `from` on the spare top id of each slot while the others shift.
    local spare = cfg.stride - 1
    for _, id in ipairs(logicals[from].ids) do
      hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(id), id = id - from + spare }))
    end
    if from < to then
      for n = from + 1, to do
        shift(n, -1)
      end
    else
      for n = from - 1, to, -1 do
        shift(n, 1)
      end
    end
    for _, id in ipairs(logicals[from].ids) do
      local parked = id - from + spare
      hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(parked), id = parked - spare + to }))
    end
  end)
  syncing = false
  if not ok then
    error(err)
  end
  M.schedule_reconcile()
end

function M.move_workspace_step(direction)
  local current = active_logical()
  M.move_workspace_to(current, current + direction)
end

function M.move_window_step(direction)
  M.move_window(active_logical() + direction, true)
end

-- Give a workspace that sits on the wrong monitor (dragged across, or left
-- behind when a monitor was unplugged) an id that matches where it is now.
local function normalize_slots(taken)
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if is_normal(ws) and ws.monitor then
      local slot = slots[ws.monitor.name]
      if slot ~= nil and slot_of(ws.id) ~= slot then
        local n = logical_of(ws.id)
        if n == 0 or taken[id_for(slot, n)] then
          n = 1
          while taken[id_for(slot, n)] and n < cfg.max_workspaces do
            n = n + 1
          end
        end
        local target = id_for(slot, n)
        if not taken[target] then
          taken[ws.id] = nil
          taken[target] = true
          hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(ws.id), id = target }))
        end
      end
    end
  end
end

-- Drop empty workspaces (other than the one in view) and close the gaps.
local function compact()
  local logicals = snapshot()
  local active = active_logical()

  local keep = {}
  for n, entry in pairs(logicals) do
    if entry.windows > 0 or n == active then
      table.insert(keep, n)
    end
  end
  table.sort(keep)

  local taken = {}
  for _, entry in pairs(logicals) do
    for _, id in ipairs(entry.ids) do
      taken[id] = true
    end
  end

  for index, n in ipairs(keep) do
    if n ~= index then
      for _, id in ipairs(logicals[n].ids) do
        local target = id_for(slot_of(id), index)
        if not taken[target] then
          taken[id] = nil
          taken[target] = true
          hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(id), id = target }))
        end
      end
      if last_logical == n then
        last_logical = index
      end
    end
  end
end

-- Every monitor should show the same logical workspace as the focused one.
local function sync_monitors()
  local workspace = hl.get_active_workspace()
  if not is_normal(workspace) then
    return
  end

  local n = logical_of(workspace.id)
  for name, slot in pairs(slots) do
    local shown = hl.get_active_workspace(name)
    if shown ~= nil and shown.id ~= id_for(slot, n) then
      show(n)
      return
    end
  end
end

function M.reconcile()
  reconcile_pending = false
  if syncing then
    return
  end

  syncing = true
  local ok, err = pcall(function()
    local taken = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
      if is_normal(ws) then
        taken[ws.id] = true
      end
    end
    normalize_slots(taken)
    if cfg.dynamic then
      compact()
    end
  end)
  syncing = false
  if not ok then
    error(err)
  end

  sync_monitors()
end

-- Events arrive in bursts (a window close fires several); coalesce them.
function M.schedule_reconcile()
  if reconcile_pending or syncing then
    return
  end
  reconcile_pending = true
  hl.timer(function()
    M.reconcile()
  end, { timeout = 40, type = "oneshot" })
end

-- Machine-readable state for the shell plugin and scripts.
function M.state()
  local logicals = snapshot()
  local out = { active = active_logical(), count = M.count(), stride = cfg.stride, workspaces = {} }
  for n = 1, out.count do
    local entry = logicals[n]
    table.insert(out.workspaces, { n = n, windows = entry and entry.windows or 0 })
  end
  return out
end

local function bind_keys()
  local prev_key, next_key = "UP", "DOWN"
  if cfg.orientation == "horizontal" then
    prev_key, next_key = "LEFT", "RIGHT"
  end

  for n = 1, 10 do
    local key = "code:" .. tostring(n + 9)
    hl.unbind("SUPER + " .. key)
    hl.unbind("SUPER + SHIFT + " .. key)
    hl.unbind("SUPER + SHIFT + ALT + " .. key)

    o.bind("SUPER + " .. key, "Switch to workspace " .. n, function() M.go(n) end)
    o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. n, function() M.move_window(n, true) end)
    o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. n, function()
      M.move_window(n, false)
    end)
  end

  for _, keys in ipairs({
    "SUPER + CTRL + " .. prev_key,
    "SUPER + CTRL + " .. next_key,
    "SUPER + CTRL + SHIFT + " .. prev_key,
    "SUPER + CTRL + SHIFT + " .. next_key,
    "SUPER + TAB",
    "SUPER + SHIFT + TAB",
    "SUPER + CTRL + TAB",
    "SUPER + mouse_down",
    "SUPER + mouse_up",
  }) do
    hl.unbind(keys)
  end

  o.bind("SUPER + CTRL + " .. prev_key, "Previous workspace", function() M.step(-1) end)
  o.bind("SUPER + CTRL + " .. next_key, "Next workspace", function() M.step(1) end)
  o.bind("SUPER + CTRL + SHIFT + " .. prev_key, "Move window to previous workspace", function()
    M.move_window_step(-1)
  end)
  o.bind("SUPER + CTRL + SHIFT + " .. next_key, "Move window to next workspace", function()
    M.move_window_step(1)
  end)
  o.bind("SUPER + TAB", "Next workspace", function() M.step(1) end)
  o.bind("SUPER + SHIFT + TAB", "Previous workspace", function() M.step(-1) end)
  o.bind("SUPER + CTRL + TAB", "Former workspace", function() M.former() end)
  o.bind("SUPER + mouse_down", "Next workspace", function() M.step(1) end)
  o.bind("SUPER + mouse_up", "Previous workspace", function() M.step(-1) end)

  hl.unbind("SUPER + CTRL + ALT + " .. prev_key)
  hl.unbind("SUPER + CTRL + ALT + " .. next_key)
  o.bind("SUPER + CTRL + ALT + " .. prev_key, "Move workspace up the list", function() M.move_workspace_step(-1) end)
  o.bind("SUPER + CTRL + ALT + " .. next_key, "Move workspace down the list", function() M.move_workspace_step(1) end)

  if cfg.overview_key then
    hl.unbind(cfg.overview_key)
    o.bind(cfg.overview_key, "Workspace overview", "omarchy-shell shell toggle " .. cfg.plugin_id .. " '{}'")
  end
end

function M.setup(options)
  cfg = {}
  for key, value in pairs(defaults) do
    cfg[key] = value
  end
  for key, value in pairs(options or {}) do
    cfg[key] = value
  end

  -- `omarchy menu keybindings` evaluates this config against a stub `hl` to
  -- list bindings; only touch live compositor state under the real API.
  local live = type(hl.get_monitors) == "function"

  if live then
    apply_rules()
  end

  if cfg.animation then
    local style = cfg.orientation == "horizontal" and "slide" or "slidevert"
    hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "easeOutQuint", style = style })
  end

  if cfg.bindings then
    bind_keys()
  end

  hl.layer_rule({ match = { namespace = "^better-workspaces-overview$" }, blur = true, ignore_alpha = 0.1, animation = "fade" })

  hl.on("workspace.active", function()
    if not syncing then
      sync_monitors()
      M.schedule_reconcile()
    end
  end)

  for _, event in ipairs({ "window.open", "window.close", "window.destroy", "window.move_to_workspace", "workspace.removed", "workspace.move_to_monitor" }) do
    hl.on(event, function() M.schedule_reconcile() end)
  end

  for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
    hl.on(event, function()
      apply_rules()
      M.schedule_reconcile()
    end)
  end

  -- Exposed for the shell plugin and scripts:
  --   hyprctl eval 'o.better_workspaces.go(3)'
  o.better_workspaces = M
  -- Backwards compatible with the old paired-workspace script.
  o.switch_workspace_pair = M.go

  if live then
    M.schedule_reconcile()
  end
  return M
end

return M
