#!/bin/bash

# Remove the Better Workspaces symlinks and restore Omarchy's stock workspaces.

set -euo pipefail

config="${XDG_CONFIG_HOME:-$HOME/.config}"
plugin_id="bumaruf.better-workspaces"
hypr="$config/hypr"
shell_json="$config/omarchy/shell.json"
stamp="$(date +%s)"

if [[ -f $shell_json ]] && command -v jq >/dev/null; then
  cp "$shell_json" "$shell_json.bak.$stamp"
  jq --arg old "$plugin_id" '(.bar.layout[]?[]? | select(.id == $old) | .id) |= "omarchy.workspaces"' \
    "$shell_json.bak.$stamp" >"$shell_json"
fi

if grep -qs 'hypr.better-workspaces.init' "$hypr/workspaces.lua"; then
  mv "$hypr/workspaces.lua" "$hypr/workspaces.lua.bak.$stamp"
  echo "-- Personal workspace rules." >"$hypr/workspaces.lua"
  echo "Moved $hypr/workspaces.lua to $hypr/workspaces.lua.bak.$stamp"
fi

[[ -L $hypr/better-workspaces ]] && rm "$hypr/better-workspaces"
[[ -L $config/omarchy/plugins/$plugin_id ]] && rm "$config/omarchy/plugins/$plugin_id"

command -v hyprctl >/dev/null && hyprctl reload >/dev/null
command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Better Workspaces removed."
